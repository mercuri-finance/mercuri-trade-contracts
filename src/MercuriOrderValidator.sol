// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IValidationCallback} from "../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {ResolvedOrder} from "../lib/uniswapx/src/base/ReactorStructs.sol";

/// @notice Checks a Mercurifi order's trader-signed condition when the reactor resolves it: only the bound filler may
///         settle it, and a take-profit or stop-loss settles only while its signed pool's price is at or beyond the
///         signed trigger. The condition is `OrderInfo.additionalValidationData`, inside the trader's Permit2
///         signature: `abi.encode(uint8 version, uint8 kind, bytes32 poolId, uint160 triggerSqrtPriceX96)`.
/// @dev Immutable: no owner, pause, upgrade or storage. Deployed by its filler's constructor, so each names the other
///      for life; replacing either replaces both, and orders signed for the old pair stay fillable only by it.
///      The reactor calls `validate` before it pulls the input. The pool binding is enforced by the filler, which
///      swaps only through the pool whose `keccak256(abi.encode(key))` is the signed `poolId` and whose currencies are
///      the order's input and output; this contract reads that pool's price.
///
///      The trigger is a v4 `sqrtPriceX96` of the signed pool (currency1 per currency0, raw units), and is compared
///      with the pool's current spot price before the swap, inclusive. Take-profit fires when the order's rate,
///      output per input, has risen to the trigger; stop-loss when it has fallen to it. Pool currencies are sorted,
///      so the input is currency0 exactly when its address is the lower one:
///
///      | Order           | USDC is   | Input is  | Token price in USDC | Take-profit fires | Stop-loss fires  |
///      | --------------- | --------- | --------- | ------------------- | ----------------- | ---------------- |
///      | Sell token→USDC | currency1 | currency0 | rises with price    | price >= trigger  | price <= trigger |
///      | Sell token→USDC | currency0 | currency1 | falls with price    | price <= trigger  | price >= trigger |
///      | Buy USDC→token  | currency0 | currency0 | falls with price    | price >= trigger  | price <= trigger |
///      | Buy USDC→token  | currency1 | currency1 | rises with price    | price <= trigger  | price >= trigger |
///
///      ("price" is the pool's `sqrtPriceX96`.) A sell's take-profit therefore fires as the token's USDC price rises
///      to the trigger and its stop-loss as it falls; a buy's take-profit as the token's price falls and its
///      stop-loss as it rises. The spot price can be moved within a block; the signed minimum output, not this
///      check, bounds what a fill can cost the trader.
contract MercuriOrderValidator is IValidationCallback {
    using StateLibrary for IPoolManager;

    /// @notice The only condition encoding this validator accepts.
    uint8 public constant VERSION = 1;
    /// @notice Kind of an order that fills at its signed minimum or better, with no price condition.
    uint8 public constant KIND_LIMIT = 0;
    /// @notice Kind of an order that fills only once its rate (output per input) has risen to the trigger.
    uint8 public constant KIND_TAKE_PROFIT = 1;
    /// @notice Kind of an order that fills only once its rate (output per input) has fallen to the trigger.
    uint8 public constant KIND_STOP_LOSS = 2;

    uint256 private constant DATA_LENGTH = 128;

    /// @notice The only filler allowed to settle orders that name this validator.
    address public immutable filler;
    /// @notice Uniswap v4 PoolManager whose pool state the trigger is read from.
    IPoolManager public immutable poolManager;

    /// @notice The filler or the pool manager is the zero address.
    error ZeroAddress();
    /// @notice The order is being settled by a filler other than `filler`.
    error WrongFiller();
    /// @notice The signed condition is not exactly four ABI words, or its trigger does not fit in 160 bits.
    error InvalidValidationData();
    /// @notice The signed condition's version is not `VERSION`.
    error UnsupportedVersion();
    /// @notice The signed condition's kind is not a limit, take-profit or stop-loss.
    error UnknownKind();
    /// @notice A limit's trigger is not zero, or a take-profit's or stop-loss's trigger is outside v4's price range.
    error InvalidTrigger();
    /// @notice The signed pool has no price: it is not initialized in `poolManager`.
    error PoolNotInitialized();
    /// @notice The signed pool's current price has not reached the take-profit or stop-loss trigger.
    error TriggerNotReached();

    /// @notice Binds this validator to its filler and pool manager for life.
    /// @dev Reverts `ZeroAddress` if either is zero. The filler deploys this contract from its own constructor.
    /// @param filler_ The filler that alone may settle orders naming this validator.
    /// @param poolManager_ Uniswap v4 PoolManager holding the pools orders are signed against.
    constructor(address filler_, IPoolManager poolManager_) {
        if (filler_ == address(0) || address(poolManager_) == address(0)) revert ZeroAddress();
        filler = filler_;
        poolManager = poolManager_;
    }

    /// @notice Refuses the order unless `filler` settles it and, for a take-profit or stop-loss, the signed pool's
    ///         price has reached the trigger in the order's direction (see the contract table).
    /// @dev A view the reactor calls before any transfer. Malformed data reverts with a typed error, never a panic: a
    ///      word is range-checked before it is narrowed. The order's first output is the trader's; the filler refuses
    ///      any other shape before calling the reactor.
    /// @param orderFiller The address that called the reactor to settle the order.
    /// @param resolvedOrder The order as the reactor resolved it, with its signed `additionalValidationData`.
    function validate(address orderFiller, ResolvedOrder calldata resolvedOrder) external view {
        if (orderFiller != filler) revert WrongFiller();
        (uint8 kind, bytes32 poolId, uint160 trigger) = _condition(resolvedOrder.info.additionalValidationData);
        if (kind == KIND_LIMIT) return;
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(poolId));
        if (price == 0) revert PoolNotInitialized();
        // The rate (output per input) rises with the price exactly when the input is currency0.
        bool rateRisesWithPrice = address(resolvedOrder.input.token) < resolvedOrder.outputs[0].token;
        bool atOrAbove = (kind == KIND_TAKE_PROFIT) == rateRisesWithPrice;
        if (atOrAbove ? price < trigger : price > trigger) revert TriggerNotReached();
    }

    /// @dev Decodes and checks the signed condition. Each field is read as a whole word first, so a value that does not
    ///      fit its type is refused with a typed error rather than by the ABI decoder.
    /// @param data The order's `additionalValidationData`.
    /// @return kind `KIND_LIMIT`, `KIND_TAKE_PROFIT` or `KIND_STOP_LOSS`.
    /// @return poolId The signed pool's id.
    /// @return trigger The signed trigger `sqrtPriceX96`; zero for a limit.
    function _condition(bytes calldata data) private pure returns (uint8 kind, bytes32 poolId, uint160 trigger) {
        if (data.length != DATA_LENGTH) revert InvalidValidationData();
        (uint256 version, uint256 rawKind, bytes32 pool, uint256 rawTrigger) =
            abi.decode(data, (uint256, uint256, bytes32, uint256));
        if (version != VERSION) revert UnsupportedVersion();
        if (rawKind > KIND_STOP_LOSS) revert UnknownKind();
        if (rawTrigger > type(uint160).max) revert InvalidValidationData();
        kind = uint8(rawKind);
        poolId = pool;
        trigger = uint160(rawTrigger);
        if (kind == KIND_LIMIT) {
            if (trigger != 0) revert InvalidTrigger();
        } else if (trigger < TickMath.MIN_SQRT_PRICE || trigger >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidTrigger();
        }
    }
}
