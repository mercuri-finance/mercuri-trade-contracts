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
    /// @notice An agent key became able to act.
    /// @param agent The agent key.
    /// @param expiresAt Unix time (seconds) from which the agent can no longer act.
    /// @param permissions Bitmask of `P_*` permissions.
    event AgentActivated(address indexed agent, uint40 expiresAt, uint16 permissions);

    /// @notice A constructor dependency is the zero address.
    error ZeroAddress();
    /// @notice Only the factory may initialise an account.
    error NotFactory();
    /// @notice The account, or the implementation itself, is already initialised.
    error AlreadyInitialized();
    /// @notice The period length is outside one hour to seven days.
    error PeriodOutOfRange();
    /// @notice The widening delay is above seven days.
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
}
