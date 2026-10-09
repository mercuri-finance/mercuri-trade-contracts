// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILaunchFactory} from "@mercuri/launch/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {IGraduationManager} from "@mercuri/launch/interfaces/IGraduationManager.sol";
import {Policy, Agent, InitParams} from "../AgentTypes.sol";

/// @notice A Mercurifi agent account: a per-user vault whose agent keys trade Launch tokens within owner-set caps and
///         can never withdraw. Each account is an EIP-1167 clone of one immutable implementation.
interface IAgentAccount is IERC1271 {
    /// @notice A policy took effect, at creation or later.
    /// @param policy The full policy now in force (amounts usdc6).
    event PolicyApplied(Policy policy);
    /// @notice An agent key became able to act, or an active agent's terms changed (narrowed now or widened from the
    ///         queue). The event always carries the terms now in force.
    /// @param agent The agent key.
    /// @param expiresAt Unix time (seconds) from which the agent can no longer act.
    /// @param permissions Bitmask of `P_*` permissions.
    event AgentActivated(address indexed agent, uint40 expiresAt, uint16 permissions);
    /// @notice An agent addition or widening was queued.
    /// @param id Queue id.
    /// @param agent The agent key.
    /// @param expiresAt Requested expiry, Unix seconds.
    /// @param permissions Requested `P_*` bitmask.
    /// @param eta Unix time (seconds) from which anyone may execute the item; it expires 7 days later.
    event AgentQueued(uint256 indexed id, address indexed agent, uint40 expiresAt, uint16 permissions, uint40 eta);
    /// @notice An agent was revoked and retired forever.
    /// @param agent The agent key.
    /// @param expiresAt Expiry it had, Unix seconds.
    /// @param permissions `P_*` bitmask it had.
    event AgentRevoked(address indexed agent, uint40 expiresAt, uint16 permissions);
    /// @notice A policy widening was queued.
    /// @param id Queue id.
    /// @param eta Unix time (seconds) from which anyone may execute the item; it expires 7 days later.
    /// @param policy The full target policy (amounts usdc6); fields tightened before execution keep their value.
    event PolicyQueued(uint256 indexed id, uint40 eta, Policy policy);
    /// @notice A queued item was cancelled by the owner, or found void on an execution attempt after the account's
    ///         epoch moved (agents paused or ownership transferred).
    /// @param id Queue id.
    event QueuedCancelled(uint256 indexed id);
    /// @notice A queued item was executed.
    /// @param id Queue id.
    event QueuedExecuted(uint256 indexed id);
    /// @notice A token was added to or removed from the buy allowlist.
    /// @param token The token.
    /// @param allowed Whether buys of it pass when `allowlistOnly` is set.
    event TokenAllowed(address indexed token, bool allowed);
    /// @notice Adding a token to the buy allowlist was queued.
    /// @param id Queue id.
    /// @param token The token.
    /// @param eta Unix time (seconds) from which anyone may execute the item; it expires 7 days later.
    event TokenAllowQueued(uint256 indexed id, address indexed token, uint40 eta);
    /// @notice The owner paused or unpaused this account's agents. Pausing voids every queued item.
    /// @param paused True when paused.
    event AgentsPaused(bool paused);
    /// @notice The widening delay changed.
    /// @param delay New delay, seconds.
    event IncreaseDelaySet(uint32 delay);
    /// @notice Lowering the widening delay was queued.
    /// @param id Queue id.
    /// @param delay Requested delay, seconds.
    /// @param eta Unix time (seconds) from which anyone may execute the item; it expires 7 days later.
    event IncreaseDelayQueued(uint256 indexed id, uint32 delay, uint40 eta);
    /// @notice An ownership transfer was queued; only `newOwner` can complete it, through `acceptOwnership`.
    /// @param id Queue id.
    /// @param newOwner The proposed owner.
    /// @param eta Unix time (seconds) from which `newOwner` may accept; it expires 7 days later.
    event OwnershipQueued(uint256 indexed id, address indexed newOwner, uint40 eta);
    /// @notice Ownership moved. Every item queued before it is void.
    /// @param previousOwner The former owner.
    /// @param newOwner The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Assets left the account to the owner.
    /// @param token The token, or zero for native USDC.
    /// @param amount Amount sent: native wei (18 decimals) for zero, else the token's own units.
    event Withdrawn(address indexed token, uint256 amount);

    /// @notice A constructor dependency, or the token passed to `setTokenAllowed`, is the zero address.
    error ZeroAddress();
    /// @notice Only the factory may initialise an account.
    error NotFactory();
    /// @notice The account, or the implementation itself, is already initialised.
    error AlreadyInitialized();
    /// @notice The period length is outside one hour to seven days.
    error PeriodOutOfRange();
    /// @notice The widening delay is above seven days (at creation or in `setIncreaseDelay`).
    error DelayOutOfRange();
    /// @notice The referrer is the account itself, which the FeeManager would refuse.
    error SelfReferrer();
    /// @notice The agent key is zero, the owner or the account itself.
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
    /// @notice Only the owner may call this.
    error NotOwner();
    /// @notice The agent is not active (never added, not yet activated, or revoked).
    error AgentNotActive();
    /// @notice The agent is already active; use `setAgent` to change its terms.
    error AgentAlreadyActive();
    /// @notice The address was revoked before and can never be an agent again.
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
    /// @notice The queued item no longer applies: the state it was queued against changed (agent terms or delay
    ///         changed, or the epoch moved before an ownership acceptance).
    error StaleQueued();
    /// @notice Ownership transfers complete only through `acceptOwnership` by the new owner.
    error AcceptRequired();
    /// @notice The caller is not the new owner of this queued ownership transfer, or the item is not one.
    error NotPendingOwner();
    /// @notice The proposed owner is zero, the account itself or the current owner.
    error InvalidOwner();
    /// @notice Sending native USDC to the owner failed.
    error NativeTransferFailed();

    /// @notice Sets the owner, referrer, policy, period, delay and optional first agent of a fresh clone.
    /// @dev Callable only by `FACTORY`, once, inside `createAccount`. Binds a non-zero referrer in the FeeManager.
    /// @param owner_ The account's owner, the creator of the account.
    /// @param p Creation parameters (policy amounts usdc6, times in seconds).
    function initialize(address owner_, InitParams calldata p) external;

    /// @notice Factory that alone may initialise accounts of this implementation.
    /// @return The AgentAccountFactory address.
    function FACTORY() external view returns (address);
    /// @notice Launch factory whose `curveOf` registry decides which curves are genuine.
    /// @return The LaunchFactory proxy.
    function LAUNCH_FACTORY() external view returns (ILaunchFactory);
    /// @notice Launch FeeManager that holds the referrer binding and the account's creator fees.
    /// @return The FeeManager proxy.
    function FEE_MANAGER() external view returns (IFeeManager);
    /// @notice Launch GraduationManager that names each graduated token's pool.
    /// @return The GraduationManager proxy.
    function GRADUATION_MANAGER() external view returns (IGraduationManager);
    /// @notice The only hook a pool swap may go through.
    /// @return The LaunchHook address.
    function LAUNCH_HOOK() external view returns (address);
    /// @notice Uniswap v4 PoolManager of graduated pools.
    /// @return The PoolManager address.
    function POOL_MANAGER() external view returns (IPoolManager);
    /// @notice Universal Router used for pool swaps.
    /// @return The router address.
    function UNIVERSAL_ROUTER() external view returns (address);
    /// @notice Permit2 used to approve the router for one swap at a time.
    /// @return The Permit2 address.
    function PERMIT2() external view returns (address);
    /// @notice Arc's native USDC, whose ERC-20 view has 6 decimals.
    /// @return The USDC address.
    function USDC() external view returns (address);

    /// @notice The account's owner, who manages agents and policy and alone receives withdrawals.
    /// @return The owner address; zero on the implementation.
    function owner() external view returns (address);
    /// @notice The referrer bound in the FeeManager at creation, fixed for life.
    /// @return The referrer, or zero for none.
    function referrer() external view returns (address);
    /// @notice The policy in force.
    /// @return The policy (amounts usdc6).
    function policy() external view returns (Policy memory);
    /// @notice Length of a usage period, fixed at creation.
    /// @return Seconds.
    function periodSeconds() external view returns (uint32);
    /// @notice Delay before a widening change takes effect.
    /// @return Seconds.
    function increaseDelay() external view returns (uint32);
    /// @notice An agent key's standing.
    /// @param a The agent key.
    /// @return The agent record; all zero if never added.
    function agent(address a) external view returns (Agent memory);
    /// @notice Number of active agents, expired ones included until revoked.
    /// @return The count, at most 8.
    function activeAgentCount() external view returns (uint8);
    /// @notice Whether an address was revoked as an agent; retired addresses can never be agents again.
    /// @param a The address.
    /// @return True when retired.
    function retired(address a) external view returns (bool);
    /// @notice Whether a token is on the buy allowlist used when `allowlistOnly` is set.
    /// @param token The token.
    /// @return True when allowed.
    function tokenAllowed(address token) external view returns (bool);
    /// @notice Whether the owner has paused this account's agents.
    /// @return True when paused.
    function ownerPaused() external view returns (bool);
    /// @notice Current queue epoch. Items queued in an older epoch are void; pausing agents and accepting ownership
    ///         move it.
    /// @return The epoch.
    function epoch() external view returns (uint64);
    /// @notice A queued item. An item is executable when it exists, its epoch equals `epoch()` and
    ///         `eta <= now <= eta + 7 days`.
    /// @param id Queue id (ids start at 1).
    /// @return kind `Q_*` kind; zero when no item has this id.
    /// @return eta Unix time (seconds) from which it may be executed.
    /// @return itemEpoch Epoch at queue time.
    /// @return payload ABI-encoded arguments: `(address, uint40, uint16)` for an addition; `(address, uint40, uint16,
    ///         Agent snapshot)` for an agent widening; `(Policy target, Policy snapshot)` for a policy; `(address)` for
    ///         a token; `(uint32 delay, uint32 snapshot)` for the delay; `(address)` for an owner.
    function queued(uint256 id) external view returns (uint8 kind, uint40 eta, uint64 itemEpoch, bytes memory payload);

    /// @notice Queues a new agent key; it becomes active once the item executes.
    /// @dev Owner only. Reverts for a retired or active key, the owner, the account, zero, an expiry outside
    ///      `(now, now + 180 days]` or bad permissions; the terms and the 8-agent limit are checked again on execution.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask, non-zero and within `P_ALL`.
    /// @return id Queue id.
    function addAgent(address a, uint40 expiresAt, uint16 permissions) external returns (uint256 id);
    /// @notice Replaces an active agent's terms: immediately when the expiry is not later and no permission is added,
    ///         otherwise queued as a full replacement that executes only if the agent is unchanged by then.
    /// @dev Owner only. Reverts `AgentNotActive` for an inactive key.
    /// @param a The agent key.
    /// @param expiresAt New expiry, Unix seconds, in `(now, now + 180 days]`.
    /// @param permissions New `P_*` bitmask, non-zero and within `P_ALL`.
    /// @return id Queue id, or zero when applied immediately.
    function setAgent(address a, uint40 expiresAt, uint16 permissions) external returns (uint256 id);
    /// @notice Revokes an active agent now and retires its address forever. Queued items for it can no longer
    ///         execute.
    /// @dev Owner only.
    /// @param a The agent key.
    function revokeAgent(address a) external;
    /// @notice Revokes `oldA` now and queues `newA` with the given terms.
    /// @dev Owner only. Same checks as `revokeAgent` and `addAgent`.
    /// @param oldA The agent key to retire.
    /// @param newA The replacement key.
    /// @param expiresAt Expiry of `newA`, Unix seconds.
    /// @param permissions `P_*` bitmask of `newA`.
    /// @return id Queue id of the addition.
    function rotateAgent(address oldA, address newA, uint40 expiresAt, uint16 permissions) external returns (uint256 id);
    /// @notice Sets the policy: every field that is not looser takes effect now; if any field is looser, the full
    ///         target is queued with a snapshot of the policy after the immediate part.
    /// @dev Owner only. Both the immediate result and the target are checked against the beta ceilings and policy
    ///      bounds; on execution the merged result is checked again.
    /// @param p Target policy (amounts usdc6).
    /// @return id Queue id, or zero when nothing was queued.
    function setPolicy(Policy calldata p) external returns (uint256 id);
    /// @notice Removes a token from the buy allowlist now, or queues adding it.
    /// @dev Owner only. Adding a token already allowed returns zero without queueing.
    /// @param token The token; not zero.
    /// @param allowed True to add, false to remove.
    /// @return id Queue id, or zero when applied immediately.
    function setTokenAllowed(address token, bool allowed) external returns (uint256 id);
    /// @notice Raises (or keeps) the widening delay now, or queues lowering it behind the current delay.
    /// @dev Owner only. A queued lowering executes only if the delay is unchanged by then.
    /// @param d New delay, seconds, at most 7 days.
    /// @return id Queue id, or zero when applied immediately.
    function setIncreaseDelay(uint32 d) external returns (uint256 id);
    /// @notice Queues handing ownership to `newOwner`, who completes it with `acceptOwnership` after the delay.
    /// @dev Owner only.
    /// @param newOwner The proposed owner: not zero, the account or the current owner.
    /// @return id Queue id.
    function transferOwnership(address newOwner) external returns (uint256 id);
    /// @notice Completes a queued ownership transfer. Moves the epoch, which voids every other queued item, and
    ///         revokes the new owner as an agent if it is one, so the owner never has a trade path.
    /// @dev Callable only by the queued new owner, from the ETA to 7 days after it, in the item's epoch.
    /// @param id Queue id of the transfer.
    function acceptOwnership(uint256 id) external;
    /// @notice Executes a queued item. Anyone may call it.
    /// @dev From the ETA to 7 days after it. An item from an older epoch is deleted with `QueuedCancelled` instead,
    ///      without reverting. Ownership items revert `AcceptRequired`.
    /// @param id Queue id.
    function executeQueued(uint256 id) external;
    /// @notice Deletes a queued item.
    /// @dev Owner only.
    /// @param id Queue id.
    function cancelQueued(uint256 id) external;
    /// @notice Pauses or unpauses this account's agents, immediately. Pausing voids every queued item.
    /// @dev Owner only.
    /// @param paused True to pause.
    function pauseAgents(bool paused) external;
    /// @notice Sends `amount` of a token, or native USDC, to the owner.
    /// @dev Owner only; works while agents are paused, by the owner or the factory.
    /// @param token The token, or zero for native USDC.
    /// @param amount Native wei (18 decimals) for zero, else the token's own units.
    function withdraw(address token, uint256 amount) external;
    /// @notice Sends the full balance of each listed token, or of native USDC for zero, to the owner.
    /// @dev Owner only. Zero balances are skipped, so repeats are harmless.
    /// @param tokens Tokens to empty; zero means native USDC.
    function withdrawMany(address[] calldata tokens) external;
}
