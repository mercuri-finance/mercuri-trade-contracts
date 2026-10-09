// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgentPolicyRegistry} from "./interfaces/IAgentPolicyRegistry.sol";
import {IAgentAccountFactory} from "./interfaces/IAgentAccountFactory.sol";
import {AgentPolicyLib} from "./AgentPolicyLib.sol";
import {
    Policy,
    Agent,
    Usage,
    InitParams,
    P_ALL,
    MAX_AGENTS,
    MAX_AGENT_TTL,
    QUEUE_TTL,
    MAX_DELAY,
    MIN_PERIOD,
    MAX_PERIOD,
    Q_ADD_AGENT,
    Q_POLICY,
    Q_ALLOW_TOKEN,
    Q_DELAY,
    Q_OWNER,
    Q_SET_AGENT
} from "./AgentTypes.sol";

/// @notice Configuration and usage of every Mercurifi agent account of one factory. Owners manage their account
///         here; accounts ask it to authorise each agent call and to charge each trade to the period caps.
/// @dev Deployed by its factory, in the factory's constructor; immutable, with no admin and no owner of its own, and
///      it holds no funds. Every owner function takes the account as its first parameter and requires the caller to
///      be that account's owner. `authorize` and `record` act only on `msg.sender`'s own state and only for a
///      registered account, so one account can never touch another's usage. An address is registered exactly when
///      its owner is non-zero; owners can never become zero.
contract AgentPolicyRegistry is IAgentPolicyRegistry {
    using AgentPolicyLib for Policy;

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

    /// @dev One account's configuration and usage.
    struct Config {
        address owner;
        uint32 periodSeconds;
        uint32 increaseDelay;
        uint8 activeAgentCount;
        bool ownerPaused;
        uint64 epoch;
        uint64 writeSeq;
        uint64 delayWrite;
        Usage usage;
        Policy policy;
        uint64[11] policyWrite;
        uint256 lastQueueId;
    }

    /// @inheritdoc IAgentPolicyRegistry
    address public immutable FACTORY;

    /// @dev Configuration by account.
    mapping(address account => Config) private _c;
    /// @dev Agent records by account and key.
    mapping(address account => mapping(address => Agent)) private _agents;
    /// @inheritdoc IAgentPolicyRegistry
    mapping(address account => mapping(address => bool)) public retired;
    /// @inheritdoc IAgentPolicyRegistry
    mapping(address account => mapping(address => bool)) public tokenAllowed;
    /// @inheritdoc IAgentPolicyRegistry
    mapping(address account => mapping(address => uint64)) public agentWrite;
    /// @inheritdoc IAgentPolicyRegistry
    mapping(address account => mapping(address => uint64)) public tokenWrite;
    /// @dev Queued items by account and id; deleted on execution or cancellation.
    mapping(address account => mapping(uint256 => QueuedItem)) private _queue;
    /// @dev USDC spent by account, period id and token, usdc6.
    mapping(address account => mapping(uint64 => mapping(address => uint64))) private _tokenSpent;

    /// @dev Reverts `NotOwner` unless the caller is the owner of `account`.
    modifier onlyOwner(address account) {
        _checkOwner(account);
        _;
    }

    /// @notice Binds the registry to its factory, the deployer.
    constructor() {
        FACTORY = msg.sender;
    }

    // ------------------------------------------------------------------ factory and account calls

    /// @inheritdoc IAgentPolicyRegistry
    function register(address account, address owner_, InitParams calldata p) external {
        if (msg.sender != FACTORY) revert NotFactory();
        Config storage c = _c[account];
        if (c.owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert InvalidOwner();
        if (p.periodSeconds < MIN_PERIOD || p.periodSeconds > MAX_PERIOD) revert PeriodOutOfRange();
        if (p.increaseDelay > MAX_DELAY) revert DelayOutOfRange();
        c.owner = owner_;
        c.periodSeconds = p.periodSeconds;
        c.increaseDelay = p.increaseDelay;
        _applyPolicy(account, p.policy);
        if (p.firstAgent != address(0)) {
            _checkAgentTerms(account, p.firstAgent, p.firstAgentExpiresAt, p.firstAgentPermissions);
            c.activeAgentCount = 1;
            _setAgentTerms(account, p.firstAgent, p.firstAgentExpiresAt, p.firstAgentPermissions);
        }
    }

    /// @notice Preamble of every agent function of the calling account (spec section 4.6, steps 2 to 7): owner
    ///         pause, factory pause, an active and unexpired agent holding `permission`, a deadline in
    ///         `[now, now + maxDeadlineSeconds]`, the period roll and the action count, which it increments.
    /// @dev Callable only by a registered account, for itself (`msg.sender`). The account runs its own lock first.
    /// @param agent_ The agent key that called the account.
    /// @param permission The `P_*` bit the function needs.
    /// @param deadline The agent's deadline, Unix seconds.
    /// @return p The policy in force (amounts usdc6).
    /// @return periodId `block.timestamp / periodSeconds`.
    function authorize(address agent_, uint16 permission, uint256 deadline)
        external
        returns (Policy memory p, uint64 periodId)
    {
        Config storage c = _account();
        if (c.ownerPaused || IAgentAccountFactory(FACTORY).isPaused()) revert Paused();
        Agent memory a = _agents[msg.sender][agent_];
        if (!a.active) revert NotAgent();
        if (block.timestamp >= a.expiresAt) revert AgentExpired();
        if (a.permissions & permission == 0) revert MissingPermission();
        p = c.policy;
        if (deadline < block.timestamp || deadline > block.timestamp + p.maxDeadlineSeconds) {
            revert DeadlineOutOfRange();
        }
        Usage memory u = _currentUsage(c);
        if (u.actions >= p.maxActionsPerPeriod) revert ActionLimit();
        ++u.actions;
        c.usage = u;
        return (p, u.periodId);
    }

    /// @inheritdoc IAgentPolicyRegistry
    function record(address token, uint256 spent6, uint256 sellBasis6, bool isLaunch) external {
        Config storage c = _account();
        Usage memory u = _currentUsage(c);
        Policy memory p = c.policy;
        if (spent6 != 0) {
            // Compared as "at most what is left", so no input can overflow.
            uint256 left = _left(p.periodSpendCap, u.spent);
            if (spent6 > left) revert PeriodSpendExceeded(left);
            uint64 tokenUsed = _tokenSpent[msg.sender][u.periodId][token];
            left = _left(p.perTokenPeriodCap, tokenUsed);
            if (spent6 > left) revert TokenCapExceeded(left);
            // Both sums are now at most their caps, which are uint64.
            // forge-lint: disable-next-line(unsafe-typecast)
            u.spent += uint64(spent6);
            // forge-lint: disable-next-line(unsafe-typecast)
            _tokenSpent[msg.sender][u.periodId][token] = tokenUsed + uint64(spent6);
        }
        if (sellBasis6 != 0) {
            uint256 left = _left(p.periodSellCap, u.sold);
            if (sellBasis6 > left) revert PeriodSellExceeded(left);
            // forge-lint: disable-next-line(unsafe-typecast)
            u.sold += uint64(sellBasis6);
        }
        if (isLaunch) {
            if (u.launches >= p.launchesPerPeriod) revert LaunchLimit();
            ++u.launches;
        }
        c.usage = u;
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IAgentPolicyRegistry
    function owner(address account) external view returns (address) {
        return _c[account].owner;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function policy(address account) external view returns (Policy memory) {
        return _c[account].policy;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function periodSeconds(address account) external view returns (uint32) {
        return _c[account].periodSeconds;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function increaseDelay(address account) external view returns (uint32) {
        return _c[account].increaseDelay;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function agent(address account, address a) external view returns (Agent memory) {
        return _agents[account][a];
    }

    /// @inheritdoc IAgentPolicyRegistry
    function activeAgentCount(address account) external view returns (uint8) {
        return _c[account].activeAgentCount;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function ownerPaused(address account) external view returns (bool) {
        return _c[account].ownerPaused;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function writeSeq(address account) external view returns (uint64) {
        return _c[account].writeSeq;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function epoch(address account) external view returns (uint64) {
        return _c[account].epoch;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function policyWrite(address account, uint256 field) external view returns (uint64) {
        return _c[account].policyWrite[field];
    }

    /// @inheritdoc IAgentPolicyRegistry
    function delayWrite(address account) external view returns (uint64) {
        return _c[account].delayWrite;
    }

    /// @inheritdoc IAgentPolicyRegistry
    function queued(address account, uint256 id)
        external
        view
        returns (uint8 kind, uint40 eta, uint64 itemEpoch, uint64 seq, bytes memory payload)
    {
        QueuedItem storage q = _queue[account][id];
        if (q.kind == 0) return (0, 0, 0, 0, "");
        return (q.kind, _eta(_c[account], q.queuedAt, q.delayAtQueue), q.epoch, q.seq, q.payload);
    }

    /// @inheritdoc IAgentPolicyRegistry
    function usage(address account)
        external
        view
        returns (uint64 periodId, uint64 spent, uint64 sold, uint32 actions, uint16 launches)
    {
        Usage memory u = _currentUsage(_c[account]);
        return (u.periodId, u.spent, u.sold, u.actions, u.launches);
    }

    /// @inheritdoc IAgentPolicyRegistry
    function tokenSpent(address account, address token) external view returns (uint64) {
        return _tokenSpent[account][_currentUsage(_c[account]).periodId][token];
    }

    /// @inheritdoc IAgentPolicyRegistry
    function headroom(address account) external view returns (uint64, uint64, uint32, uint16) {
        Config storage c = _c[account];
        Usage memory u = _currentUsage(c);
        Policy memory p = c.policy;
        // Each value is at most its cap, which has the same width.
        return (
            uint64(_left(p.periodSpendCap, u.spent)),
            uint64(_left(p.periodSellCap, u.sold)),
            uint32(_left(p.maxActionsPerPeriod, u.actions)),
            uint16(_left(p.launchesPerPeriod, u.launches))
        );
    }

    // ------------------------------------------------------------------ agents

    /// @inheritdoc IAgentPolicyRegistry
    function addAgent(address account, address a, uint40 expiresAt, uint16 permissions)
        public
        onlyOwner(account)
        returns (uint256 id)
    {
        _checkAddable(account, a, expiresAt, permissions);
        id = _queueItem(account, Q_ADD_AGENT, abi.encode(a, expiresAt, permissions));
        emit AgentQueued(account, id, a, expiresAt, permissions, _queueEta(account));
    }

    /// @inheritdoc IAgentPolicyRegistry
    function setAgent(address account, address a, uint40 expiresAt, uint16 permissions)
        external
        onlyOwner(account)
        returns (uint256 id)
    {
        Agent memory cur = _agents[account][a];
        if (!cur.active) revert AgentNotActive();
        _checkAgentTerms(account, a, expiresAt, permissions);
        if (expiresAt <= cur.expiresAt && permissions & ~cur.permissions == 0) {
            _setAgentTerms(account, a, expiresAt, permissions);
            return 0;
        }
        id = _queueItem(account, Q_SET_AGENT, abi.encode(a, expiresAt, permissions));
        emit AgentQueued(account, id, a, expiresAt, permissions, _queueEta(account));
    }

    /// @inheritdoc IAgentPolicyRegistry
    function revokeAgent(address account, address a) external onlyOwner(account) {
        _revoke(account, a);
    }

    /// @inheritdoc IAgentPolicyRegistry
    function rotateAgent(address account, address oldA, address newA, uint40 expiresAt, uint16 permissions)
        external
        onlyOwner(account)
        returns (uint256 id)
    {
        _revoke(account, oldA);
        return addAgent(account, newA, expiresAt, permissions);
    }

    // ------------------------------------------------------------------ policy, allowlist and delay

    /// @inheritdoc IAgentPolicyRegistry
    function setPolicy(address account, Policy calldata p) external onlyOwner(account) returns (uint256 id) {
        Policy memory target = p;
        Policy memory cur = _c[account].policy;
        Policy memory now_ = cur.tighten(target);
        if (keccak256(abi.encode(now_)) != keccak256(abi.encode(cur))) _applyPolicy(account, now_);
        if (!now_.isNarrowing(target)) {
            target.checkCeilings(IAgentAccountFactory(FACTORY).ceilings());
            target.validate();
            id = _queueItem(account, Q_POLICY, abi.encode(target));
            emit PolicyQueued(account, id, _queueEta(account), target);
        }
    }

    /// @inheritdoc IAgentPolicyRegistry
    function setTokenAllowed(address account, address token, bool allowed)
        external
        onlyOwner(account)
        returns (uint256 id)
    {
        if (token == address(0)) revert ZeroAddress();
        if (!allowed) {
            tokenAllowed[account][token] = false;
            tokenWrite[account][token] = ++_c[account].writeSeq;
            emit TokenAllowed(account, token, false);
            return 0;
        }
        if (tokenAllowed[account][token]) return 0;
        id = _queueItem(account, Q_ALLOW_TOKEN, abi.encode(token));
        emit TokenAllowQueued(account, id, token, _queueEta(account));
    }

    /// @inheritdoc IAgentPolicyRegistry
    function setIncreaseDelay(address account, uint32 d) external onlyOwner(account) returns (uint256 id) {
        if (d > MAX_DELAY) revert DelayOutOfRange();
        if (d >= _c[account].increaseDelay) {
            _setDelay(account, d);
            return 0;
        }
        id = _queueItem(account, Q_DELAY, abi.encode(d));
        emit IncreaseDelayQueued(account, id, d, _queueEta(account));
    }

    // ------------------------------------------------------------------ ownership

    /// @inheritdoc IAgentPolicyRegistry
    function transferOwnership(address account, address newOwner) external onlyOwner(account) returns (uint256 id) {
        if (newOwner == address(0) || newOwner == account || newOwner == msg.sender) revert InvalidOwner();
        id = _queueItem(account, Q_OWNER, abi.encode(newOwner));
        emit OwnershipQueued(account, id, newOwner, _queueEta(account));
    }

    /// @inheritdoc IAgentPolicyRegistry
    function acceptOwnership(address account, uint256 id) external {
        Config storage c = _c[account];
        QueuedItem storage q = _queue[account][id];
        if (q.kind == 0) revert UnknownQueued(id);
        if (q.kind != Q_OWNER || abi.decode(q.payload, (address)) != msg.sender) revert NotPendingOwner();
        if (q.epoch != c.epoch) revert StaleQueued();
        _checkWindow(_eta(c, q.queuedAt, q.delayAtQueue));
        delete _queue[account][id];
        if (_agents[account][msg.sender].active) _revoke(account, msg.sender);
        address previous = c.owner;
        c.owner = msg.sender;
        ++c.epoch;
        emit QueuedExecuted(account, id);
        emit AccountOwnerChanged(account, previous, msg.sender);
    }

    // ------------------------------------------------------------------ queue

    /// @inheritdoc IAgentPolicyRegistry
    function executeQueued(address account, uint256 id) external {
        Config storage c = _c[account];
        QueuedItem memory q = _queue[account][id];
        if (q.kind == 0) revert UnknownQueued(id);
        if (q.kind == Q_OWNER) revert AcceptRequired();
        delete _queue[account][id];
        if (q.epoch != c.epoch) {
            emit QueuedCancelled(account, id);
            return;
        }
        _checkWindow(_eta(c, q.queuedAt, q.delayAtQueue));
        if (q.kind == Q_POLICY) {
            // Skip the write when every field was written since queueing: the item has nothing left to apply.
            uint64[11] memory lastWrite = c.policyWrite;
            for (uint256 i; i < 11; ++i) {
                if (lastWrite[i] <= q.seq) {
                    _applyPolicy(account, c.policy.merge(abi.decode(q.payload, (Policy)), lastWrite, q.seq));
                    break;
                }
            }
        } else if (q.kind == Q_ALLOW_TOKEN) {
            address token = abi.decode(q.payload, (address));
            _checkFresh(tokenWrite[account][token], q.seq);
            tokenAllowed[account][token] = true;
            tokenWrite[account][token] = ++c.writeSeq;
            emit TokenAllowed(account, token, true);
        } else if (q.kind == Q_DELAY) {
            _checkFresh(c.delayWrite, q.seq);
            _setDelay(account, abi.decode(q.payload, (uint32)));
        } else {
            (address a, uint40 expiresAt, uint16 permissions) = abi.decode(q.payload, (address, uint40, uint16));
            if (q.kind == Q_ADD_AGENT) {
                _checkAddable(account, a, expiresAt, permissions);
                _checkFresh(agentWrite[account][a], q.seq);
                if (c.activeAgentCount >= MAX_AGENTS) revert TooManyAgents();
                ++c.activeAgentCount;
            } else {
                _checkFresh(agentWrite[account][a], q.seq);
                if (!_agents[account][a].active) revert AgentNotActive();
                _checkAgentTerms(account, a, expiresAt, permissions);
            }
            _setAgentTerms(account, a, expiresAt, permissions);
        }
        emit QueuedExecuted(account, id);
    }

    /// @inheritdoc IAgentPolicyRegistry
    function cancelQueued(address account, uint256 id) external onlyOwner(account) {
        if (_queue[account][id].kind == 0) revert UnknownQueued(id);
        delete _queue[account][id];
        emit QueuedCancelled(account, id);
    }

    /// @inheritdoc IAgentPolicyRegistry
    function pauseAgents(address account, bool paused) external onlyOwner(account) {
        Config storage c = _c[account];
        c.ownerPaused = paused;
        if (paused) ++c.epoch;
        emit AgentsPaused(account, paused);
    }

    // ------------------------------------------------------------------ internals

    /// @dev The caller's configuration; reverts `NotAccount` unless the caller is a registered account.
    /// @return c The caller's configuration.
    function _account() private view returns (Config storage c) {
        c = _c[msg.sender];
        if (c.owner == address(0)) revert NotAccount();
    }

    /// @dev Stored usage, or a zero usage of the current period once the period has changed.
    /// @param c The account's configuration.
    /// @return u Usage of the current period (amounts usdc6).
    function _currentUsage(Config storage c) private view returns (Usage memory u) {
        u = c.usage;
        uint32 len = c.periodSeconds;
        uint64 periodId = len == 0 ? 0 : uint64(block.timestamp / len);
        if (u.periodId != periodId) u = Usage({periodId: periodId, spent: 0, sold: 0, actions: 0, launches: 0});
    }

    /// @dev `cap - used`, or zero when the cap was lowered below the usage.
    /// @param cap The limit.
    /// @param used The usage.
    /// @return What is left.
    function _left(uint256 cap, uint256 used) private pure returns (uint256) {
        return cap > used ? cap - used : 0;
    }

    /// @dev Checks `next` against `validate` and the factory's beta ceilings, stores it, records each changed field's
    ///      write and emits `PolicyApplied`. Every policy write goes through here.
    /// @param account The agent account.
    /// @param next Policy to apply (amounts usdc6).
    function _applyPolicy(address account, Policy memory next) private {
        next.checkCeilings(IAgentAccountFactory(FACTORY).ceilings());
        next.validate();
        Config storage c = _c[account];
        uint256[11] memory o = AgentPolicyLib.words(c.policy);
        uint256[11] memory n = AgentPolicyLib.words(next);
        uint64 seq = ++c.writeSeq;
        for (uint256 i; i < 11; ++i) {
            if (o[i] != n[i]) c.policyWrite[i] = seq;
        }
        c.policy = next;
        emit PolicyApplied(account, next);
    }

    /// @dev Reverts `NotOwner` unless the caller is the owner of `account` (never true for an unregistered one).
    /// @param account The agent account.
    function _checkOwner(address account) private view {
        if (msg.sender != _c[account].owner) revert NotOwner();
    }

    /// @dev Stores a new queued item with the current time, delay, epoch and write sequence number.
    /// @param account The agent account.
    /// @param kind `Q_*` kind.
    /// @param payload ABI-encoded arguments.
    /// @return id The new queue id, per account.
    function _queueItem(address account, uint8 kind, bytes memory payload) private returns (uint256 id) {
        Config storage c = _c[account];
        id = ++c.lastQueueId;
        _queue[account][id] = QueuedItem({
            kind: kind,
            queuedAt: uint40(block.timestamp),
            delayAtQueue: c.increaseDelay,
            epoch: c.epoch,
            seq: c.writeSeq,
            payload: payload
        });
    }

    /// @dev ETA of an item queued now: `now + increaseDelay`.
    /// @param account The agent account.
    /// @return Unix seconds.
    function _queueEta(address account) private view returns (uint40) {
        return uint40(block.timestamp + _c[account].increaseDelay);
    }

    /// @dev Effective ETA: `queuedAt + max(delayAtQueue, increaseDelay)`, so raising the delay also delays items
    ///      already queued.
    /// @param c The account's configuration.
    /// @param queuedAt The item's queue time, Unix seconds.
    /// @param delayAtQueue The delay when it was queued, seconds.
    /// @return Unix seconds.
    function _eta(Config storage c, uint40 queuedAt, uint32 delayAtQueue) private view returns (uint40) {
        uint32 d = c.increaseDelay;
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
    /// @param account The agent account.
    /// @param d Delay, seconds.
    function _setDelay(address account, uint32 d) private {
        Config storage c = _c[account];
        c.increaseDelay = d;
        c.delayWrite = ++c.writeSeq;
        emit IncreaseDelaySet(account, d);
    }

    /// @dev Reverts unless `a` can be added now: not retired, not active, and acceptable terms.
    /// @param account The agent account.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask.
    function _checkAddable(address account, address a, uint40 expiresAt, uint16 permissions) private view {
        if (retired[account][a]) revert AgentRetired();
        if (_agents[account][a].active) revert AgentAlreadyActive();
        _checkAgentTerms(account, a, expiresAt, permissions);
    }

    /// @dev Marks `a` active with these terms and emits `AgentActivated`. Callers check the terms.
    /// @param account The agent account.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask.
    function _setAgentTerms(address account, address a, uint40 expiresAt, uint16 permissions) private {
        _agents[account][a] = Agent({active: true, expiresAt: expiresAt, permissions: permissions});
        agentWrite[account][a] = ++_c[account].writeSeq;
        emit AgentActivated(account, a, expiresAt, permissions);
    }

    /// @dev Retires `a` forever, revoking it if active, and records the write. Reverts `InvalidAgent` for zero, the
    ///      owner or the account, which can never be agents.
    /// @param account The agent account.
    /// @param a The address.
    function _revoke(address account, address a) private {
        Config storage c = _c[account];
        if (a == address(0) || a == c.owner || a == account) revert InvalidAgent();
        if (retired[account][a]) revert AgentRetired();
        Agent memory cur = _agents[account][a];
        retired[account][a] = true;
        agentWrite[account][a] = ++c.writeSeq;
        if (cur.active) {
            _agents[account][a].active = false;
            --c.activeAgentCount;
        }
        emit AgentRevoked(account, a, cur.expiresAt, cur.permissions);
    }

    /// @dev Reverts unless `a` may become an agent of `account` with these terms: not zero, the owner or the
    ///      account; expiry in `(now, now + 180 days]`; permissions non-zero and within `P_ALL`. An owner-agent would
    ///      give the owner a trade path.
    /// @param account The agent account.
    /// @param a The agent key.
    /// @param expiresAt Expiry, Unix seconds.
    /// @param permissions `P_*` bitmask.
    function _checkAgentTerms(address account, address a, uint40 expiresAt, uint16 permissions) private view {
        if (a == address(0) || a == _c[account].owner || a == account) revert InvalidAgent();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_AGENT_TTL) {
            revert AgentExpiryOutOfRange();
        }
        if (permissions == 0 || permissions & ~P_ALL != 0) revert InvalidPermissions();
    }
}
