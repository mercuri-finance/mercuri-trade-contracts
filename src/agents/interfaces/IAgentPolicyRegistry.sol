// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Policy, Agent, InitParams} from "../AgentTypes.sol";

/// @notice Configuration and usage of every Mercurifi agent account of one factory: owner, policy, agents, allowlist,
///         the delayed-widening queue, the owner pause and the per-period usage counters. One immutable singleton per
///         factory, with no admin and no owner of its own; it emits every configuration event, each with the
///         account as its first indexed parameter. Funds, cost basis and trading stay in the account.
interface IAgentPolicyRegistry {
    /// @notice A policy took effect, at creation or later.
    /// @param account The agent account.
    /// @param policy The full policy now in force (amounts usdc6).
    event PolicyApplied(address indexed account, Policy policy);
    /// @notice An agent key became able to act, or an active agent's terms changed (narrowed now or widened from the
    ///         queue). The event always carries the terms now in force.
    /// @param account The agent account.
    /// @param agent The agent key.
    /// @param expiresAt Unix time (seconds) from which the agent can no longer act.
    /// @param permissions Bitmask of `P_*` permissions.
    event AgentActivated(address indexed account, address indexed agent, uint40 expiresAt, uint16 permissions);
    /// @notice An agent addition or widening was queued.
    /// @param account The agent account.
    /// @param id Queue id, per account.
    /// @param agent The agent key.
    /// @param expiresAt Requested expiry, Unix seconds.
    /// @param permissions Requested `P_*` bitmask.
    /// @param eta ETA at queue time, Unix seconds: queue time plus the delay then. A later delay raise moves it, so
    ///        read `queued(account, id)` for the effective ETA; the item expires 7 days after the effective ETA.
    event AgentQueued(
        address indexed account,
        uint256 indexed id,
        address indexed agent,
        uint40 expiresAt,
        uint16 permissions,
        uint40 eta
    );
    /// @notice An address was retired forever, and revoked if it was an active agent.
    /// @param account The agent account.
    /// @param agent The address.
    /// @param expiresAt Expiry it had, Unix seconds; zero if it was never an agent.
    /// @param permissions `P_*` bitmask it had; zero if it was never an agent.
    event AgentRevoked(address indexed account, address indexed agent, uint40 expiresAt, uint16 permissions);
    /// @notice A policy widening was queued.
    /// @param account The agent account.
    /// @param id Queue id, per account.
    /// @param eta ETA at queue time, Unix seconds: queue time plus the delay then. A later delay raise moves it, so
    ///        read `queued(account, id)` for the effective ETA; the item expires 7 days after the effective ETA.
    /// @param policy The full target policy (amounts usdc6); fields written after queueing keep their value.
    event PolicyQueued(address indexed account, uint256 indexed id, uint40 eta, Policy policy);
    /// @notice A queued item was cancelled by the owner, or found void on an execution attempt after the account's
    ///         epoch moved (agents paused or ownership transferred).
    /// @param account The agent account.
    /// @param id Queue id, per account.
    event QueuedCancelled(address indexed account, uint256 indexed id);
    /// @notice A queued item was executed.
    /// @param account The agent account.
    /// @param id Queue id, per account.
    event QueuedExecuted(address indexed account, uint256 indexed id);
    /// @notice A token was added to or removed from the buy allowlist.
    /// @param account The agent account.
    /// @param token The token.
    /// @param allowed Whether buys of it pass when `allowlistOnly` is set.
    event TokenAllowed(address indexed account, address indexed token, bool allowed);
    /// @notice Adding a token to the buy allowlist was queued.
    /// @param account The agent account.
    /// @param id Queue id, per account.
    /// @param token The token.
    /// @param eta ETA at queue time, Unix seconds: queue time plus the delay then. A later delay raise moves it, so
    ///        read `queued(account, id)` for the effective ETA; the item expires 7 days after the effective ETA.
    event TokenAllowQueued(address indexed account, uint256 indexed id, address indexed token, uint40 eta);
    /// @notice The owner paused or unpaused the account's agents. Pausing voids every queued item.
    /// @param account The agent account.
    /// @param paused True when paused.
    event AgentsPaused(address indexed account, bool paused);
    /// @notice The widening delay changed.
    /// @param account The agent account.
    /// @param delay New delay, seconds.
    event IncreaseDelaySet(address indexed account, uint32 delay);
    /// @notice Lowering the widening delay was queued.
    /// @param account The agent account.
    /// @param id Queue id, per account.
    /// @param delay Requested delay, seconds.
    /// @param eta ETA at queue time, Unix seconds: queue time plus the delay then. A later delay raise moves it, so
    ///        read `queued(account, id)` for the effective ETA; the item expires 7 days after the effective ETA.
    event IncreaseDelayQueued(address indexed account, uint256 indexed id, uint32 delay, uint40 eta);
    /// @notice An ownership transfer was queued; only `newOwner` can complete it, through `acceptOwnership`.
    /// @param account The agent account.
    /// @param id Queue id, per account.
    /// @param newOwner The proposed owner.
    /// @param eta ETA at queue time, Unix seconds: queue time plus the delay then. A later delay raise moves it, so
    ///        read `queued(account, id)` for the effective ETA from which `newOwner` may accept; it expires 7 days
    ///        after it.
    event OwnershipQueued(address indexed account, uint256 indexed id, address indexed newOwner, uint40 eta);
    /// @notice Ownership of the account moved. Every item queued before it is void.
    /// @param account The agent account.
    /// @param previousOwner The former owner.
    /// @param newOwner The new owner.
    event AccountOwnerChanged(address indexed account, address indexed previousOwner, address indexed newOwner);

    /// @notice Only the factory may register accounts.
    error NotFactory();
    /// @notice The account is already registered.
    error AlreadyInitialized();
    /// @notice The caller is not a registered agent account.
    error NotAccount();
    /// @notice The period length is outside one hour to seven days.
    error PeriodOutOfRange();
    /// @notice The widening delay is above seven days (at creation or in `setIncreaseDelay`).
    error DelayOutOfRange();
    /// @notice The agent key (to add, change, revoke or rotate) is zero, the owner or the account itself.
    error InvalidAgent();
    /// @notice The agent's expiry is not after now, or is more than 180 days away.
    error AgentExpiryOutOfRange();
    /// @notice The agent's permissions are empty or contain an unknown bit.
    error InvalidPermissions();
    /// @notice A policy field is looser than the factory's beta ceiling.
    /// @param field Index of the field in `Policy` struct order (0 `maxTradeUsdc` … 9 `maxDeadlineSeconds`).
    error BetaCeiling(uint8 field);
    /// @notice A policy field is outside its valid range: a bps field above 10,000 or a deadline outside 1–600 s.
    /// @param field Index of the field in `Policy` struct order (6 impact, 7 snipe, 9 deadline).
    error InvalidPolicy(uint8 field);
    /// @notice The token passed to `setTokenAllowed` is the zero address.
    error ZeroAddress();
    /// @notice Only the account's owner may call this.
    error NotOwner();
    /// @notice The agent is not active (never added, not yet activated, or revoked).
    error AgentNotActive();
    /// @notice The agent is already active; use `setAgent` to change its terms.
    error AgentAlreadyActive();
    /// @notice The address was revoked before and can never be an agent of this account again.
    error AgentRetired();
    /// @notice Eight agents are already active.
    error TooManyAgents();
    /// @notice No queued item has this id (never queued, executed or cancelled).
    /// @param id Queue id.
    error UnknownQueued(uint256 id);
    /// @notice The queued item's delay has not passed.
    /// @param eta Unix time (seconds) from which it may be executed.
    error TooEarly(uint40 eta);
    /// @notice The queued item expired 7 days after its ETA.
    error QueuedExpired();
    /// @notice The queued item no longer applies: its subject (the agent, the token's allowlist entry or the delay)
    ///         was written after it was queued, or, for an ownership acceptance, the epoch moved.
    error StaleQueued();
    /// @notice Ownership transfers complete only through `acceptOwnership` by the new owner.
    error AcceptRequired();
    /// @notice The caller is not the new owner of this queued ownership transfer, or the item is not one.
    error NotPendingOwner();
    /// @notice The proposed owner is zero, the account itself or the current owner.
    error InvalidOwner();
    /// @notice The caller is not an active agent of this account (the owner is never one).
    error NotAgent();
    /// @notice The agent's expiry has passed.
    error AgentExpired();
    /// @notice The agent lacks the permission bit this function needs.
    error MissingPermission();
    /// @notice Agents are paused, by the owner or by the factory's guardian.
    error Paused();
    /// @notice The deadline is in the past or more than `maxDeadlineSeconds` ahead.
    error DeadlineOutOfRange();
    /// @notice The period's `maxActionsPerPeriod` is used up.
    error ActionLimit();
    /// @notice The period's `launchesPerPeriod` is used up.
    error LaunchLimit();
    /// @notice The period's measured spend would exceed `periodSpendCap`.
    /// @param remaining Spend left this period before the trade, usdc6.
    error PeriodSpendExceeded(uint256 remaining);
    /// @notice The period's sells at cost-basis value would exceed `periodSellCap`.
    /// @param remaining Sell value left this period before the trade, usdc6.
    error PeriodSellExceeded(uint256 remaining);
    /// @notice The period's measured spend on this token would exceed `perTokenPeriodCap`.
    /// @param remaining Spend left on this token this period before the trade, usdc6.
    error TokenCapExceeded(uint256 remaining);

    // ------------------------------------------------------------------ factory and account calls

    /// @notice Registers a new account with its owner, policy, period, delay and optional first agent.
    /// @dev Factory only, once per account, inside `createAccount`. The policy and first agent take effect at once
    ///      but are checked against the factory's beta ceilings and the agent rules. `p.referrer` is not used here;
    ///      the account binds it.
    /// @param account The new clone.
    /// @param owner_ Its owner, the caller of `createAccount`.
    /// @param p Creation parameters (policy amounts usdc6, times in seconds).
    function register(address account, address owner_, InitParams calldata p) external;
    /// @notice Preamble of every agent function of the calling account (spec section 4.6, steps 2 to 7): owner
    ///         pause, factory pause, an active and unexpired agent holding `permission`, a deadline in
    ///         `[now, now + maxDeadlineSeconds]`, the period roll and the action count, which it increments.
    /// @dev Callable only by a registered account, for itself (`msg.sender`). The account runs its own lock first.
    ///      Every agent function counts one action here, including `claimFees` and `sweepToOwner`. For `P_LAUNCH` it
    ///      also reverts `LaunchLimit` when the period's launches are used up, after the action check and before the
    ///      account calls the LaunchFactory; `record` counts the launch.
    /// @param agent The agent key that called the account.
    /// @param permission The `P_*` bit the function needs.
    /// @param deadline The agent's deadline, Unix seconds.
    /// @return p The policy in force (amounts usdc6).
    /// @return periodId `block.timestamp / periodSeconds`.
    function authorize(address agent, uint16 permission, uint256 deadline)
        external
        returns (Policy memory p, uint64 periodId);
    /// @notice Charges an executed trade of the calling account to its period caps, after the trade, from measured
    ///         values. Reverts with the cap's typed error, so the whole trade reverts.
    /// @dev Callable only by a registered account, for itself. `spent6` counts toward `periodSpendCap` and the
    ///      per-token `perTokenPeriodCap` of `token`; `sellBasis6` toward `periodSellCap`; `isLaunch` toward
    ///      `launchesPerPeriod`. The account checks `maxTradeUsdc` itself.
    /// @param token The token the spend is keyed by.
    /// @param spent6 Measured USDC spent, usdc6.
    /// @param sellBasis6 Cost-basis value of a sell, usdc6.
    /// @param isLaunch True for a launch.
    function record(address token, uint256 spent6, uint256 sellBasis6, bool isLaunch) external;

    // ------------------------------------------------------------------ views

    /// @notice The factory that alone registers accounts here and whose pause and ceilings apply.
    /// @return The AgentAccountFactory address.
    function FACTORY() external view returns (address);
    /// @notice The account's owner, who manages it here and alone receives its withdrawals.
    /// @param account The agent account.
    /// @return The owner; zero for an address that is not a registered account.
    function owner(address account) external view returns (address);
    /// @notice The policy in force.
    /// @param account The agent account.
    /// @return The policy (amounts usdc6).
    function policy(address account) external view returns (Policy memory);
    /// @notice Length of the account's usage period, fixed at creation.
    /// @param account The agent account.
    /// @return Seconds.
    function periodSeconds(address account) external view returns (uint32);
    /// @notice Delay before a widening change takes effect.
    /// @param account The agent account.
    /// @return Seconds.
    function increaseDelay(address account) external view returns (uint32);
    /// @notice An agent key's standing in an account.
    /// @param account The agent account.
    /// @param a The agent key.
    /// @return The agent record; all zero if never added.
    function agent(address account, address a) external view returns (Agent memory);
    /// @notice Number of active agents, expired ones included until revoked.
    /// @param account The agent account.
    /// @return The count, at most 8.
    function activeAgentCount(address account) external view returns (uint8);
    /// @notice Whether an address was revoked as an agent of the account; it can never be one again.
    /// @param account The agent account.
    /// @param a The address.
    /// @return True when retired.
    function retired(address account, address a) external view returns (bool);
    /// @notice Whether a token is on the account's buy allowlist, used when `allowlistOnly` is set.
    /// @param account The agent account.
    /// @param token The token.
    /// @return True when allowed.
    function tokenAllowed(address account, address token) external view returns (bool);
    /// @notice Whether the owner has paused the account's agents.
    /// @param account The agent account.
    /// @return True when paused.
    function ownerPaused(address account) external view returns (bool);
    /// @notice Write sequence number: incremented by every applied change to the account's policy, an agent, a
    ///         token's allowlist entry or the delay. Queued items record it, and an item's subject written after
    ///         that number is not overwritten by it.
    /// @param account The agent account.
    /// @return The current number.
    function writeSeq(address account) external view returns (uint64);
    /// @notice Current queue epoch of the account. Items queued in an older epoch are void; pausing agents and
    ///         accepting ownership move it.
    /// @param account The agent account.
    /// @return The epoch.
    function epoch(address account) external view returns (uint64);
    /// @notice Write sequence number of a policy field's last change.
    /// @param account The agent account.
    /// @param field Field index in `Policy` struct order (0–10).
    /// @return The `writeSeq` value of that write; zero if never written (a field left at zero at creation).
    function policyWrite(address account, uint256 field) external view returns (uint64);
    /// @notice Write sequence number of an agent address's last activation, term change or retirement.
    /// @param account The agent account.
    /// @param a The address.
    /// @return The `writeSeq` value of that write; zero if never written.
    function agentWrite(address account, address a) external view returns (uint64);
    /// @notice Write sequence number of a token's last allowlist addition or removal.
    /// @param account The agent account.
    /// @param token The token.
    /// @return The `writeSeq` value of that write; zero if never written.
    function tokenWrite(address account, address token) external view returns (uint64);
    /// @notice Write sequence number of the widening delay's last change.
    /// @param account The agent account.
    /// @return The `writeSeq` value of that write; zero if never changed after creation.
    function delayWrite(address account) external view returns (uint64);
    /// @notice A queued item of the account. An item is executable when it exists, its epoch equals
    ///         `epoch(account)` and `eta <= now <= eta + 7 days`. Expired and older-epoch items stay in storage until
    ///         executed (which deletes an older-epoch item) or cancelled.
    /// @param account The agent account.
    /// @param id Queue id (ids start at 1 per account).
    /// @return kind `Q_*` kind; zero when no item has this id.
    /// @return eta Effective ETA, Unix seconds: queue time plus the larger of the delay at queue time and the
    ///         current delay, so raising the delay also delays items already queued. Expiry is `eta + 7 days`.
    /// @return itemEpoch Epoch at queue time.
    /// @return seq `writeSeq` at queue time: a subject whose last write (`policyWrite`, `agentWrite`, `tokenWrite`,
    ///         `delayWrite`) is above it keeps its value (policy field) or makes the item revert `StaleQueued`.
    /// @return payload ABI-encoded arguments: `(address agent, uint40 expiresAt, uint16 permissions)` for an agent
    ///         addition or widening; `(Policy target)` for a policy; `(address token)`; `(uint32 delay)`;
    ///         `(address newOwner)`.
    function queued(address account, uint256 id)
        external
        view
        returns (uint8 kind, uint40 eta, uint64 itemEpoch, uint64 seq, bytes memory payload);
    /// @notice Usage of the account's current period; all zero (with the current id) once a new period has begun.
    /// @param account The agent account.
    /// @return periodId `block.timestamp / periodSeconds`.
    /// @return spent USDC spent, usdc6.
    /// @return sold Sells at cost-basis value, usdc6.
    /// @return actions Agent actions.
    /// @return launches Launches.
    function usage(address account)
        external
        view
        returns (uint64 periodId, uint64 spent, uint64 sold, uint32 actions, uint16 launches);
    /// @notice USDC the account spent on `token` in the current period.
    /// @param account The agent account.
    /// @param token The token.
    /// @return usdc6.
    function tokenSpent(address account, address token) external view returns (uint64);
    /// @notice What is left of each period limit of the account right now (zero when a cap was lowered below its
    ///         usage).
    /// @param account The agent account.
    /// @return spend `periodSpendCap` left, usdc6.
    /// @return sell `periodSellCap` left, usdc6.
    /// @return actions Actions left.
    /// @return launches Launches left.
    function headroom(address account)
        external
        view
        returns (uint64 spend, uint64 sell, uint32 actions, uint16 launches);

    // ------------------------------------------------------------------ owner functions

    /// @notice Queues a new agent key; it becomes active once the item executes.
    /// @dev Account owner only. Reverts for a retired or active key, the owner, the account, zero, an expiry outside
    ///      `(now, now + 180 days]` or bad permissions; the terms and the 8-agent limit are checked again on execution.
    /// @param account The agent account.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask, non-zero and within `P_ALL`.
    /// @return id Queue id.
    function addAgent(address account, address a, uint40 expiresAt, uint16 permissions) external returns (uint256 id);
    /// @notice Replaces an active agent's terms: immediately when the expiry is not later and no permission is added,
    ///         otherwise queued as a full replacement that executes only if the agent was not written since.
    /// @dev Account owner only. Reverts `AgentNotActive` for an inactive key.
    /// @param account The agent account.
    /// @param a The agent key.
    /// @param expiresAt New expiry, Unix seconds, in `(now, now + 180 days]`.
    /// @param permissions New `P_*` bitmask, non-zero and within `P_ALL`.
    /// @return id Queue id, or zero when applied immediately.
    function setAgent(address account, address a, uint40 expiresAt, uint16 permissions) external returns (uint256 id);
    /// @notice Retires an address forever, revoking it now if it is an active agent. Queued items for it can no
    ///         longer execute (an addition fails `AgentRetired`, a widening `StaleQueued`).
    /// @dev Account owner only. Reverts `InvalidAgent` for zero, the owner or the account, and `AgentRetired` if
    ///      already retired.
    /// @param account The agent account.
    /// @param a The address.
    function revokeAgent(address account, address a) external;
    /// @notice Retires `oldA` now (revoking it if active) and queues `newA` with the given terms.
    /// @dev Account owner only. Same checks as `revokeAgent` and `addAgent`.
    /// @param account The agent account.
    /// @param oldA The agent key to retire.
    /// @param newA The replacement key.
    /// @param expiresAt Expiry of `newA`, Unix seconds.
    /// @param permissions `P_*` bitmask of `newA`.
    /// @return id Queue id of the addition.
    function rotateAgent(address account, address oldA, address newA, uint40 expiresAt, uint16 permissions)
        external
        returns (uint256 id);
    /// @notice Sets the policy: every field that is not looser takes effect now; if any field is looser, the full
    ///         target is queued after the immediate part. On execution, fields written after queueing keep their
    ///         current value.
    /// @dev Account owner only. Both the immediate result and the target are checked against the beta ceilings and
    ///      policy bounds; on execution the merged result is checked again.
    /// @param account The agent account.
    /// @param p Target policy (amounts usdc6).
    /// @return id Queue id, or zero when nothing was queued.
    function setPolicy(address account, Policy calldata p) external returns (uint256 id);
    /// @notice Removes a token from the buy allowlist now, or queues adding it.
    /// @dev Account owner only. Adding a token already allowed returns zero without queueing. A removal makes every
    ///      pending addition of the token stale.
    /// @param account The agent account.
    /// @param token The token; not zero.
    /// @param allowed True to add, false to remove.
    /// @return id Queue id, or zero when applied immediately.
    function setTokenAllowed(address account, address token, bool allowed) external returns (uint256 id);
    /// @notice Raises (or keeps) the widening delay now, or queues lowering it behind the current delay.
    /// @dev Account owner only. A queued lowering executes only if the delay was not written since.
    /// @param account The agent account.
    /// @param d New delay, seconds, at most 7 days.
    /// @return id Queue id, or zero when applied immediately.
    function setIncreaseDelay(address account, uint32 d) external returns (uint256 id);
    /// @notice Queues handing ownership to `newOwner`, who completes it with `acceptOwnership` after the delay.
    /// @dev Account owner only.
    /// @param account The agent account.
    /// @param newOwner The proposed owner: not zero, the account or the current owner.
    /// @return id Queue id.
    function transferOwnership(address account, address newOwner) external returns (uint256 id);
    /// @notice Completes a queued ownership transfer. Moves the epoch, which voids every other queued item, and
    ///         revokes the new owner as an agent if it is one, so the owner never has a trade path.
    /// @dev Callable only by the queued new owner, from the ETA to 7 days after it, in the item's epoch.
    /// @param account The agent account.
    /// @param id Queue id of the transfer.
    function acceptOwnership(address account, uint256 id) external;
    /// @notice Executes a queued item. Anyone may call it.
    /// @dev From the effective ETA to 7 days after it; an expired item reverts `QueuedExpired` and stays in storage
    ///      until cancelled. An item from an older epoch is deleted with `QueuedCancelled` instead, without
    ///      reverting. Ownership items revert `AcceptRequired`. A policy item whose every field was written after
    ///      queueing applies nothing and emits only `QueuedExecuted` (no `PolicyApplied`).
    /// @param account The agent account.
    /// @param id Queue id.
    function executeQueued(address account, uint256 id) external;
    /// @notice Deletes a queued item.
    /// @dev Account owner only.
    /// @param account The agent account.
    /// @param id Queue id.
    function cancelQueued(address account, uint256 id) external;
    /// @notice Pauses or unpauses the account's agents, immediately. Pausing voids every queued item.
    /// @dev Account owner only.
    /// @param account The agent account.
    /// @param paused True to pause.
    function pauseAgents(address account, bool paused) external;
}
