// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Policy, InitParams} from "../AgentTypes.sol";

/// @notice Creates Mercurifi agent accounts, records which addresses are genuine accounts, holds the beta policy
///         ceilings and the guardian pause of agent functions. Immutable; holds no funds.
interface IAgentAccountFactory {
    /// @notice An account was created and initialised.
    /// @param owner The account's owner, the caller of `createAccount`.
    /// @param account The new account.
    /// @param referrer The referrer bound for the account, or zero.
    /// @param salt The caller's salt, before it is mixed with the owner.
    event AccountCreated(address indexed owner, address indexed account, address indexed referrer, bytes32 salt);
    /// @notice Agent functions of every account are paused until `until`.
    /// @param until Unix time (seconds) the pause ends; zero or a past time means not paused.
    /// @param by The guardian or admin that set it.
    event AgentsPausedUntil(uint40 until, address by);
    /// @notice The guardian changed.
    /// @param guardian The new guardian.
    event GuardianSet(address guardian);

    /// @notice The implementation, the admin or a new guardian is the zero address.
    error ZeroAddress();
    /// @notice The implementation is bound to another factory or another registry.
    error ImplementationMismatch();
    /// @notice A beta ceiling is outside its valid range: a bps field above 10,000 or a deadline outside 1–600 s.
    /// @param field Index of the field in `Policy` struct order (6 impact, 7 snipe, 9 deadline).
    error InvalidCeiling(uint8 field);
    /// @notice The admin tried to extend a pause while none is active; the admin cannot start a pause.
    error NoActivePause();
    /// @notice The admin tried to extend a pause beyond 30 days from now.
    /// @param maxUntil Latest end the admin may set now, Unix seconds.
    error PauseTooLong(uint40 maxUntil);
    /// @notice The caller already created an account with this salt.
    /// @param account The existing account.
    error AccountExists(address account);
    /// @notice The caller is not the admin.
    error NotAdmin();
    /// @notice The caller is not the guardian.
    error NotGuardian();
    /// @notice The factory was deployed without a guardian, so no pause can ever be set.
    error GuardianDisabled();
    /// @notice The guardian's previous pause ended less than 72 hours ago, or is still running.
    /// @param readyAt Unix time (seconds) from which the guardian may pause again.
    error PauseCooldown(uint40 readyAt);

    /// @notice Creates the caller's account at a deterministic address, registers it in the registry (owner, policy,
    ///         period, delay, first agent) and initialises it (referrer binding).
    /// @dev The CREATE2 salt is `keccak256(abi.encode(msg.sender, salt))`, so nobody can take another owner's
    ///      address. Reverts `AccountExists` if that address is already used.
    /// @param salt Caller-chosen salt.
    /// @param p Creation parameters (policy amounts usdc6, times in seconds).
    /// @return account The new account.
    function createAccount(bytes32 salt, InitParams calldata p) external returns (address account);
    /// @notice Address `createAccount(salt, …)` called by `owner` deploys to.
    /// @param owner The future owner.
    /// @param salt The salt the owner will pass.
    /// @return The predicted account address.
    function predictAccount(address owner, bytes32 salt) external view returns (address);
    /// @notice Whether an address is an account created by this factory.
    /// @param account Address to check.
    /// @return True for accounts created here.
    function isAccount(address account) external view returns (bool);
    /// @notice The account implementation every clone delegates to.
    /// @return The implementation address.
    function implementation() external view returns (address);
    /// @notice The registry of every account's owner, policy, agents, queue and usage, deployed by this factory.
    /// @return The AgentPolicyRegistry address.
    function registry() external view returns (address);
    /// @notice The beta ceilings every stored policy must stay within.
    /// @dev Same shape as `Policy` (amounts usdc6). `allowlistOnly` is ignored; `minTokenAgeBlocks` is a floor.
    /// @return The ceilings.
    function ceilings() external view returns (Policy memory);
    /// @notice Whether agent functions of every account are paused.
    /// @return True while `block.timestamp < pausedUntil`.
    function isPaused() external view returns (bool);
    /// @notice End of the current pause.
    /// @return Unix time (seconds); zero or a past time means not paused.
    function pausedUntil() external view returns (uint40);
    /// @notice Address that may pause agent functions for 72 hours.
    /// @return The guardian, or zero if none.
    function guardian() external view returns (address);
    /// @notice Address that may replace the guardian and extend or lift a pause: the network's Launch timelock.
    /// @return The admin.
    function admin() external view returns (address);
    /// @notice The factory's version.
    /// @return The version string.
    function VERSION() external view returns (string memory);
    /// @notice Pauses agent functions of every account for at least 72 hours.
    /// @dev Guardian only. Sets `pausedUntil` to `max(pausedUntil, now + 72 hours)`, so it never shortens a pause the
    ///      admin extended. Allowed on the first call, and afterwards once 72 hours have passed since the
    ///      `pausedUntil` the guardian's previous call stored; admin changes to `pausedUntil` do not move that time.
    function guardianPause() external;
    /// @notice Shortens, lifts or extends the current pause.
    /// @dev Admin only. Any `until <= pausedUntil` is allowed at any time (zero lifts). A later `until` is allowed
    ///      only while a pause is active (`NoActivePause` otherwise, so the admin cannot start a pause) and only up to
    ///      `now + 30 days` (`PauseTooLong`). Does not change the guardian's cooldown.
    /// @param until Unix time (seconds) the pause ends.
    function adminSetPausedUntil(uint40 until) external;
    /// @notice Replaces the guardian.
    /// @dev Admin only. Reverts `ZeroAddress` for zero, and `GuardianDisabled` forever on a factory deployed without
    ///      a guardian.
    /// @param g The new guardian.
    function setGuardian(address g) external;
}
