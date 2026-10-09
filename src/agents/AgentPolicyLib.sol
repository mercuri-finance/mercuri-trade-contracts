// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
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
        uint256[11] memory pw = _words(p);
        uint256[11] memory cw = _words(c);
        for (uint256 i; i < F_ALLOWLIST_ONLY; ++i) {
            if (i == F_MIN_TOKEN_AGE_BLOCKS ? pw[i] < cw[i] : pw[i] > cw[i]) {
                revert IAgentAccount.BetaCeiling(uint8(i));
            }
        }
    }

    /// @notice Reverts unless `p` is well formed, whatever the ceilings.
    /// @dev `InvalidPolicy(field)`: `maxPriceImpactBps` and `maxSnipeBps` at most 10,000; `maxDeadlineSeconds` in
    ///      `[1, 600]`.
    /// @param p Policy to check.
    function validate(Policy memory p) internal pure {
        (bool ok, uint8 field) = checkShape(p);
        if (!ok) revert IAgentAccount.InvalidPolicy(field);
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
        uint256[11] memory c = _words(current);
        uint256[11] memory n = _words(next);
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
        uint256[11] memory c = _words(current);
        uint256[11] memory n = _words(next);
        for (uint256 i; i < POLICY_FIELDS; ++i) {
            if (_narrows(i, c[i], n[i])) c[i] = n[i];
        }
        return _fromWords(c);
    }

    /// @notice The policy a queued change applies: field by field, `target` where `current` still equals the
    ///         `snapshot` taken at queue time, and `current` where the field changed since.
    /// @dev A field changes while an item waits only through an immediate tightening or another executed queued
    ///      item; either way the newer value wins, so an older queued widening never undoes a later tightening.
    /// @param current Policy in force (amounts usdc6).
    /// @param snapshot Policy in force when the change was queued (amounts usdc6).
    /// @param target Policy the owner asked for (amounts usdc6).
    /// @return The merged policy (amounts usdc6).
    function merge(Policy memory current, Policy memory snapshot, Policy memory target)
        internal
        pure
        returns (Policy memory)
    {
        uint256[11] memory c = _words(current);
        uint256[11] memory s = _words(snapshot);
        uint256[11] memory t = _words(target);
        for (uint256 i; i < POLICY_FIELDS; ++i) {
            if (c[i] == s[i]) c[i] = t[i];
        }
        return _fromWords(c);
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

    /// @dev A policy as its 11 ABI words, one per field in struct order (a static struct encodes field by field).
    /// @param p The policy.
    /// @return The field values.
    function _words(Policy memory p) private pure returns (uint256[11] memory) {
        return abi.decode(abi.encode(p), (uint256[11]));
    }

    /// @dev Inverse of `_words`; every word comes from a field of the same type, so the decode cannot fail.
    /// @param w The field values.
    /// @return The policy.
    function _fromWords(uint256[11] memory w) private pure returns (Policy memory) {
        return abi.decode(abi.encode(w), (Policy));
    }
}
