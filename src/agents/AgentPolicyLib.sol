// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {
    Policy,
    MAX_BPS,
    MAX_DEADLINE,
    F_MAX_TRADE_USDC,
    F_PERIOD_SPEND_CAP,
    F_PER_TOKEN_PERIOD_CAP,
    F_PERIOD_SELL_CAP,
    F_MAX_ACTIONS_PER_PERIOD,
    F_LAUNCHES_PER_PERIOD,
    F_MAX_PRICE_IMPACT_BPS,
    F_MAX_SNIPE_BPS,
    F_MIN_TOKEN_AGE_BLOCKS,
    F_MAX_DEADLINE_SECONDS
} from "./AgentTypes.sol";

/// @notice Pure policy helpers of agent accounts.
library AgentPolicyLib {
    /// @notice Reverts unless every field of `p` is within the beta ceilings `c`.
    /// @dev Field by field in `Policy` struct order, reverting `BetaCeiling(field)` at the first looser field: caps,
    ///      counts, impact, snipe and deadline must be `<=` their ceiling; `minTokenAgeBlocks` must be `>=` its
    ///      ceiling, which acts as a floor (zero in the beta, so never binding); `allowlistOnly` is not limited.
    /// @param p Policy to check (amounts usdc6).
    /// @param c Beta ceilings (amounts usdc6).
    function checkCeilings(Policy memory p, Policy memory c) internal pure {
        if (p.maxTradeUsdc > c.maxTradeUsdc) revert IAgentAccount.BetaCeiling(F_MAX_TRADE_USDC);
        if (p.periodSpendCap > c.periodSpendCap) revert IAgentAccount.BetaCeiling(F_PERIOD_SPEND_CAP);
        if (p.perTokenPeriodCap > c.perTokenPeriodCap) revert IAgentAccount.BetaCeiling(F_PER_TOKEN_PERIOD_CAP);
        if (p.periodSellCap > c.periodSellCap) revert IAgentAccount.BetaCeiling(F_PERIOD_SELL_CAP);
        if (p.maxActionsPerPeriod > c.maxActionsPerPeriod) revert IAgentAccount.BetaCeiling(F_MAX_ACTIONS_PER_PERIOD);
        if (p.launchesPerPeriod > c.launchesPerPeriod) revert IAgentAccount.BetaCeiling(F_LAUNCHES_PER_PERIOD);
        if (p.maxPriceImpactBps > c.maxPriceImpactBps) revert IAgentAccount.BetaCeiling(F_MAX_PRICE_IMPACT_BPS);
        if (p.maxSnipeBps > c.maxSnipeBps) revert IAgentAccount.BetaCeiling(F_MAX_SNIPE_BPS);
        if (p.minTokenAgeBlocks < c.minTokenAgeBlocks) revert IAgentAccount.BetaCeiling(F_MIN_TOKEN_AGE_BLOCKS);
        if (p.maxDeadlineSeconds > c.maxDeadlineSeconds) revert IAgentAccount.BetaCeiling(F_MAX_DEADLINE_SECONDS);
    }

    /// @notice Reverts unless `p` is well formed, whatever the ceilings.
    /// @dev `InvalidPolicy(field)`: `maxPriceImpactBps` and `maxSnipeBps` at most 10,000; `maxDeadlineSeconds` in
    ///      `[1, 600]`.
    /// @param p Policy to check.
    function validate(Policy memory p) internal pure {
        if (p.maxPriceImpactBps > MAX_BPS) revert IAgentAccount.InvalidPolicy(F_MAX_PRICE_IMPACT_BPS);
        if (p.maxSnipeBps > MAX_BPS) revert IAgentAccount.InvalidPolicy(F_MAX_SNIPE_BPS);
        if (p.maxDeadlineSeconds == 0 || p.maxDeadlineSeconds > MAX_DEADLINE) {
            revert IAgentAccount.InvalidPolicy(F_MAX_DEADLINE_SECONDS);
        }
    }
}
