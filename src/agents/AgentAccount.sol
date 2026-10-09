// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILaunchFactory} from "@mercuri/launch/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {IGraduationManager} from "@mercuri/launch/interfaces/IGraduationManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {IAgentAccountFactory} from "./interfaces/IAgentAccountFactory.sol";
import {AgentPolicyLib} from "./AgentPolicyLib.sol";
import {
    Policy,
    Agent,
    InitParams,
    P_ALL,
    MAX_AGENTS,
    MAX_AGENT_TTL,
    QUEUE_TTL,
    MAX_DELAY,
    MIN_PERIOD,
    MAX_PERIOD,
    Q_ADD_AGENT,
    Q_SET_AGENT,
    Q_POLICY,
    Q_ALLOW_TOKEN,
    Q_DELAY,
    Q_OWNER
} from "./AgentTypes.sol";

/// @notice A Mercurifi agent account: a per-user vault whose agent keys trade Launch tokens within owner-set caps and
///         can never withdraw. Withdrawals go only to the owner, and the owner has no trade path.
/// @dev The implementation behind EIP-1167 clones made by `FACTORY`. Every dependency is an immutable of this
///      implementation, so clones read it from the implementation's code. No proxy upgrade, delegatecall, generic
///      execute or selfdestruct. The implementation itself is locked in its constructor and never holds an owner.
contract AgentAccount is IAgentAccount, ReentrancyGuardTransient {
    using AgentPolicyLib for Policy;
    using SafeERC20 for IERC20;

    /// @dev A queued owner change; see `queued` for the payload encodings. One slot plus the payload.
    struct QueuedItem {
        uint8 kind;
        /// @dev Unix seconds when queued.
        uint40 queuedAt;
        /// @dev `increaseDelay` when queued, seconds.
        uint32 delayAtQueue;
        /// @dev `epoch` when queued.
        uint64 epoch;
        /// @dev `writeSeq` when queued.
        uint64 seq;
        bytes payload;
    }

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
    /// @inheritdoc IAgentAccount
    mapping(address => bool) public retired;
    /// @inheritdoc IAgentAccount
    mapping(address => bool) public tokenAllowed;
    /// @inheritdoc IAgentAccount
    bool public ownerPaused;
    /// @inheritdoc IAgentAccount
    uint64 public epoch;
    /// @inheritdoc IAgentAccount
    uint64 public writeSeq;
    /// @dev Delay's last write sequence number.
    uint64 private delayWrite;
    /// @dev Each policy field's last write sequence number, in `Policy` struct order.
    uint64[11] private policyWrite;
    /// @dev Each agent address's last write sequence number (activation, term change or retirement).
    mapping(address => uint64) private agentWrite;
    /// @dev Each token's last allowlist write sequence number (addition or removal).
    mapping(address => uint64) private tokenWrite;
    /// @dev Last queue id handed out; ids start at 1.
    uint256 private lastQueueId;
    /// @dev Queued items by id; deleted on execution or cancellation.
    mapping(uint256 => QueuedItem) private queue;

    /// @dev Reverts `NotOwner` unless the caller is the owner.
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

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
            activeAgentCount = 1;
            _setAgentTerms(p.firstAgent, p.firstAgentExpiresAt, p.firstAgentPermissions);
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

    /// @inheritdoc IAgentAccount
    function queued(uint256 id) external view returns (uint8 kind, uint40 eta, uint64 itemEpoch, bytes memory payload) {
        QueuedItem storage q = queue[id];
        if (q.kind == 0) return (0, 0, 0, "");
        return (q.kind, _eta(q.queuedAt, q.delayAtQueue), q.epoch, q.payload);
    }

    // ------------------------------------------------------------------ agents

    /// @inheritdoc IAgentAccount
    function addAgent(address a, uint40 expiresAt, uint16 permissions) public onlyOwner returns (uint256 id) {
        _checkAddable(a, expiresAt, permissions);
        id = _queue(Q_ADD_AGENT, abi.encode(a, expiresAt, permissions));
        emit AgentQueued(id, a, expiresAt, permissions, uint40(block.timestamp + increaseDelay));
    }

    /// @inheritdoc IAgentAccount
    function setAgent(address a, uint40 expiresAt, uint16 permissions) external onlyOwner returns (uint256 id) {
        Agent memory cur = agents[a];
        if (!cur.active) revert AgentNotActive();
        _checkAgentTerms(a, expiresAt, permissions);
        if (expiresAt <= cur.expiresAt && permissions & ~cur.permissions == 0) {
            _setAgentTerms(a, expiresAt, permissions);
            return 0;
        }
        id = _queue(Q_SET_AGENT, abi.encode(a, expiresAt, permissions));
        emit AgentQueued(id, a, expiresAt, permissions, uint40(block.timestamp + increaseDelay));
    }

    /// @inheritdoc IAgentAccount
    function revokeAgent(address a) external onlyOwner {
        _revoke(a);
    }

    /// @inheritdoc IAgentAccount
    function rotateAgent(address oldA, address newA, uint40 expiresAt, uint16 permissions)
        external
        onlyOwner
        returns (uint256 id)
    {
        _revoke(oldA);
        return addAgent(newA, expiresAt, permissions);
    }

    // ------------------------------------------------------------------ policy, allowlist and delay

    /// @inheritdoc IAgentAccount
    function setPolicy(Policy calldata p) external onlyOwner returns (uint256 id) {
        Policy memory target = p;
        Policy memory cur = _policy;
        Policy memory now_ = cur.tighten(target);
        if (keccak256(abi.encode(now_)) != keccak256(abi.encode(cur))) _applyPolicy(now_);
        if (!now_.isNarrowing(target)) {
            target.checkCeilings(IAgentAccountFactory(FACTORY).ceilings());
            target.validate();
            id = _queue(Q_POLICY, abi.encode(target, now_));
            emit PolicyQueued(id, uint40(block.timestamp + increaseDelay), target);
        }
    }

    /// @inheritdoc IAgentAccount
    function setTokenAllowed(address token, bool allowed) external onlyOwner returns (uint256 id) {
        if (token == address(0)) revert ZeroAddress();
        if (!allowed) {
            tokenAllowed[token] = false;
            tokenWrite[token] = ++writeSeq;
            emit TokenAllowed(token, false);
            return 0;
        }
        if (tokenAllowed[token]) return 0;
        id = _queue(Q_ALLOW_TOKEN, abi.encode(token));
        emit TokenAllowQueued(id, token, uint40(block.timestamp + increaseDelay));
    }

    /// @inheritdoc IAgentAccount
    function setIncreaseDelay(uint32 d) external onlyOwner returns (uint256 id) {
        if (d > MAX_DELAY) revert DelayOutOfRange();
        uint32 cur = increaseDelay;
        if (d >= cur) {
            _setDelay(d);
            return 0;
        }
        id = _queue(Q_DELAY, abi.encode(d));
        emit IncreaseDelayQueued(id, d, uint40(block.timestamp + increaseDelay));
    }

    // ------------------------------------------------------------------ ownership

    /// @inheritdoc IAgentAccount
    function transferOwnership(address newOwner) external onlyOwner returns (uint256 id) {
        if (newOwner == address(0) || newOwner == address(this) || newOwner == owner) revert InvalidOwner();
        id = _queue(Q_OWNER, abi.encode(newOwner));
        emit OwnershipQueued(id, newOwner, uint40(block.timestamp + increaseDelay));
    }

    /// @inheritdoc IAgentAccount
    function acceptOwnership(uint256 id) external {
        QueuedItem storage q = queue[id];
        if (q.kind == 0) revert UnknownQueued(id);
        if (q.kind != Q_OWNER || abi.decode(q.payload, (address)) != msg.sender) revert NotPendingOwner();
        if (q.epoch != epoch) revert StaleQueued();
        _checkWindow(_eta(q.queuedAt, q.delayAtQueue));
        delete queue[id];
        if (agents[msg.sender].active) _revoke(msg.sender);
        address previous = owner;
        owner = msg.sender;
        ++epoch;
        emit QueuedExecuted(id);
        emit OwnershipTransferred(previous, msg.sender);
    }

    // ------------------------------------------------------------------ queue

    /// @inheritdoc IAgentAccount
    function executeQueued(uint256 id) external {
        QueuedItem memory q = queue[id];
        if (q.kind == 0) revert UnknownQueued(id);
        if (q.kind == Q_OWNER) revert AcceptRequired();
        delete queue[id];
        if (q.epoch != epoch) {
            emit QueuedCancelled(id);
            return;
        }
        _checkWindow(_eta(q.queuedAt, q.delayAtQueue));
        if (q.kind == Q_POLICY) {
            _applyPolicy(_policy.merge(abi.decode(q.payload, (Policy)), policyWrite, q.seq));
        } else if (q.kind == Q_ALLOW_TOKEN) {
            address token = abi.decode(q.payload, (address));
            _checkFresh(tokenWrite[token], q.seq);
            tokenAllowed[token] = true;
            tokenWrite[token] = ++writeSeq;
            emit TokenAllowed(token, true);
        } else if (q.kind == Q_DELAY) {
            _checkFresh(delayWrite, q.seq);
            _setDelay(abi.decode(q.payload, (uint32)));
        } else {
            (address a, uint40 expiresAt, uint16 permissions) = abi.decode(q.payload, (address, uint40, uint16));
            if (q.kind == Q_ADD_AGENT) {
                _checkAddable(a, expiresAt, permissions);
                _checkFresh(agentWrite[a], q.seq);
                if (activeAgentCount >= MAX_AGENTS) revert TooManyAgents();
                ++activeAgentCount;
            } else {
                _checkFresh(agentWrite[a], q.seq);
                if (!agents[a].active) revert AgentNotActive();
                _checkAgentTerms(a, expiresAt, permissions);
            }
            _setAgentTerms(a, expiresAt, permissions);
        }
        emit QueuedExecuted(id);
    }

    /// @inheritdoc IAgentAccount
    function cancelQueued(uint256 id) external onlyOwner {
        if (queue[id].kind == 0) revert UnknownQueued(id);
        delete queue[id];
        emit QueuedCancelled(id);
    }

    /// @inheritdoc IAgentAccount
    function pauseAgents(bool paused) external onlyOwner {
        ownerPaused = paused;
        if (paused) ++epoch;
        emit AgentsPaused(paused);
    }

    // ------------------------------------------------------------------ withdrawals

    /// @inheritdoc IAgentAccount
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        _send(token, amount);
    }

    /// @inheritdoc IAgentAccount
    function withdrawMany(address[] calldata tokens) external onlyOwner nonReentrant {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
            if (amount != 0) _send(token, amount);
        }
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
        uint256[11] memory o = AgentPolicyLib.words(_policy);
        uint256[11] memory n = AgentPolicyLib.words(next);
        uint64 seq = ++writeSeq;
        for (uint256 i; i < 11; ++i) {
            if (o[i] != n[i]) policyWrite[i] = seq;
        }
        _policy = next;
        emit PolicyApplied(next);
    }

    /// @dev Reverts `NotOwner` unless the caller is the owner.
    function _checkOwner() private view {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @dev Stores a new queued item with the current time, delay, epoch and write sequence number.
    /// @param kind `Q_*` kind.
    /// @param payload ABI-encoded arguments.
    /// @return id The new queue id.
    function _queue(uint8 kind, bytes memory payload) private returns (uint256 id) {
        id = ++lastQueueId;
        queue[id] = QueuedItem({
            kind: kind,
            queuedAt: uint40(block.timestamp),
            delayAtQueue: increaseDelay,
            epoch: epoch,
            seq: writeSeq,
            payload: payload
        });
    }

    /// @dev Effective ETA: `queuedAt + max(delayAtQueue, increaseDelay)`, so raising the delay also delays items
    ///      already queued.
    /// @param queuedAt The item's queue time, Unix seconds.
    /// @param delayAtQueue The delay when it was queued, seconds.
    /// @return Unix seconds.
    function _eta(uint40 queuedAt, uint32 delayAtQueue) private view returns (uint40) {
        uint32 d = increaseDelay;
        return queuedAt + (delayAtQueue > d ? delayAtQueue : d);
    }

    /// @dev Reverts `TooEarly` before `eta` and `QueuedExpired` after `eta + QUEUE_TTL`.
    /// @param eta The item's effective ETA, Unix seconds.
    function _checkWindow(uint40 eta) private view {
        if (block.timestamp < eta) revert TooEarly(eta);
        if (block.timestamp > eta + QUEUE_TTL) revert QueuedExpired();
    }

    /// @dev Reverts `StaleQueued` when the item's subject was written after the item was queued.
    /// @param lastWrite The subject's last write sequence number.
    /// @param seq The item's `writeSeq` at queue time.
    function _checkFresh(uint64 lastWrite, uint64 seq) private pure {
        if (lastWrite > seq) revert StaleQueued();
    }

    /// @dev Stores the widening delay, records the write and emits `IncreaseDelaySet`.
    /// @param d Delay, seconds.
    function _setDelay(uint32 d) private {
        increaseDelay = d;
        delayWrite = ++writeSeq;
        emit IncreaseDelaySet(d);
    }

    /// @dev Reverts unless `a` can be added now: not retired, not active, and acceptable terms.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask.
    function _checkAddable(address a, uint40 expiresAt, uint16 permissions) private view {
        if (retired[a]) revert AgentRetired();
        if (agents[a].active) revert AgentAlreadyActive();
        _checkAgentTerms(a, expiresAt, permissions);
    }

    /// @dev Marks `a` active with these terms and emits `AgentActivated`. Callers check the terms.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask.
    function _setAgentTerms(address a, uint40 expiresAt, uint16 permissions) private {
        agents[a] = Agent({active: true, expiresAt: expiresAt, permissions: permissions});
        agentWrite[a] = ++writeSeq;
        emit AgentActivated(a, expiresAt, permissions);
    }

    /// @dev Retires `a` forever, revoking it if active, and records the write.
    /// @param a The address.
    function _revoke(address a) private {
        if (retired[a]) revert AgentRetired();
        Agent memory cur = agents[a];
        retired[a] = true;
        agentWrite[a] = ++writeSeq;
        if (cur.active) {
            agents[a].active = false;
            --activeAgentCount;
        }
        emit AgentRevoked(a, cur.expiresAt, cur.permissions);
    }

    /// @dev Sends `amount` of `token` (zero: native wei) to the owner and emits `Withdrawn`.
    /// @param token The token, or zero for native USDC.
    /// @param amount Native wei (18 decimals) for zero, else the token's own units.
    function _send(address token, uint256 amount) private {
        address to = owner;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, amount);
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
