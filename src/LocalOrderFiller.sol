// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {IReactorCallback} from "../lib/uniswapx/src/interfaces/IReactorCallback.sol";
import {SignedOrder, ResolvedOrder} from "../lib/uniswapx/src/base/ReactorStructs.sol";
import {V3DutchOrder} from "../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOrderSwapRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Local integration candidate only. No deployment or release manifest entry.
/// The reactor owns signatures/nonces; this immutable filler builds single-pool
/// recipes and gives all surplus to the signed trader after atomic settlement.
contract LocalOrderFiller is IReactorCallback {
    using SafeERC20 for IERC20;
    IReactor public immutable reactor;
    IOrderSwapRouter public immutable router;
    IAllowanceTransfer public immutable permit2;
    address public immutable usdc;
    address public immutable launchHook;
    address public immutable appRecipient;
    uint256 public constant APP_FEE_BPS = 50;
    bool private active;
    uint256 private inputBaseline;
    error InvalidOrder();
    error ForbiddenCallback();
    error NetMinimumNotMet();

    constructor(IReactor r, IOrderSwapRouter u, IAllowanceTransfer p, address usd, address hook, address recipient) {
        require(
            address(r) != address(0) && address(u) != address(0) && address(p) != address(0) && usd != address(0)
                && recipient != address(0) && hook != address(0)
        );
        reactor = r;
        router = u;
        permit2 = p;
        usdc = usd;
        launchHook = hook;
        appRecipient = recipient;
    }

    function fill(SignedOrder calldata signed, PoolKey calldata key) external {
        if (active) revert InvalidOrder();
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        if (order.baseOutputs.length != 1 || order.baseOutputs[0].recipient != order.info.swapper) revert InvalidOrder();
        IERC20 output = IERC20(order.baseOutputs[0].token);
        IERC20 input = IERC20(address(order.baseInput.token));
        uint256 beforeBalance = output.balanceOf(order.info.swapper);
        active = true;
        inputBaseline = input.balanceOf(address(this));
        uint256 outputBaseline = output.balanceOf(address(this));
        reactor.executeWithCallback(signed, abi.encode(key));
        // Only this fill's surplus belongs to its signer. Unsolicited donations
        // neither subsidize orders nor prevent the next user's fill.
        uint256 leftover = output.balanceOf(address(this)) - outputBaseline;
        if (leftover > 0) output.safeTransfer(order.info.swapper, leftover);
        input.forceApprove(address(permit2), 0);
        permit2.approve(address(input), address(router), 0, 0);
        output.forceApprove(address(reactor), 0);
        if (output.balanceOf(order.info.swapper) < beforeBalance + order.baseOutputs[0].minAmount) {
            revert NetMinimumNotMet();
        }
        active = false;
        inputBaseline = 0;
    }

    function reactorCallback(ResolvedOrder[] memory orders, bytes memory callbackData) external {
        if (msg.sender != address(reactor) || !active) revert ForbiddenCallback();
        if (orders.length != 1 || orders[0].outputs.length != 1) revert InvalidOrder();
        ResolvedOrder memory order = orders[0];
        PoolKey memory key = abi.decode(callbackData, (PoolKey));
        address input = address(order.input.token);
        address output = order.outputs[0].token;
        if (input == output || output == address(0) || order.outputs[0].recipient != order.info.swapper) revert InvalidOrder();
        if (!((input == Currency.unwrap(key.currency0) && output == Currency.unwrap(key.currency1))
                    || (input == Currency.unwrap(key.currency1) && output == Currency.unwrap(key.currency0)))) revert InvalidOrder();
        if (input != usdc && output != usdc) revert InvalidOrder();
        uint256 amount = order.input.amount;
        uint256 minimum = order.outputs[0].amount;
        if (amount > type(uint128).max || minimum > type(uint128).max) revert InvalidOrder();
        // A taxed input must not spend pre-existing donated funds to fill the gap.
        if (IERC20(input).balanceOf(address(this)) != inputBaseline + amount) revert InvalidOrder();
        IERC20(input).forceApprove(address(permit2), amount);
        permit2.approve(input, address(router), uint160(amount), uint48(block.timestamp));
        bool app = address(key.hooks) != launchHook;
        bool buy = input == usdc;
        uint256 fee = app && buy ? amount * APP_FEE_BPS / 10000 : 0;
        bytes memory hookData = app ? bytes("") : abi.encode(uint256(uint160(order.info.swapper)));
        bytes[] memory swapParams = new bytes[](3);
        swapParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams(
                key,
                input == Currency.unwrap(key.currency0),
                uint128(amount - fee),
                uint128(app && !buy ? 0 : minimum),
                0,
                hookData
            )
        );
        swapParams[1] = abi.encode(Currency.wrap(input), amount - fee);
        // Keep sell output in the router until PAY_PORTION and SWEEP have run.
        swapParams[2] = abi.encode(Currency.wrap(output), app && !buy ? address(2) : address(this), uint256(0));
        bytes memory swapInput = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE)),
            swapParams
        );
        bytes memory commands;
        bytes[] memory inputs;
        if (!app) {
            commands = hex"10";
            inputs = new bytes[](1);
            inputs[0] = swapInput;
        } else if (buy) {
            commands = hex"0210";
            inputs = new bytes[](2);
            inputs[0] = abi.encode(usdc, appRecipient, uint160(fee));
            inputs[1] = swapInput;
        } else {
            commands = hex"100604";
            inputs = new bytes[](3);
            inputs[0] = swapInput;
            inputs[1] = abi.encode(usdc, appRecipient, APP_FEE_BPS);
            inputs[2] = abi.encode(usdc, address(this), minimum);
        }
        router.execute(commands, inputs, order.info.deadline);
        // Fixed input orders reject liquidity exhaustion instead of refunding a partial fill.
        if (IERC20(input).balanceOf(address(this)) != inputBaseline) revert InvalidOrder();
        IERC20(output).forceApprove(address(reactor), minimum);
    }
}
