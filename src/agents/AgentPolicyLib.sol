// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentPolicyRegistry} from "./interfaces/IAgentPolicyRegistry.sol";
import {
    Policy,
    MAX_BPS,
    MAX_DEADLINE,
    F_MAX_PRICE_IMPACT_BPS,
    F_MAX_SNIPE_BPS,
    F_MIN_TOKEN_AGE_BLOCKS,
    F_MAX_DEADLINE_SECONDS,
    F_ALLOWLIST_ONLY
} from "./AgentTypes.sol";

/// @dev Number of `Policy` fields.
uint256 constant POLICY_FIELDS = 11;

/// @notice Pure policy helpers of agent accounts.
library AgentPolicyLib {
    /// @notice Reverts unless every field of `p` is within the beta ceilings `c`.
    /// @dev Field by field in `Policy` struct order, reverting `BetaCeiling(field)` at the first looser field: caps,
    ///      counts, impact, snipe and deadline must be `<=` their ceiling; `minTokenAgeBlocks` must be `>=` its
    ///      ceiling, which acts as a floor (zero in the beta, so never binding); `allowlistOnly` is not limited.
    /// @param p Policy to check (amounts usdc6).
    /// @param c Beta ceilings (amounts usdc6).
    function checkCeilings(Policy memory p, Policy memory c) internal pure {
        uint256[11] memory pw = words(p);
        uint256[11] memory cw = words(c);
        for (uint256 i; i < F_ALLOWLIST_ONLY; ++i) {
            if (i == F_MIN_TOKEN_AGE_BLOCKS ? pw[i] < cw[i] : pw[i] > cw[i]) {
                revert IAgentPolicyRegistry.BetaCeiling(uint8(i));
            }
        }
    }

    /// @notice Reverts unless `p` is well formed, whatever the ceilings.
    /// @dev `InvalidPolicy(field)`: `maxPriceImpactBps` and `maxSnipeBps` at most 10,000; `maxDeadlineSeconds` in
    ///      `[1, 600]`.
    /// @param p Policy to check.
    function validate(Policy memory p) internal pure {
        (bool ok, uint8 field) = checkShape(p);
        if (!ok) revert IAgentPolicyRegistry.InvalidPolicy(field);
    }

    /// @notice Whether `p` is well formed: the bounds `validate` enforces, also applied to the factory's ceilings.
    /// @param p Policy (or ceilings) to check.
    /// @return ok True when every bounded field is in range.
    /// @return field Index of the first out-of-range field in `Policy` struct order; zero when `ok`.
    function checkShape(Policy memory p) internal pure returns (bool ok, uint8 field) {
        if (p.maxPriceImpactBps > MAX_BPS) return (false, F_MAX_PRICE_IMPACT_BPS);
        if (p.maxSnipeBps > MAX_BPS) return (false, F_MAX_SNIPE_BPS);
        if (p.maxDeadlineSeconds == 0 || p.maxDeadlineSeconds > MAX_DEADLINE) return (false, F_MAX_DEADLINE_SECONDS);
        return (true, 0);
    }

    /// @notice Whether every field of `next` is at least as tight as in `current`, so applying it needs no delay.
    /// @dev Caps, counts, impact, snipe and deadline: `next <= current`. `minTokenAgeBlocks`: `next >= current`.
    ///      `allowlistOnly`: `next || !current`. Equal policies are narrowing.
    /// @param current Policy in force (amounts usdc6).
    /// @param next Proposed policy (amounts usdc6).
    /// @return True when no field of `next` is looser than in `current`.
    function isNarrowing(Policy memory current, Policy memory next) internal pure returns (bool) {
        uint256[11] memory c = words(current);
        uint256[11] memory n = words(next);
        for (uint256 i; i < POLICY_FIELDS; ++i) {
            if (!_narrows(i, c[i], n[i])) return false;
        }
        return true;
    }

    /// @notice The immediate part of a policy change: each field of `next` that is at least as tight as in
    ///         `current`, and `current`'s value for each field that `next` would loosen.
    /// @dev Uses the per-field rule of `isNarrowing`. The result is always narrowing from `current`, and equals `next`
    ///      exactly when `isNarrowing(current, next)`.
    /// @param current Policy in force (amounts usdc6).
    /// @param next Proposed policy (amounts usdc6).
    /// @return The policy to apply now (amounts usdc6).
    function tighten(Policy memory current, Policy memory next) internal pure returns (Policy memory) {
        uint256[11] memory c = words(current);
        uint256[11] memory n = words(next);
        for (uint256 i; i < POLICY_FIELDS; ++i) {
            if (_narrows(i, c[i], n[i])) c[i] = n[i];
        }
        return _fromWords(c);
    }

    /// @notice The policy a queued change applies: field by field, `target` where the field was last written at or
    ///         before the item was queued (`lastWrite[i] <= seq`), and `current` where it was written since.
    /// @dev Versions, not values, decide: a field written after queueing (an immediate tightening, or another
    ///      executed item) keeps its value even if it later returns to the value it had at queue time, so an older
    ///      queued widening never undoes a later change.
    /// @param current Policy in force (amounts usdc6).
    /// @param target Policy the owner asked for (amounts usdc6).
    /// @param lastWrite Write sequence number of each field's last change, in `Policy` struct order.
    /// @param seq The account's write sequence number when the change was queued.
    /// @return The merged policy (amounts usdc6).
    function merge(Policy memory current, Policy memory target, uint64[11] memory lastWrite, uint64 seq)
        internal
        pure
        returns (Policy memory)
    {
        uint256[11] memory c = words(current);
        uint256[11] memory t = words(target);
        for (uint256 i; i < POLICY_FIELDS; ++i) {
            if (lastWrite[i] <= seq) c[i] = t[i];
        }
        return _fromWords(c);
    }

    /// @notice Price impact of a curve buy: how far its average price lies above the marginal price before it.
    /// @dev `avg = ceil(net * 1e18 / tokensOut)`, impact `ceil((avg - price) * 10,000 / price)`, zero when `avg` is not
    ///      above `price`. Both roundings are against the trade. Callers pass `tokensOut > 0` and `price > 0`.
    /// @param net Native USDC wei priced on the curve (the quote's used amount minus fee and tax).
    /// @param tokensOut Quoted tokens, 18-decimal units.
    /// @param price Marginal price before the trade, native wei per whole token.
    /// @return Impact, basis points.
    function buyImpactBps(uint256 net, uint256 tokensOut, uint256 price) internal pure returns (uint256) {
        uint256 avg = Math.mulDiv(net, 1e18, tokensOut, Math.Rounding.Ceil);
        return avg > price ? Math.mulDiv(avg - price, MAX_BPS, price, Math.Rounding.Ceil) : 0;
    }

    /// @notice Price impact of a curve sell: how far its average price lies below the marginal price before it.
    /// @dev `avg = floor(gross * 1e18 / tokensIn)`, impact `ceil((price - avg) * 10,000 / price)`, zero when `avg` is
    ///      not below `price`. Both roundings are against the trade. Callers pass `tokensIn > 0` and `price > 0`.
    /// @param gross Quoted proceeds plus fee, native USDC wei.
    /// @param tokensIn Tokens sold, 18-decimal units.
    /// @param price Marginal price before the trade, native wei per whole token.
    /// @return Impact, basis points.
    function sellImpactBps(uint256 gross, uint256 tokensIn, uint256 price) internal pure returns (uint256) {
        uint256 avg = Math.mulDiv(gross, 1e18, tokensIn);
        return price > avg ? Math.mulDiv(price - avg, MAX_BPS, price, Math.Rounding.Ceil) : 0;
    }

    /// @notice Price impact of a pool swap: how far the pool price moved, from `sqrtPriceX96` before and after.
    /// @dev `r = floor(after * 1e18 / before)`, `ratio = floor(r * r / 1e18)` (the price ratio scaled by 1e18) and
    ///      impact `floor(|ratio - 1e18| * 10,000 / 1e18)`. Symmetric in direction; callers pass `sqrtBefore > 0`
    ///      (an initialised pool).
    /// @param sqrtBefore Pool `sqrtPriceX96` before the swap (Q64.96).
    /// @param sqrtAfter Pool `sqrtPriceX96` after the swap (Q64.96).
    /// @return Impact, basis points.
    function poolImpactBps(uint256 sqrtBefore, uint256 sqrtAfter) internal pure returns (uint256) {
        uint256 r = Math.mulDiv(sqrtAfter, 1e18, sqrtBefore);
        uint256 ratio = Math.mulDiv(r, r, 1e18);
        uint256 diff = ratio > 1e18 ? ratio - 1e18 : 1e18 - ratio;
        return diff * MAX_BPS / 1e18;
    }

    /// @dev Per-field narrowing rule. `minTokenAgeBlocks` is a floor, so higher is tighter; for `allowlistOnly`
    ///      (0 or 1) `next >= current` is `next || !current`; every other field is tighter when lower or equal.
    /// @param field Field index in `Policy` struct order.
    /// @param current Current value.
    /// @param next Proposed value.
    /// @return True when `next` is at least as tight as `current`.
    function _narrows(uint256 field, uint256 current, uint256 next) private pure returns (bool) {
        return field == F_MIN_TOKEN_AGE_BLOCKS || field == F_ALLOWLIST_ONLY ? next >= current : next <= current;
    }

    /// @notice A policy as its 11 ABI words, one per field in `Policy` struct order (a static struct encodes field
    ///         by field; `allowlistOnly` is 0 or 1).
    /// @param p The policy.
    /// @return The field values.
    function words(Policy memory p) internal pure returns (uint256[11] memory) {
        return abi.decode(abi.encode(p), (uint256[11]));
    }

    /// @dev Inverse of `words`; every word comes from a field of the same type, so the decode cannot fail.
    /// @param w The field values.
    /// @return The policy.
    function _fromWords(uint256[11] memory w) private pure returns (Policy memory) {
        return abi.decode(abi.encode(w), (Policy));
    }
}
