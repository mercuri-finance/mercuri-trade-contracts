// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {IReactorCallback} from "../lib/uniswapx/src/interfaces/IReactorCallback.sol";
import {SignedOrder, ResolvedOrder} from "../lib/uniswapx/src/base/ReactorStructs.sol";
import {V3DutchOrder, V3DutchOrderLib} from "../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
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

/// @notice Settles one signed UniswapX order through one Arc v4 USDC pool.
/// @dev Immutable: no owner, pause, upgrade or rescue path. Orders are bound to
/// their reactor and cosigner, not to this contract, so a replacement filler can
/// settle orders that are already signed; the keeper switches by configuration.
/// The signed trader receives every output above the resolved minimum. Tokens sent
/// to this contract outside a fill are never spent to subsidize another order.
contract MercuriOrderFiller is IReactorCallback {
    using SafeERC20 for IERC20;
    using V3DutchOrderLib for V3DutchOrder;
    /// @notice Reactor that authenticates orders and invokes the callback.
    IReactor public immutable reactor;
    /// @notice Universal Router used for the v4 swap and app fee payment.
    IOrderSwapRouter public immutable router;
    /// @notice Permit2 allowance target used by the router.
    IAllowanceTransfer public immutable permit2;
    /// @notice USDC token address used for the pool and app fee.
    address public immutable usdc;
    /// @notice Launch hook address; pools with this hook pay Launch's hook fee.
    address public immutable launchHook;
    /// @notice Recipient of the app fee on other USDC pools.
    address public immutable appRecipient;
    /// @notice App fee in basis points of the USDC side, fixed at 50 bps.
    uint256 public constant APP_FEE_BPS = 50;
    bool private active;
    uint256 private inputBaseline;
    /// @notice One order settled through this filler.
    /// @param orderHash The trader-signed order hash, as the reactor's `Fill` event carries it.
    /// @param swapper The trader who signed the order.
    /// @param poolId `keccak256(abi.encode(key))` of the pool used.
    event OrderFilled(bytes32 indexed orderHash, address indexed swapper, bytes32 indexed poolId);
    /// @notice A constructor dependency or the fee recipient is the zero address.
    error ZeroAddress();
    /// @notice The order, its outputs or the pool do not fit this filler, or a fill is already in progress.
    error InvalidOrder();
    /// @notice The callback came from someone other than the reactor, or outside a fill.
    error ForbiddenCallback();
    /// @notice The trader's balance rose by less than the order's signed minimum output.
    error NetMinimumNotMet();

    /// @notice Sets the immutable settlement dependencies and fee recipient.
    /// @param r Reactor that authenticates the signed order.
    /// @param u Universal Router used for the swap.
    /// @param p Permit2 allowance target used by the router.
    /// @param usd USDC token address.
    /// @param hook Deployed Launch hook; its pools use the Launch fee path.
    /// @param recipient App fee recipient for other USDC pools.
    constructor(IReactor r, IOrderSwapRouter u, IAllowanceTransfer p, address usd, address hook, address recipient) {
        if (
            address(r) == address(0) || address(u) == address(0) || address(p) == address(0) || usd == address(0)
                || recipient == address(0) || hook == address(0)
        ) revert ZeroAddress();
        reactor = r;
        router = u;
        permit2 = p;
        usdc = usd;
        launchHook = hook;
        appRecipient = recipient;
    }

    /// @notice Fills one signed order and delivers its entire net output to the trader.
    /// @dev Anyone may submit a signed order. The reactor enforces its signature,
    /// nonce and deadline; this call reverts atomically if the net minimum is unmet.
    /// @param signed User-signed UniswapX V3 Dutch order and signature.
    /// @param key The one USDC pool used for this fill.
    function fill(SignedOrder calldata signed, PoolKey calldata key) external {
        if (active) revert InvalidOrder();
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        if (order.baseOutputs.length != 1 || order.baseOutputs[0].recipient != order.info.swapper) {
            revert InvalidOrder();
        }
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
        emit OrderFilled(order.hash(), order.info.swapper, keccak256(abi.encode(key)));
        active = false;
        inputBaseline = 0;
    }

    /// @dev The trader's output plus any reactor protocol fee. Fees must be in the
    /// output token: the whole input is spent on the swap, so an input-token fee
    /// cannot be paid and the fill is refused (the order stays open, no funds move).
    /// @param order The resolved order; `outputs[0]` is the trader's.
    /// @param output The output token.
    /// @return owed The total the reactor will take from this contract.
    function _owed(ResolvedOrder memory order, address output) private pure returns (uint256 owed) {
        uint256 n = order.outputs.length;
        if (n == 0) revert InvalidOrder();
        for (uint256 i; i < n; ++i) {
            if (order.outputs[i].token != output || order.outputs[i].recipient == address(0)) revert InvalidOrder();
            owed += order.outputs[i].amount;
        }
    }

    /// @notice Settles the reactor's resolved order against the supplied pool.
    /// @dev Only the configured reactor can call this during an active fill.
    /// @param orders The reactor's resolved orders; exactly one is accepted, with output-token fee outputs allowed.
    /// @param callbackData ABI-encoded pool key supplied to `fill`.
    function reactorCallback(ResolvedOrder[] memory orders, bytes memory callbackData) external {
        if (msg.sender != address(reactor) || !active) revert ForbiddenCallback();
        if (orders.length != 1) revert InvalidOrder();
        ResolvedOrder memory order = orders[0];
        PoolKey memory key = abi.decode(callbackData, (PoolKey));
        address input = address(order.input.token);
        address output = order.outputs[0].token;
        if (input == output || output == address(0) || order.outputs[0].recipient != order.info.swapper) {
            revert InvalidOrder();
        }
        if (!((input == Currency.unwrap(key.currency0) && output == Currency.unwrap(key.currency1))
                    || (input == Currency.unwrap(key.currency1) && output == Currency.unwrap(key.currency0)))) revert InvalidOrder();
        if (input != usdc && output != usdc) revert InvalidOrder();
        uint256 amount = order.input.amount;
        uint256 minimum = _owed(order, output);
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
