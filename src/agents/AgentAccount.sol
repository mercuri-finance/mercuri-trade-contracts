// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILaunchFactory} from "@mercuri/launch/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {IGraduationManager} from "@mercuri/launch/interfaces/IGraduationManager.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {IAgentAccountFactory} from "./interfaces/IAgentAccountFactory.sol";
import {AgentPolicyLib} from "./AgentPolicyLib.sol";
import {Policy, Agent, InitParams, P_ALL, MAX_AGENT_TTL, MAX_DELAY, MIN_PERIOD, MAX_PERIOD} from "./AgentTypes.sol";

/// @notice A Mercurifi agent account: a per-user vault whose agent keys trade Launch tokens within owner-set caps and
///         can never withdraw. Withdrawals go only to the owner, and the owner has no trade path.
/// @dev The implementation behind EIP-1167 clones made by `FACTORY`. Every dependency is an immutable of this
///      implementation, so clones read it from the implementation's code. No proxy upgrade, delegatecall, generic
///      execute or selfdestruct. The implementation itself is locked in its constructor and never holds an owner.
contract AgentAccount is IAgentAccount {
    using AgentPolicyLib for Policy;

    /// @inheritdoc IAgentAccount
    address public immutable FACTORY;
    /// @inheritdoc IAgentAccount
    ILaunchFactory public immutable LAUNCH_FACTORY;
    /// @inheritdoc IAgentAccount
    IFeeManager public immutable FEE_MANAGER;
    /// @inheritdoc IAgentAccount
    IGraduationManager public immutable GRADUATION_MANAGER;
    /// @inheritdoc IAgentAccount
    address public immutable LAUNCH_HOOK;
    /// @inheritdoc IAgentAccount
    IPoolManager public immutable POOL_MANAGER;
    /// @inheritdoc IAgentAccount
    address public immutable UNIVERSAL_ROUTER;
    /// @inheritdoc IAgentAccount
    address public immutable PERMIT2;
    /// @inheritdoc IAgentAccount
    address public immutable USDC;

    /// @inheritdoc IAgentAccount
    address public owner;
    /// @inheritdoc IAgentAccount
    uint32 public periodSeconds;
    /// @inheritdoc IAgentAccount
    uint32 public increaseDelay;
    /// @inheritdoc IAgentAccount
    uint8 public activeAgentCount;
    /// @dev Set once by `initialize`, and by the constructor on the implementation.
    bool private initialized;
    /// @inheritdoc IAgentAccount
    address public referrer;
    /// @dev The policy in force; read through `policy()`.
    Policy private _policy;
    /// @dev Agent records by key; read through `agent()`.
    mapping(address => Agent) private agents;

    /// @notice Deploys the implementation, bound to its factory and the network's Launch and Uniswap contracts.
    /// @dev Reverts `ZeroAddress` for any zero dependency. Locks itself: `initialize` on the implementation reverts.
    /// @param factory_ The AgentAccountFactory that will clone this implementation (predicted before deployment).
    /// @param launchFactory_ LaunchFactory proxy.
    /// @param feeManager_ FeeManager proxy.
    /// @param graduationManager_ GraduationManager proxy.
    /// @param launchHook_ LaunchHook.
    /// @param poolManager_ Uniswap v4 PoolManager.
    /// @param universalRouter_ Universal Router.
    /// @param permit2_ Permit2.
    /// @param usdc_ Arc's native USDC (6-decimal ERC-20 view).
    constructor(
        address factory_,
        address launchFactory_,
        address feeManager_,
        address graduationManager_,
        address launchHook_,
        address poolManager_,
        address universalRouter_,
        address permit2_,
        address usdc_
    ) {
        if (
            factory_ == address(0) || launchFactory_ == address(0) || feeManager_ == address(0)
                || graduationManager_ == address(0) || launchHook_ == address(0) || poolManager_ == address(0)
                || universalRouter_ == address(0) || permit2_ == address(0) || usdc_ == address(0)
        ) revert ZeroAddress();
        FACTORY = factory_;
        LAUNCH_FACTORY = ILaunchFactory(launchFactory_);
        FEE_MANAGER = IFeeManager(feeManager_);
        GRADUATION_MANAGER = IGraduationManager(graduationManager_);
        LAUNCH_HOOK = launchHook_;
        POOL_MANAGER = IPoolManager(poolManager_);
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
        USDC = usdc_;
        initialized = true;
    }

    /// @notice Accepts native USDC from anyone. No logic runs.
    receive() external payable {}

    /// @inheritdoc IAgentAccount
    function initialize(address owner_, InitParams calldata p) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        if (p.periodSeconds < MIN_PERIOD || p.periodSeconds > MAX_PERIOD) revert PeriodOutOfRange();
        if (p.increaseDelay > MAX_DELAY) revert DelayOutOfRange();
        owner = owner_;
        periodSeconds = p.periodSeconds;
        increaseDelay = p.increaseDelay;
        _applyPolicy(p.policy);
        if (p.referrer != address(0)) {
            if (p.referrer == address(this)) revert SelfReferrer();
            referrer = p.referrer;
            FEE_MANAGER.bindReferrer(p.referrer);
        }
        if (p.firstAgent != address(0)) {
            _checkAgentTerms(p.firstAgent, p.firstAgentExpiresAt, p.firstAgentPermissions);
            agents[p.firstAgent] = Agent(true, p.firstAgentExpiresAt, p.firstAgentPermissions);
            activeAgentCount = 1;
            emit AgentActivated(p.firstAgent, p.firstAgentExpiresAt, p.firstAgentPermissions);
        }
    }

    /// @inheritdoc IAgentAccount
    function policy() external view returns (Policy memory) {
        return _policy;
    }

    /// @inheritdoc IAgentAccount
    function agent(address a) external view returns (Agent memory) {
        return agents[a];
    }

    /// @notice Never accepts a signature: agent accounts sign nothing in this version.
    /// @dev Always `0xffffffff`. Arc's USDC accepts contract signatures in the `bytes` forms of `permit` and
    ///      `transferWithAuthorization`, so returning the magic value would open a withdrawal path.
    /// @param hash Ignored.
    /// @param signature Ignored.
    /// @return magicValue Always `0xffffffff`.
    function isValidSignature(bytes32 hash, bytes memory signature) external pure returns (bytes4 magicValue) {
        hash;
        signature;
        return 0xffffffff;
    }

    /// @dev Checks `p` against `validate` and the factory's beta ceilings, stores it and emits `PolicyApplied`. Every
    ///      policy write goes through here.
    /// @param next Policy to apply (amounts usdc6).
    function _applyPolicy(Policy memory next) private {
        next.checkCeilings(IAgentAccountFactory(FACTORY).ceilings());
        next.validate();
        _policy = next;
        emit PolicyApplied(next);
    }

    /// @dev Reverts unless `a` may become an agent with these terms: not zero, the owner or this account; expiry in
    ///      `(now, now + 180 days]`; permissions non-zero and within `P_ALL`. An owner-agent would give the owner a
    ///      trade path.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask.
    function _checkAgentTerms(address a, uint40 expiresAt, uint16 permissions) private view {
        if (a == address(0) || a == owner || a == address(this)) revert InvalidAgent();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_AGENT_TTL) {
            revert AgentExpiryOutOfRange();
        }
        if (permissions == 0 || permissions & ~P_ALL != 0) revert InvalidPermissions();
    }
}
