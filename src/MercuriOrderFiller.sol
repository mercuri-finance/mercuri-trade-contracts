// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {IReactorCallback} from "../lib/uniswapx/src/interfaces/IReactorCallback.sol";
import {SignedOrder, ResolvedOrder} from "../lib/uniswapx/src/base/ReactorStructs.sol";
import {V3DutchOrder, V3DutchOrderLib} from "../lib/uniswapx/src/lib/V3DutchOrderLib.sol";

/// @dev The one Universal Router entry point this filler calls: a command list, its inputs and a deadline.
interface IOrderSwapRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Settles one signed UniswapX order through one Arc v4 USDC pool. The signed trader receives every output
///         above what the reactor takes (its protocol fee) and, on a sell, above the execution fee. A fixed USDC
///         execution fee is paid to `feeRecipient` (the keeper) on each successful fill, from the USDC side: a buy's
///         input before the swap, a sell's output after it. The signed minimum is still enforced, so the fee only comes
///         out of value above it. Tokens sent to this contract outside a fill never subsidize another order or the fee.
/// @dev Immutable: no owner, pause, upgrade or rescue path. Orders are bound to their reactor and cosigner, not to
///      this contract, so a replacement filler can settle orders that are already signed; the keeper switches by
///      configuration. Only the configured keeper (`feeRecipient`) can call `fill`. The keeper cosigns each order
///      exclusive to this filler, and the caller of `fill` chooses the pool, so an open `fill` would let a copier
///      route a keeper-cosigned order through a pool of its choice (for example around Launch's hook fee) or race
///      the keeper for its own transaction. Restricting the caller keeps settlement and pool choice with the keeper.
///      Rotating the keeper key therefore means deploying a new filler and switching by configuration.
contract MercuriOrderFiller is IReactorCallback {
    using SafeERC20 for IERC20;
    using V3DutchOrderLib for V3DutchOrder;

    /// @notice App fee in basis points of the USDC side, fixed at 50 bps.
    uint256 public constant APP_FEE_BPS = 50;
    /// @notice Upper bound on `executionFee`: 0.10 USDC (6 decimals).
    uint256 public constant MAX_EXECUTION_FEE = 100_000;

    uint256 private constant BPS = 10_000;

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
    /// @notice USDC (6 decimals) paid to `feeRecipient` once per successful fill, on Launch and listed pools alike.
    /// @dev A buy takes it from the USDC input before the swap; a sell from the USDC output after it. It never
    ///      reduces the trader's signed minimum, and zero disables the transfer.
    uint256 public immutable executionFee;
    /// @notice Recipient of the execution fee: the keeper's transaction address, fixed for this filler's life.
    /// @dev Also the only address allowed to call `fill`.
    address public immutable feeRecipient;

    /// @dev True only while `fill` runs: `reactorCallback` requires it and a nested `fill` is refused.
    bool private active;
    /// @dev This contract's input-token balance when the current fill started; zero outside a fill.
    uint256 private inputBaseline;

    /// @notice Emitted once for each order settled through this filler.
    /// @param orderHash the trader-signed order hash, as the reactor's `Fill` event carries it
    /// @param swapper the trader who signed the order
    /// @param poolId `keccak256(abi.encode(key))` of the pool used
    event OrderFilled(bytes32 indexed orderHash, address indexed swapper, bytes32 indexed poolId);

    /// @notice A constructor dependency or the fee recipient is the zero address.
    error ZeroAddress();
    /// @notice The order, its outputs or the pool do not fit this filler, or a fill is already in progress.
    error InvalidOrder();
    /// @notice The callback came from someone other than the reactor, or outside a fill.
    error ForbiddenCallback();
    /// @notice The trader's balance rose by less than the order's signed minimum output.
    error NetMinimumNotMet();
    /// @notice The constructor's execution fee is above `MAX_EXECUTION_FEE`.
    error ExecutionFeeTooHigh();
    /// @notice `fill` was called by an address other than the configured keeper (`feeRecipient`).
    error NotKeeper();

    /// @notice Fixes the settlement dependencies, fee recipients and execution fee for this filler's life.
    /// @dev Reverts `ZeroAddress` if any address is zero and `ExecutionFeeTooHigh` above `MAX_EXECUTION_FEE`.
    /// @param reactor_ Reactor that authenticates the signed order.
    /// @param router_ Universal Router used for the swap.
    /// @param permit2_ Permit2 allowance target used by the router.
    /// @param usdc_ USDC token address.
    /// @param launchHook_ Deployed Launch hook; its pools use the Launch fee path.
    /// @param appRecipient_ App fee recipient for other USDC pools.
    /// @param executionFee_ Execution fee in USDC (6 decimals), at most `MAX_EXECUTION_FEE`; zero disables it.
    /// @param feeRecipient_ Execution fee recipient (the keeper's transaction address); must be nonzero.
    constructor(
        IReactor reactor_,
        IOrderSwapRouter router_,
        IAllowanceTransfer permit2_,
        address usdc_,
        address launchHook_,
        address appRecipient_,
        uint256 executionFee_,
        address feeRecipient_
    ) {
        if (
            address(reactor_) == address(0) || address(router_) == address(0) || address(permit2_) == address(0)
                || usdc_ == address(0) || appRecipient_ == address(0) || launchHook_ == address(0)
                || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        if (executionFee_ > MAX_EXECUTION_FEE) revert ExecutionFeeTooHigh();
        reactor = reactor_;
        router = router_;
        permit2 = permit2_;
        usdc = usdc_;
        launchHook = launchHook_;
        appRecipient = appRecipient_;
        executionFee = executionFee_;
        feeRecipient = feeRecipient_;
    }

    /// @notice Fills one signed order: the trader receives every output above what the reactor takes; a fixed USDC
    ///         execution fee is taken from the order's USDC side (the input on a buy, the output on a sell) and paid
    ///         to `feeRecipient`.
    /// @dev Only the configured keeper (`feeRecipient`) may call this; any other caller reverts `NotKeeper` before the
    ///      order is touched. The reactor enforces its signature, nonce and deadline; this call reverts atomically,
    ///      paying no fee, if the trader's signed net minimum is unmet.
    /// @param signed User-signed UniswapX V3 Dutch order and signature.
    /// @param key The one USDC pool used for this fill.
    function fill(SignedOrder calldata signed, PoolKey calldata key) external {
        if (msg.sender != feeRecipient) revert NotKeeper();
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

        // Only this fill's surplus belongs to its signer. Unsolicited donations neither subsidize orders nor prevent
        // the next user's fill. On a sell the callback kept the execution fee in USDC output; on a buy, in USDC input.
        uint256 leftover =
            output.balanceOf(address(this)) - outputBaseline - (address(output) == usdc ? executionFee : 0);
        if (leftover > 0) output.safeTransfer(order.info.swapper, leftover);
        input.forceApprove(address(permit2), 0);
        permit2.approve(address(input), address(router), 0, 0);
        output.forceApprove(address(reactor), 0);

        if (output.balanceOf(order.info.swapper) < beforeBalance + order.baseOutputs[0].minAmount) {
            revert NetMinimumNotMet();
        }
        if (executionFee > 0) IERC20(usdc).safeTransfer(feeRecipient, executionFee);
        emit OrderFilled(order.hash(), order.info.swapper, keccak256(abi.encode(key)));
        active = false;
        inputBaseline = 0;
    }

    /// @notice Settles the reactor's resolved order against the supplied pool.
    /// @dev Only the configured reactor can call this during an active fill. It leaves exactly `executionFee` USDC in
    ///      this contract for `fill` to pay: a buy swaps the input less the app and execution fees; a sell requires
    ///      the swap to yield the reactor's outputs plus the execution fee.
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
                    || (input == Currency.unwrap(key.currency1) && output == Currency.unwrap(key.currency0)))) {
            revert InvalidOrder();
        }
        if (input != usdc && output != usdc) revert InvalidOrder();
        bool app = address(key.hooks) != launchHook;
        bool buy = input == usdc;
        uint256 amount = order.input.amount;
        uint256 minimum = _owed(order, output);
        // A sell's swap must also yield the execution fee on top of the reactor's outputs.
        uint256 required = buy ? minimum : minimum + executionFee;
        if (amount > type(uint128).max || required > type(uint128).max) revert InvalidOrder();
        uint256 appFee = app && buy ? amount * APP_FEE_BPS / BPS : 0;
        // A buy keeps the execution fee from its USDC input, so the input must exceed both fees.
        uint256 kept = buy ? executionFee : 0;
        if (buy && amount <= appFee + executionFee) revert InvalidOrder();
        // A taxed input must not spend pre-existing donated funds to fill the gap.
        if (IERC20(input).balanceOf(address(this)) != inputBaseline + amount) revert InvalidOrder();
        IERC20(input).forceApprove(address(permit2), amount - kept);
        permit2.approve(input, address(router), uint160(amount - kept), uint48(block.timestamp));
        (bytes memory commands, bytes[] memory inputs) =
            _recipe(key, input, output, amount - appFee - kept, appFee, required, order.info.swapper);
        router.execute(commands, inputs, order.info.deadline);
        // Fixed input orders reject liquidity exhaustion instead of refunding a partial fill.
        if (IERC20(input).balanceOf(address(this)) != inputBaseline + kept) revert InvalidOrder();
        IERC20(output).forceApprove(address(reactor), minimum);
    }

    /// @dev The trader's output plus any reactor protocol fee. Fees must be in the output token: the whole input goes
    ///      to the swap and fees, so an input-token fee cannot be paid and the fill is refused (the order stays open,
    ///      no funds move).
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

    /// @dev Builds the Universal Router call for one exact-input swap on `key`. Launch pools swap with the swap minimum
    ///      and pay Launch's hook fee; other pools pay the app fee from the USDC side (before a buy, as a portion of a
    ///      sell's output) and sweep the rest here.
    /// @param key The pool to swap on.
    /// @param input The token this contract spends.
    /// @param output The token this contract receives.
    /// @param swapAmount Input swapped, after the app and execution fees on a buy.
    /// @param appFee The app fee paid from a buy's USDC input; zero otherwise.
    /// @param required Least output this contract must receive: the reactor's outputs, plus the fee on a sell.
    /// @param swapper The trader, credited by Launch's hook for referrals.
    /// @return commands Universal Router commands.
    /// @return inputs Universal Router inputs, one per command.
    function _recipe(
        PoolKey memory key,
        address input,
        address output,
        uint256 swapAmount,
        uint256 appFee,
        uint256 required,
        address swapper
    ) private view returns (bytes memory commands, bytes[] memory inputs) {
        bool app = address(key.hooks) != launchHook;
        bool buy = input == usdc;
        bytes memory hookData = app ? bytes("") : abi.encode(uint256(uint160(swapper)));
        bytes[] memory swapParams = new bytes[](3);
        swapParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams(
                key,
                input == Currency.unwrap(key.currency0),
                uint128(swapAmount),
                uint128(app && !buy ? 0 : required),
                0,
                hookData
            )
        );
        swapParams[1] = abi.encode(Currency.wrap(input), swapAmount);
        // Keep sell output in the router until PAY_PORTION and SWEEP have run.
        swapParams[2] = abi.encode(Currency.wrap(output), app && !buy ? address(2) : address(this), uint256(0));
        bytes memory swapInput = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE)),
            swapParams
        );
        if (!app) {
            commands = hex"10";
            inputs = new bytes[](1);
            inputs[0] = swapInput;
        } else if (buy) {
            commands = hex"0210";
            inputs = new bytes[](2);
            inputs[0] = abi.encode(usdc, appRecipient, uint160(appFee));
            inputs[1] = swapInput;
        } else {
            commands = hex"100604";
            inputs = new bytes[](3);
            inputs[0] = swapInput;
            inputs[1] = abi.encode(usdc, appRecipient, APP_FEE_BPS);
            inputs[2] = abi.encode(usdc, address(this), required);
        }
    }
}
