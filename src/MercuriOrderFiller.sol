// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {IReactorCallback} from "../lib/uniswapx/src/interfaces/IReactorCallback.sol";
import {IValidationCallback} from "../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {SignedOrder, ResolvedOrder} from "../lib/uniswapx/src/base/ReactorStructs.sol";
import {V3DutchOrder, V3DutchOrderLib, V3DutchInput} from "../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {NonlinearDutchDecayLib} from "../lib/uniswapx/src/lib/NonlinearDutchDecayLib.sol";
import {MathExt} from "../lib/uniswapx/src/lib/MathExt.sol";
import {FixedPointMathLib} from "../lib/uniswapx/lib/solmate/src/utils/FixedPointMathLib.sol";
import {IOrderSwapRouter} from "./interfaces/IOrderSwapRouter.sol";
import {MercuriOrderValidator} from "./MercuriOrderValidator.sol";

/// @notice Settles one signed UniswapX order through one Arc v4 USDC pool. The signed trader receives every output
///         above what the reactor takes (its protocol fee) and, on a sell, above the execution fee: a fixed USDC fee
///         paid to `feeRecipient` (the keeper) on each successful fill, only out of value above the signed minimum.
/// @dev Immutable: no owner, pause, upgrade or rescue path. The execution fee comes from the USDC side (see
///      `executionFee`). Tokens sent to this contract outside a fill never subsidize another order or the fee. Native
///      value is accepted only from the reactor (its end-of-fill refund) and is never spent. Only the configured keeper
///      (`feeRecipient`) can call `fill`. The pool is not the reason: the callback swaps only through the pool the
///      trader signed, whoever calls. Only this filler can settle an order (its validator refuses any other), so an
///      open `fill` would let anyone take a cosigned order from the mempool and, in one transaction, push the signed
///      pool's price (through a take-profit or stop-loss trigger, or just against a limit), fill there down to the
///      signed minimum and restore the price: a risk-free sandwich that the keeper's off-chain six-block hold cannot
///      stop, because it happens inside one transaction. It would also let copiers race the keeper's own fill
///      transaction and leave the keeper paying for the reverted one. Every order must name this filler's `validator`,
///      which the constructor deploys with CREATE2 and which accepts only this filler and checks the signed take-profit
///      or stop-loss trigger against the signed pool's price; the callback swaps only through that signed pool. So
///      neither the keeper's nor the cosigner's key can settle an untriggered order, route one through another pool or
///      settle it through another filler. Orders are bound to their reactor, cosigner and validator, and through the
///      validator to this filler: a replacement filler, which rotating the keeper key requires, comes with its own
///      validator and cannot settle orders signed for this one.
contract MercuriOrderFiller is IReactorCallback {
    using SafeERC20 for IERC20;
    using V3DutchOrderLib for V3DutchOrder;
    using NonlinearDutchDecayLib for V3DutchInput;
    using MathExt for uint256;
    using FixedPointMathLib for uint256;

    /// @notice App fee in basis points of the USDC side, fixed at 50 bps.
    /// @dev Charged on listed (non-Launch) pools only. A buy pays it on the gross signed input, which includes the
    ///      execution fee; a sell pays it on the swap's USDC output.
    uint256 public constant APP_FEE_BPS = 50;
    /// @notice Upper bound on `executionFee`: 0.10 USDC (6 decimals).
    uint256 public constant MAX_EXECUTION_FEE = 100_000;

    /// @notice CREATE2 salt with which the constructor deploys `validator` from this contract.
    bytes32 public constant VALIDATOR_SALT = bytes32(0);

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
    /// @notice Order validator every order must name; it accepts no other filler.
    /// @dev Deployed by the constructor with CREATE2 from this address with `VALIDATOR_SALT`, bound to this filler and
    ///      the pool manager for life.
    IValidationCallback public immutable validator;

    /// @dev True only while `fill` runs: `reactorCallback` requires it and a nested `fill` is refused.
    bool private active;
    /// @dev This contract's input-token balance when the current fill started; zero outside a fill.
    uint256 private inputBaseline;
    /// @dev Output the current fill's swap delivered above what it had to (`required`); zero outside a fill. The most
    ///      `fill` pays the trader on top of the reactor's outputs.
    uint256 private outputSurplus;

    /// @notice Emitted once for each order settled through this filler.
    /// @param orderHash the trader-signed order hash, as the reactor's `Fill` event carries it
    /// @param swapper the trader who signed the order
    /// @param poolId `keccak256(abi.encode(key))` of the pool used
    event OrderFilled(bytes32 indexed orderHash, address indexed swapper, bytes32 indexed poolId);

    /// @notice A constructor dependency or the fee recipient is the zero address.
    error ZeroAddress();
    /// @notice The order does not name this filler's `validator` as its `additionalValidationContract`.
    error WrongValidator();
    /// @notice The pool supplied to `fill` is not the pool the trader signed in the order's validation data.
    error PoolNotSigned();
    /// @notice `fill` was entered while a fill is already in progress.
    error Reentered();
    /// @notice The order does not have exactly one output to its signer in a token other than its input, or the
    ///         reactor resolved an output with no recipient.
    error InvalidOutputs();
    /// @notice The reactor resolved other than exactly one order for the callback.
    error InvalidOrderCount();
    /// @notice The pool's currencies are not the order's input and output, or neither of them is USDC.
    error PoolMismatch();
    /// @notice The input or the output owed does not fit in 128 bits, as the output of a late-cosigned order past its
    ///         window does.
    error AmountOverflow();
    /// @notice A buy's USDC input does not exceed the app fee plus the execution fee.
    error InputTooSmallForFees();
    /// @notice The filler did not receive exactly the signed input (a taxed input token) or the swap did not spend all
    ///         of it (the pool ran out of liquidity); a fixed-input order is never partly filled.
    error InputNotConsumed();
    /// @notice The swap delivered less output to this contract than it must hand back, as a taxed output token does.
    error InsufficientOutput();
    /// @notice The reactor's protocol fee is in a token other than the output; the input goes whole to the swap and
    ///         fees, so such a fee cannot be paid.
    error FeeOutputUnsupported();
    /// @notice The callback came from someone other than the reactor, or outside a fill.
    error ForbiddenCallback();
    /// @notice The trader's balance rose by less than the order's signed minimum output.
    error NetMinimumNotMet();
    /// @notice The constructor's execution fee is above `MAX_EXECUTION_FEE`.
    error ExecutionFeeTooHigh();
    /// @notice `fill` was called by an address other than the configured keeper (`feeRecipient`).
    error NotKeeper();
    /// @notice Native value was sent by an address other than the reactor.
    error NotReactor();
    /// @notice The order's deadline has passed; the reactor would refuse it (`DeadlineReached`).
    error OrderExpired();
    /// @notice The order's Permit2 nonce is already used or cancelled; Permit2 would refuse it (`InvalidNonce`).
    error NonceUsed();
    /// @notice The trader holds less of the input token than the reactor would take for this order in this block.
    error SwapperBalanceTooLow();
    /// @notice The trader's input-token allowance to Permit2 is below what the reactor would take for this order in
    ///         this block.
    error SwapperAllowanceTooLow();

    /// @notice Fixes the settlement dependencies, fee recipients and execution fee for this filler's life, and deploys
    ///         this filler's order validator.
    /// @dev Reverts `ZeroAddress` if any address is zero and `ExecutionFeeTooHigh` above `MAX_EXECUTION_FEE`. The
    ///      validator's address is `CREATE2(this, VALIDATOR_SALT, keccak256(creationCode ++ abi.encode(this,
    ///      poolManager_)))`, so both addresses are known before deployment.
    /// @param reactor_ Reactor that authenticates the signed order.
    /// @param router_ Universal Router used for the swap.
    /// @param permit2_ Permit2 allowance target used by the router.
    /// @param usdc_ USDC token address.
    /// @param launchHook_ Deployed Launch hook; its pools use the Launch fee path.
    /// @param appRecipient_ App fee recipient for other USDC pools.
    /// @param executionFee_ Execution fee in USDC (6 decimals), at most `MAX_EXECUTION_FEE`; zero disables it.
    /// @param feeRecipient_ Execution fee recipient (the keeper's transaction address); must be nonzero.
    /// @param poolManager_ Uniswap v4 PoolManager the validator reads trigger prices from.
    constructor(
        IReactor reactor_,
        IOrderSwapRouter router_,
        IAllowanceTransfer permit2_,
        address usdc_,
        address launchHook_,
        address appRecipient_,
        uint256 executionFee_,
        address feeRecipient_,
        IPoolManager poolManager_
    ) {
        if (
            address(reactor_) == address(0) || address(router_) == address(0) || address(permit2_) == address(0)
                || usdc_ == address(0) || appRecipient_ == address(0) || launchHook_ == address(0)
                || feeRecipient_ == address(0) || address(poolManager_) == address(0)
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
        validator = new MercuriOrderValidator{salt: VALIDATOR_SALT}(address(this), poolManager_);
    }

    // ---------------------------------------------------------------- settlement

    /// @notice Accepts native value from the reactor only.
    /// @dev The reactor refunds its whole native balance to the filler at the end of `executeWithCallback`. On Arc
    ///      native value is USDC, so any dust on the reactor (a 1-wei send or a 1-unit ERC-20 USDC transfer) is
    ///      refunded here, after the callback's input checks and the reactor's output transfers. Refusing it would
    ///      revert every fill. The value stays in this contract unspent, like a donation: `fill` pays the trader at
    ///      most the swap's own surplus, so it never subsidizes the fill it arrives in, and the next fill's baselines
    ///      include it, so no later fill can spend it either. There is no rescue path.
    receive() external payable {
        if (msg.sender != address(reactor)) revert NotReactor();
    }

    /// @notice Fills one signed order: the trader receives every output above what the reactor takes; a fixed USDC
    ///         execution fee is taken from the order's USDC side (the input on a buy, the output on a sell) and paid
    ///         to `feeRecipient`.
    /// @dev Only the configured keeper (`feeRecipient`) may call this; any other caller reverts `NotKeeper` before the
    ///      order is touched. An order that does not name `validator` reverts `WrongValidator` before the reactor; the
    ///      validator then refuses an untriggered take-profit or stop-loss, and the callback refuses a `key` other than
    ///      the signed pool (`PoolNotSigned`). The reactor enforces its signature, nonce and deadline; this call
    ///      reverts atomically, paying no fee, if the trader's signed net minimum is unmet. Before the reactor runs,
    ///      `_requireFundable` refuses an order the reactor would refuse at the input transfer (passed deadline, used
    ///      nonce, too little balance or Permit2 allowance), so a trader who moves funds, revokes the approval or
    ///      cancels the nonce after the keeper's simulation costs the keeper a cheap, typed revert rather than a deep
    ///      one in the reactor.
    /// @param signed User-signed UniswapX V3 Dutch order and signature.
    /// @param key One USDC pool used for this fill.
    function fill(SignedOrder calldata signed, PoolKey calldata key) external {
        if (msg.sender != feeRecipient) revert NotKeeper();
        if (active) revert Reentered();
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        if (order.baseOutputs.length != 1 || order.baseOutputs[0].recipient != order.info.swapper) {
            revert InvalidOutputs();
        }
        if (order.info.additionalValidationContract != validator) revert WrongValidator();

        IERC20 output = IERC20(order.baseOutputs[0].token);
        IERC20 input = IERC20(address(order.baseInput.token));
        _requireFundable(order, input);
        uint256 beforeBalance = output.balanceOf(order.info.swapper);
        active = true;
        inputBaseline = input.balanceOf(address(this));
        uint256 outputBaseline = output.balanceOf(address(this));
        reactor.executeWithCallback(signed, abi.encode(key));

        // Only this fill's surplus belongs to its signer. Unsolicited donations neither subsidize orders nor prevent
        // the next user's fill. On a sell the callback kept the execution fee in USDC output; on a buy, in USDC input.
        // The balance can also hold the reactor's native refund (USDC on Arc), so the payout is capped at the swap's
        // own surplus, and the balance bound keeps any token that debits more than it sends off the donations.
        uint256 leftover =
            output.balanceOf(address(this)) - outputBaseline - (address(output) == usdc ? executionFee : 0);
        if (leftover > outputSurplus) leftover = outputSurplus;
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
        outputSurplus = 0;
    }

    /// @notice Settles the reactor's resolved order against the supplied pool.
    /// @dev Only the configured reactor can call this during an active fill, after `validator` accepted the order. The
    ///      pool must be the one the trader signed: `keccak256(abi.encode(key))` equal to the `poolId` in the order's
    ///      validation data, which the validator has already decoded and checked. It leaves exactly `executionFee` USDC
    ///      in this contract for `fill` to pay: a buy swaps the input less the app and execution fees; a sell requires
    ///      the swap to yield the reactor's outputs plus the execution fee. It records the output the swap delivered
    ///      above that as `outputSurplus`, the most `fill` pays the trader on top of the reactor's outputs.
    /// @param orders Reactor's resolved orders; exactly one is accepted, with output-token fee outputs allowed.
    /// @param callbackData ABI-encoded pool key supplied to `fill`.
    function reactorCallback(ResolvedOrder[] memory orders, bytes memory callbackData) external {
        if (msg.sender != address(reactor) || !active) revert ForbiddenCallback();
        if (orders.length != 1) revert InvalidOrderCount();
        ResolvedOrder memory order = orders[0];
        PoolKey memory key = abi.decode(callbackData, (PoolKey));
        address input = address(order.input.token);
        address output = order.outputs[0].token;
        if (input == output || output == address(0) || order.outputs[0].recipient != order.info.swapper) {
            revert InvalidOutputs();
        }
        if (!((input == Currency.unwrap(key.currency0) && output == Currency.unwrap(key.currency1))
                    || (input == Currency.unwrap(key.currency1) && output == Currency.unwrap(key.currency0)))) {
            revert PoolMismatch();
        }
        if (input != usdc && output != usdc) revert PoolMismatch();
        (,, bytes32 signedPool,) = abi.decode(order.info.additionalValidationData, (uint8, uint8, bytes32, uint160));
        if (keccak256(abi.encode(key)) != signedPool) revert PoolNotSigned();
        bool app = address(key.hooks) != launchHook;
        bool buy = input == usdc;
        uint256 amount = order.input.amount;
        uint256 minimum = _owed(order, output);
        // A sell's swap must also yield the execution fee on top of the reactor's outputs.
        uint256 required = buy ? minimum : minimum + executionFee;
        if (amount > type(uint128).max || required > type(uint128).max) revert AmountOverflow();
        uint256 appFee = app && buy ? amount * APP_FEE_BPS / BPS : 0;
        // A buy keeps the execution fee from its USDC input, so the input must exceed both fees.
        uint256 kept = buy ? executionFee : 0;
        if (buy && amount <= appFee + executionFee) revert InputTooSmallForFees();
        // A taxed input must not spend pre-existing donated funds to fill the gap.
        if (IERC20(input).balanceOf(address(this)) != inputBaseline + amount) revert InputNotConsumed();
        IERC20(input).forceApprove(address(permit2), amount - kept);
        permit2.approve(input, address(router), uint160(amount - kept), uint48(block.timestamp));
        (bytes memory commands, bytes[] memory inputs) =
            _recipe(key, input, output, amount - appFee - kept, appFee, required, order.info.swapper);
        uint256 outputBefore = IERC20(output).balanceOf(address(this));
        router.execute(commands, inputs, order.info.deadline);
        // Fixed input orders reject liquidity exhaustion instead of refunding a partial fill.
        if (IERC20(input).balanceOf(address(this)) != inputBaseline + kept) revert InputNotConsumed();
        // The router enforced a swap of at least `required`; a taxed output token can still deliver less here.
        uint256 received = IERC20(output).balanceOf(address(this)) - outputBefore;
        if (received < required) revert InsufficientOutput();
        outputSurplus = received - required;
        IERC20(output).forceApprove(address(reactor), minimum);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Refuses, before the reactor runs, an order the reactor would refuse when it pulls the input through
    ///      Permit2: the deadline has passed (`OrderExpired`), the Permit2 nonce bit is set (`NonceUsed`), or the
    ///      trader's input balance (`SwapperBalanceTooLow`) or allowance to Permit2 (`SwapperAllowanceTooLow`) is below
    ///      the amount the reactor would take in this block. It only reads: `permit2`'s nonce bitmap (the reactor's own
    ///      Permit2: the deployment script requires `reactor.permit2() == permit2`) and the input token's `balanceOf`
    ///      and `allowance`, both static calls. It can only make a fill revert earlier, never let through one the
    ///      reactor refuses. A token whose views overstate passes here and fails in Permit2 as before; one whose views
    ///      understate or revert only blocks its own orders, and `fill` already calls its `balanceOf`. The gas of
    ///      those views is bounded by the transaction the keeper chose to send for that order.
    /// @param order Decoded signed order.
    /// @param input Order's input token.
    function _requireFundable(V3DutchOrder memory order, IERC20 input) private view {
        if (order.info.deadline < block.timestamp) revert OrderExpired();
        address swapper = order.info.swapper;
        uint256 nonce = order.info.nonce;
        if (ISignatureTransfer(address(permit2)).nonceBitmap(swapper, nonce >> 8) & (1 << (nonce & 0xff)) != 0) {
            revert NonceUsed();
        }
        uint256 amount = _inputAmount(order);
        if (input.balanceOf(swapper) < amount) revert SwapperBalanceTooLow();
        if (input.allowance(swapper, address(permit2)) < amount) revert SwapperAllowanceTooLow();
    }

    /// @dev Returns the input the reactor takes for `order` in this block, resolved as `V3DutchOrderReactor._resolve`
    ///      resolves it: the cosigned input when nonzero, the base-fee adjustment bounded to `maxAmount`, then the
    ///      input curve at `block.number`. That is the reactor's block number on every chain except Arbitrum One
    ///      (42161) and Robinhood Chain (4663), where the pinned `BlockNumberish` reads ArbSys instead; on Arc it is
    ///      `block.number`. A cosigned input above the signed start is left for the reactor to refuse
    ///      (`InvalidCosignerInput`). The order is not modified.
    /// @param order Decoded signed order.
    /// @return amount Input amount the reactor would transfer from the trader.
    function _inputAmount(V3DutchOrder memory order) private view returns (uint256 amount) {
        V3DutchInput memory base = order.baseInput;
        amount = base.startAmount;
        uint256 cosigned = order.cosignerData.inputAmount;
        if (cosigned != 0 && cosigned <= amount) amount = cosigned;
        uint256 adjustment = base.adjustmentPerGweiBaseFee;
        if (adjustment != 0) {
            // Rounded in the trader's favour, as the reactor's `_computeDelta`.
            int256 gasDeltaWei = block.basefee.sub(order.startingBaseFee);
            int256 delta = gasDeltaWei >= 0
                ? int256(adjustment.mulDivDown(uint256(gasDeltaWei), 1 gwei))
                : -int256(adjustment.mulDivUp(uint256(-gasDeltaWei), 1 gwei));
            amount = amount.boundedAdd(delta, 0, base.maxAmount);
        }
        V3DutchInput memory adjusted = V3DutchInput(base.token, amount, base.curve, base.maxAmount, adjustment);
        amount = adjusted.decay(order.cosignerData.decayStartBlock, block.number).amount;
    }

    /// @dev Returns the trader's output plus any reactor protocol fee. Fees must be in the output token: the whole
    ///      input goes to the swap and fees, so an input-token fee cannot be paid and the fill is refused (the order
    ///      stays open, no funds move).
    /// @param order Resolved order; `outputs[0]` is the trader's.
    /// @param output Output token.
    /// @return owed Total the reactor will take from this contract.
    function _owed(ResolvedOrder memory order, address output) private pure returns (uint256 owed) {
        uint256 n = order.outputs.length;
        if (n == 0) revert InvalidOutputs();
        for (uint256 i; i < n; ++i) {
            if (order.outputs[i].token != output) revert FeeOutputUnsupported();
            if (order.outputs[i].recipient == address(0)) revert InvalidOutputs();
            owed += order.outputs[i].amount;
        }
    }

    /// @dev Builds the Universal Router call for one exact-input swap on `key`. Launch pools swap with the swap minimum
    ///      and pay Launch's hook fee; other pools pay the app fee from the USDC side (before a buy, as a portion of a
    ///      sell's output) and sweep the rest here.
    /// @param key Pool to swap on.
    /// @param input Token this contract spends.
    /// @param output Token this contract receives.
    /// @param swapAmount Input swapped, after the app and execution fees on a buy.
    /// @param appFee App fee paid from a buy's USDC input; zero otherwise.
    /// @param required Least output this contract must receive: the reactor's outputs, plus the fee on a sell.
    /// @param swapper Trader, credited by Launch's hook for referrals.
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
