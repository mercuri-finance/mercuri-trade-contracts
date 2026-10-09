// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {IAgentAccountFactory} from "./interfaces/IAgentAccountFactory.sol";
import {AgentPolicyLib} from "./AgentPolicyLib.sol";
import {Policy, InitParams, GUARDIAN_PAUSE, GUARDIAN_COOLDOWN, MAX_ADMIN_PAUSE} from "./AgentTypes.sol";

/// @notice Creates Mercurifi agent accounts as EIP-1167 clones of one implementation, records them, holds the beta
///         policy ceilings and the guardian pause of agent functions.
/// @dev Immutable, holds no funds. The admin (the network's Launch timelock) can only replace the guardian, shorten or
///      lift a pause, and extend an active pause by at most 30 days from now; it cannot start a pause or touch
///      accounts, policies or funds. A factory deployed with guardian zero can never pause: `guardianPause`,
///      `setGuardian` and `adminSetPausedUntil` revert forever.
contract AgentAccountFactory is IAgentAccountFactory {
    /// @notice The factory's version.
    string public constant VERSION = "1.0.0-beta.1";

    /// @notice The account implementation every clone delegates to.
    address public immutable implementation;
    /// @notice Address that may replace the guardian and extend or lift a pause: the network's Launch timelock.
    address public immutable admin;
    /// @notice True when deployed without a guardian; then no pause can ever be set.
    bool public immutable guardianDisabled;

    uint64 private immutable C_MAX_TRADE_USDC;
    uint64 private immutable C_PERIOD_SPEND_CAP;
    uint64 private immutable C_PER_TOKEN_PERIOD_CAP;
    uint64 private immutable C_PERIOD_SELL_CAP;
    uint32 private immutable C_MAX_ACTIONS_PER_PERIOD;
    uint16 private immutable C_LAUNCHES_PER_PERIOD;
    uint16 private immutable C_MAX_PRICE_IMPACT_BPS;
    uint16 private immutable C_MAX_SNIPE_BPS;
    uint32 private immutable C_MIN_TOKEN_AGE_BLOCKS;
    uint32 private immutable C_MAX_DEADLINE_SECONDS;

    /// @notice Address that may pause agent functions for 72 hours.
    address public guardian;
    /// @notice End of the current pause, Unix seconds; zero or a past time means not paused.
    uint40 public pausedUntil;
    /// @dev `pausedUntil` as stored by the guardian's latest pause, Unix seconds; the guardian's cooldown runs from it.
    ///      Later admin changes to `pausedUntil` do not move it.
    uint40 private lastGuardianPauseEnd;

    /// @notice Whether an address is an account created by this factory.
    mapping(address account => bool) public isAccount;

    /// @notice Binds the factory to its implementation, admin, guardian and beta ceilings for life.
    /// @dev Reverts `ZeroAddress` for a zero implementation or admin, and `ImplementationMismatch` unless the
    ///      implementation was deployed for this factory's address, and `InvalidCeiling(field)` for a ceiling outside
    ///      the bounds every policy must meet (bps at most 10,000, deadline in `[1, 600]`). A zero guardian disables
    ///      the pause forever.
    /// @param implementation_ AgentAccount implementation whose `FACTORY` is this factory's address.
    /// @param admin_ The network's Launch timelock.
    /// @param guardian_ The Guardian Safe, or zero for no pause at all.
    /// @param ceilings_ Beta ceilings (amounts usdc6); `allowlistOnly` is ignored, `minTokenAgeBlocks` is a floor.
    constructor(address implementation_, address admin_, address guardian_, Policy memory ceilings_) {
        if (implementation_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (IAgentAccount(implementation_).FACTORY() != address(this)) revert ImplementationMismatch();
        (bool ok, uint8 field) = AgentPolicyLib.checkShape(ceilings_);
        if (!ok) revert InvalidCeiling(field);
        implementation = implementation_;
        admin = admin_;
        guardianDisabled = guardian_ == address(0);
        if (guardian_ != address(0)) {
            guardian = guardian_;
            emit GuardianSet(guardian_);
        }
        C_MAX_TRADE_USDC = ceilings_.maxTradeUsdc;
        C_PERIOD_SPEND_CAP = ceilings_.periodSpendCap;
        C_PER_TOKEN_PERIOD_CAP = ceilings_.perTokenPeriodCap;
        C_PERIOD_SELL_CAP = ceilings_.periodSellCap;
        C_MAX_ACTIONS_PER_PERIOD = ceilings_.maxActionsPerPeriod;
        C_LAUNCHES_PER_PERIOD = ceilings_.launchesPerPeriod;
        C_MAX_PRICE_IMPACT_BPS = ceilings_.maxPriceImpactBps;
        C_MAX_SNIPE_BPS = ceilings_.maxSnipeBps;
        C_MIN_TOKEN_AGE_BLOCKS = ceilings_.minTokenAgeBlocks;
        C_MAX_DEADLINE_SECONDS = ceilings_.maxDeadlineSeconds;
    }

    /// @inheritdoc IAgentAccountFactory
    function createAccount(bytes32 salt, InitParams calldata p) external returns (address account) {
        bytes32 salt_ = _salt(msg.sender, salt);
        // A CREATE2 collision would burn all forwarded gas; refuse a used address up front instead.
        account = Clones.predictDeterministicAddress(implementation, salt_);
        if (account.code.length != 0) revert AccountExists(account);
        Clones.cloneDeterministic(implementation, salt_);
        IAgentAccount(account).initialize(msg.sender, p);
        isAccount[account] = true;
        emit AccountCreated(msg.sender, account, p.referrer, salt);
    }

    /// @inheritdoc IAgentAccountFactory
    function predictAccount(address owner, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner, salt));
    }

    /// @inheritdoc IAgentAccountFactory
    function ceilings() external view returns (Policy memory) {
        return Policy({
            maxTradeUsdc: C_MAX_TRADE_USDC,
            periodSpendCap: C_PERIOD_SPEND_CAP,
            perTokenPeriodCap: C_PER_TOKEN_PERIOD_CAP,
            periodSellCap: C_PERIOD_SELL_CAP,
            maxActionsPerPeriod: C_MAX_ACTIONS_PER_PERIOD,
            launchesPerPeriod: C_LAUNCHES_PER_PERIOD,
            maxPriceImpactBps: C_MAX_PRICE_IMPACT_BPS,
            maxSnipeBps: C_MAX_SNIPE_BPS,
            minTokenAgeBlocks: C_MIN_TOKEN_AGE_BLOCKS,
            maxDeadlineSeconds: C_MAX_DEADLINE_SECONDS,
            allowlistOnly: false
        });
    }

    /// @inheritdoc IAgentAccountFactory
    function isPaused() external view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    /// @inheritdoc IAgentAccountFactory
    function guardianPause() external {
        if (guardianDisabled) revert GuardianDisabled();
        if (msg.sender != guardian) revert NotGuardian();
        uint256 last = lastGuardianPauseEnd;
        // The first pause is always allowed; afterwards the previous guardian pause must have ended 72 hours ago.
        if (last != 0 && block.timestamp < last + GUARDIAN_COOLDOWN) {
            revert PauseCooldown(uint40(last + GUARDIAN_COOLDOWN));
        }
        // Never shortens a longer pause the admin set.
        uint40 until = uint40(block.timestamp + GUARDIAN_PAUSE);
        uint40 current = pausedUntil;
        if (current > until) until = current;
        lastGuardianPauseEnd = until;
        pausedUntil = until;
        emit AgentsPausedUntil(until, msg.sender);
    }

    /// @inheritdoc IAgentAccountFactory
    function adminSetPausedUntil(uint40 until) external {
        if (msg.sender != admin) revert NotAdmin();
        if (guardianDisabled) revert GuardianDisabled();
        uint40 current = pausedUntil;
        if (until > current) {
            // Extending: only an active pause, and to at most 30 days from now.
            if (block.timestamp >= current) revert NoActivePause();
            uint256 maxUntil = block.timestamp + MAX_ADMIN_PAUSE;
            if (until > maxUntil) revert PauseTooLong(uint40(maxUntil));
        }
        pausedUntil = until;
        emit AgentsPausedUntil(until, msg.sender);
    }

    /// @inheritdoc IAgentAccountFactory
    function setGuardian(address g) external {
        if (msg.sender != admin) revert NotAdmin();
        if (guardianDisabled) revert GuardianDisabled();
        if (g == address(0)) revert ZeroAddress();
        guardian = g;
        emit GuardianSet(g);
    }

    /// @dev CREATE2 salt of `owner`'s account for `salt`.
    /// @param owner The account's owner.
    /// @param salt The owner's salt.
    /// @return The salt passed to CREATE2.
    function _salt(address owner, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }
}
