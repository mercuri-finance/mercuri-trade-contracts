// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Account-wide trading policy, shared by all of an account's agents.
/// @dev Field order is the field index reported by `BetaCeiling(field)` and `InvalidPolicy(field)`: see the `F_*`
///      constants below. The same shape carries the factory's beta ceilings, where `allowlistOnly` is ignored and
///      `minTokenAgeBlocks` is a floor (a higher value is tighter).
struct Policy {
    /// @dev Per action, usdc6: a curve buy's input, a launch's total, a pool buy's input and a sell's cost-basis value.
    uint64 maxTradeUsdc;
    /// @dev Gross USDC spent per period across all agents, usdc6, measured as the native balance delta.
    uint64 periodSpendCap;
    /// @dev Gross USDC spent per token per period, usdc6, measured.
    uint64 perTokenPeriodCap;
    /// @dev Sells per period valued at the account's cost basis, usdc6.
    uint64 periodSellCap;
    /// @dev Agent actions per period.
    uint32 maxActionsPerPeriod;
    /// @dev Launches per period.
    uint16 launchesPerPeriod;
    /// @dev Largest price impact of the account's own trade, in basis points; at most 10,000.
    uint16 maxPriceImpactBps;
    /// @dev Buys revert while the curve's current snipe tax is above this, in basis points; at most 10,000.
    uint16 maxSnipeBps;
    /// @dev Buys revert until the curve is at least this many blocks old.
    uint32 minTokenAgeBlocks;
    /// @dev An agent's deadline must lie in `[now, now + maxDeadlineSeconds]`; in `[1, 600]` seconds.
    uint32 maxDeadlineSeconds;
    /// @dev When true, buys (curve and pool) need an owner-allowlisted token; sells stay open.
    bool allowlistOnly;
}

/// @notice One agent key's standing in an account.
struct Agent {
    /// @dev True from activation until revocation; an expired agent stays `active` but cannot act.
    bool active;
    /// @dev Unix time (seconds) from which the agent can no longer act.
    uint40 expiresAt;
    /// @dev Bitmask of `P_*` permissions.
    uint16 permissions;
}

/// @notice An account's usage in its current period.
struct Usage {
    /// @dev `block.timestamp / periodSeconds` of the period this usage belongs to.
    uint64 periodId;
    /// @dev USDC spent this period, usdc6.
    uint64 spent;
    /// @dev Sells this period at cost-basis value, usdc6.
    uint64 sold;
    /// @dev Agent actions this period.
    uint32 actions;
    /// @dev Launches this period.
    uint16 launches;
}

/// @notice An account's recorded cost basis in one token.
struct Basis {
    /// @dev USDC paid for `tokens`, usdc6.
    uint128 costUsdc;
    /// @dev Tokens bought and still held, in the token's 18-decimal units.
    uint128 tokens;
}

/// @notice Parameters of a new account, passed to `AgentAccountFactory.createAccount`.
struct InitParams {
    /// @dev Bound permanently in the FeeManager when non-zero; may not be the account itself.
    address referrer;
    /// @dev Initial policy; takes effect immediately but is checked against the beta ceilings.
    Policy policy;
    /// @dev Length of a usage period in seconds, in `[MIN_PERIOD, MAX_PERIOD]`; never changes.
    uint32 periodSeconds;
    /// @dev Delay before a widening change takes effect, in seconds, at most `MAX_DELAY`.
    uint32 increaseDelay;
    /// @dev First agent key, active immediately; zero for none.
    address firstAgent;
    /// @dev First agent's expiry, Unix seconds, in `(now, now + MAX_AGENT_TTL]`; ignored without a first agent.
    uint40 firstAgentExpiresAt;
    /// @dev First agent's `P_*` permissions, non-zero and within `P_ALL`; ignored without a first agent.
    uint16 firstAgentPermissions;
}

// Agent permission bits.
uint16 constant P_BUY = 1;
uint16 constant P_SELL = 2;
uint16 constant P_LAUNCH = 4;
uint16 constant P_POOL_SWAP = 8;
uint16 constant P_CLAIM = 16;
uint16 constant P_SWEEP_TO_OWNER = 32;
uint16 constant P_ALL = 63;

// `AgentAction` action ids.
uint8 constant ACTION_BUY = 1;
uint8 constant ACTION_SELL = 2;
uint8 constant ACTION_LAUNCH = 3;
uint8 constant ACTION_POOL_BUY = 4;
uint8 constant ACTION_POOL_SELL = 5;
uint8 constant ACTION_CLAIM = 6;
uint8 constant ACTION_SWEEP = 7;

// Policy field indices, in `Policy` struct order, as reported by `BetaCeiling` and `InvalidPolicy`.
uint8 constant F_MAX_TRADE_USDC = 0;
uint8 constant F_PERIOD_SPEND_CAP = 1;
uint8 constant F_PER_TOKEN_PERIOD_CAP = 2;
uint8 constant F_PERIOD_SELL_CAP = 3;
uint8 constant F_MAX_ACTIONS_PER_PERIOD = 4;
uint8 constant F_LAUNCHES_PER_PERIOD = 5;
uint8 constant F_MAX_PRICE_IMPACT_BPS = 6;
uint8 constant F_MAX_SNIPE_BPS = 7;
uint8 constant F_MIN_TOKEN_AGE_BLOCKS = 8;
uint8 constant F_MAX_DEADLINE_SECONDS = 9;
uint8 constant F_ALLOWLIST_ONLY = 10;

// Shared limits.
uint8 constant MAX_AGENTS = 8;
uint256 constant MAX_AGENT_TTL = 180 days;
uint256 constant QUEUE_TTL = 7 days;
uint256 constant MAX_DELAY = 7 days;
uint256 constant MIN_PERIOD = 1 hours;
uint256 constant MAX_PERIOD = 7 days;
uint256 constant MAX_DEADLINE = 600;
uint256 constant MAX_BPS = 10_000;
uint256 constant GUARDIAN_PAUSE = 72 hours;
uint256 constant GUARDIAN_COOLDOWN = 72 hours;
/// @dev Native USDC wei (18 decimals) per usdc6 unit.
uint256 constant SCALE = 1e12;
