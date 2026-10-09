// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentPolicyLib} from "../../src/agents/AgentPolicyLib.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/agents/interfaces/IAgentPolicyRegistry.sol";
import {
    Policy,
    Agent,
    InitParams,
    LaunchRequest,
    P_ALL,
    P_BUY,
    P_SELL,
    P_POOL_SWAP,
    P_LAUNCH,
    P_CLAIM,
    P_SWEEP_TO_OWNER,
    QUEUE_TTL
} from "../../src/agents/AgentTypes.sol";

/// @dev The only fuzz target: every call is one `step` of the suite, which holds the fixture and the cheatcodes.
contract AgentInvariantHandler {
    AgentInvariantsTest internal immutable suite;

    constructor(AgentInvariantsTest suite_) {
        suite = suite_;
    }

    function step(uint256 seed) external {
        suite.step(seed);
    }
}

/// @dev Task 6: invariants of spec section 5 over two accounts, several agents each, curve tokens (alice's and the
///      agents' own launches), graduated pools in both orderings, and every owner action. Each step performs one
///      action chosen by the seed; odd steps first cover any action kind not yet performed in the run, so every kind
///      is reached in every run. Positive actions are sized to succeed (bounded amounts, warps past snipe windows and
///      period ends, re-quotes) and are called directly, so any unexpected revert fails the run (`fail_on_revert`).
///      Negative actions (strangers, owners on the trade path, revoked, expired and paused agents, early executions,
///      cross-account keys, over-cap trades) run under `vm.expectRevert` and are counted separately.
///
///      Every agent call is wrapped: across it, (1) the native USDC and token balances summed over the accounts,
///      their owners and the Launch/Uniswap contracts are conserved, (2) no other address (agents, strangers, the
///      router, Permit2, ...) gains or loses anything, (3) the other account's whole registry and account state is
///      unchanged, (4) the measured spend and the independently computed sell value equal what the registry
///      charged, and every cap held at the time of the call. The owners' balances must equal the ghost tally of
///      withdrawals and sweeps (minus their deposits).
contract AgentInvariantsTest is AgentFixture {
    // ------------------------------------------------------------------ action kinds

    uint256 internal constant BUY = 0;
    uint256 internal constant GRAD_BUY = 1;
    uint256 internal constant SELL = 2;
    uint256 internal constant SELL_GIFTED = 3;
    uint256 internal constant LAUNCH = 4;
    uint256 internal constant POOL_BUY = 5;
    uint256 internal constant POOL_SELL = 6;
    uint256 internal constant CLAIM = 7;
    uint256 internal constant SWEEP = 8;
    uint256 internal constant WITHDRAW = 9;
    uint256 internal constant TIGHTEN = 10;
    uint256 internal constant QUEUE_WIDEN = 11;
    uint256 internal constant EXECUTE = 12;
    uint256 internal constant ROTATE = 13;
    uint256 internal constant MARKET = 14;
    uint256 internal constant TRANSFER_OWNER = 15;
    /// @dev Kinds below this are positive (must succeed); the rest are expected reverts.
    uint256 internal constant POSITIVE = 16;
    uint256 internal constant N_STRANGER = 16;
    uint256 internal constant N_OWNER_TRADE = 17;
    uint256 internal constant N_REVOKED = 18;
    uint256 internal constant N_EXPIRED = 19;
    uint256 internal constant N_OWNER_PAUSED = 20;
    uint256 internal constant N_FACTORY_PAUSED = 21;
    uint256 internal constant N_EARLY = 22;
    uint256 internal constant N_CROSS = 23;
    uint256 internal constant N_OVER_CAP = 24;
    uint256 internal constant N_SPEND_CAP = 25;
    uint256 internal constant N_TOKEN_CAP = 26;
    uint256 internal constant N_SELL_CAP = 27;
    uint256 internal constant N_ACTION_LIMIT = 28;
    uint256 internal constant N_LAUNCH_LIMIT = 29;
    uint256 internal constant N_CEILING = 30;
    uint256 internal constant KINDS = 31;

    uint256 internal constant PERIOD = 1 hours;
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    AgentInvariantHandler internal handler;
    AgentAccount[2] internal accts;
    address[2] internal owners;
    /// @dev Current (not revoked) agents of each account, in the order they were added.
    mapping(uint256 => address[]) internal agentsOf;
    mapping(uint256 => address[]) internal revokedOf;
    mapping(uint256 => mapping(address => bool)) internal isCurrentAgent;
    address[2] internal expiring;
    /// @dev Addresses that must never gain or lose anything during an agent call.
    address[] internal watchList;
    LaunchToken[] internal toks;
    mapping(address => uint256) internal launcherOf;

    /// @dev A queued widening as the test saw it: queue time and the test-side write sequence at queue time, and
    ///      whether a pause or an ownership change has since killed it. No registry stamp or epoch is read.
    struct Pending {
        uint256 id;
        uint256 seq;
        uint256 queuedAt;
        bool killed;
        Policy target;
    }

    mapping(uint256 => Pending[]) internal pendingOf;
    /// @dev Test-side policy write ghosts: a sequence bumped by every write, each field's last write, and each field's
    ///      last tightening (sequence and value).
    uint256[2] internal ghostSeq;
    mapping(uint256 => uint256[11]) internal fieldSeq;
    mapping(uint256 => uint256[11]) internal tightSeq;
    mapping(uint256 => uint256[11]) internal tightVal;
    uint256[2] internal lastQueueId;
    uint256 internal nonce;
    uint256 internal guardianReadyAt;

    uint256[2] internal ownerStart;
    uint256[2] public ownerIn;
    uint256[2] public ownerOut;
    /// @dev Tokens received by each owner address (owners can change through TRANSFER_OWNER).
    mapping(address => mapping(address => uint256)) internal ownerTokIn;

    struct Ghost {
        uint64 period;
        uint256 spent;
        uint256 sold;
        uint256 maxSpendCap;
        uint256 maxSellCap;
        uint256 maxTokenCap;
    }

    Ghost[2] internal ghost;
    mapping(uint256 => mapping(uint64 => mapping(address => uint256))) internal ghostTokSpent;

    uint256[KINDS] public okCount;
    uint256 public steps;
    uint256 public stepSuccesses;
    uint256 public stepExpectedReverts;
    uint256 public graduatingBuys;
    uint256 public cancelledExecutions;
    uint256 public giftedPoolSells;
    uint256 public queueExpiries;
    uint256 public ownerExitsDuringPause;
    uint256 public notYetActiveRefusals;
    uint256 public ownershipTransfers;
    uint256 internal pausedFnCursor;
    uint256[6] public pausedFnsTried;
    uint256 public oddWeiSpendRefusals;
    /// @dev Account and registry calls that succeeded, and those refused as expected.
    uint256 public okCalls;
    uint256 public refusedCalls;

    // ------------------------------------------------------------------ setup

    function setUp() public override {
        super.setUp();
        owners[0] = accountOwner;
        owners[1] = makeAddr("owner b");
        uint256 t0 = _now();
        for (uint256 i; i < 2; ++i) {
            vm.deal(owners[i], 10_000_000e18);
            address main = makeAddr(string.concat("main agent ", vm.toString(i)));
            InitParams memory p = _defaults();
            p.policy = _base();
            p.periodSeconds = uint32(PERIOD);
            p.firstAgent = main;
            p.firstAgentExpiresAt = uint40(t0 + 180 days);
            accts[i] = _account(owners[i], bytes32(i), p);
            vm.deal(address(accts[i]), 50_000e18);
            _track(i, main);
            ownerStart[i] = owners[i].balance;
        }
        // A second, narrower agent and a short-lived one, both through the queue.
        uint256[2][2] memory ids;
        for (uint256 i; i < 2; ++i) {
            address second = makeAddr(string.concat("second agent ", vm.toString(i)));
            expiring[i] = makeAddr(string.concat("expiring agent ", vm.toString(i)));
            vm.startPrank(owners[i]);
            ids[i][0] =
                registry.addAgent(address(accts[i]), second, uint40(t0 + 179 days), P_BUY | P_SELL | P_POOL_SWAP);
            ids[i][1] = registry.addAgent(address(accts[i]), expiring[i], uint40(t0 + 4 hours), P_ALL);
            vm.stopPrank();
            lastQueueId[i] = ids[i][1];
            _track(i, second);
            _track(i, expiring[i]);
        }
        vm.warp(t0 + 1 hours);
        for (uint256 i; i < 2; ++i) {
            registry.executeQueued(address(accts[i]), ids[i][0]);
            registry.executeQueued(address(accts[i]), ids[i][1]);
        }

        // Curve tokens in both orderings, and two graduated pools (both orderings).
        for (uint256 k; k < 3; ++k) {
            (LaunchToken t,) = _createOrdered(k % 2 == 0);
            toks.push(t);
        }
        for (uint256 k; k < 2; ++k) {
            (LaunchToken t, BondingCurve c) = _createOrdered(k == 0);
            _graduate(c);
            toks.push(t);
        }

        address[17] memory fixed_ = [
            stranger,
            bob,
            alice,
            creator,
            referrer,
            treasuryAddr,
            address(permit2),
            address(router),
            address(quoter),
            address(this),
            agentAdmin,
            agentGuardian,
            address(agentFactory),
            address(registry),
            address(agentImpl),
            guardian,
            trader
        ];
        for (uint256 k; k < fixed_.length; ++k) {
            watchList.push(fixed_[k]);
        }
        for (uint256 i; i < 2; ++i) {
            _sync(i);
        }

        handler = new AgentInvariantHandler(this);
        watchList.push(address(handler));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AgentInvariantHandler.step.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The base policy: the spec defaults with room for pool impact and a one-hour period (usdc6 amounts).
    function _base() internal pure returns (Policy memory p) {
        p = _defaultPolicy();
        p.maxTradeUsdc = 100e6;
        p.periodSpendCap = 600e6;
        p.perTokenPeriodCap = 250e6;
        p.periodSellCap = 400e6;
        p.maxActionsPerPeriod = 400;
        p.maxPriceImpactBps = 2_000;
    }

    function _track(uint256 i, address a) internal {
        agentsOf[i].push(a);
        isCurrentAgent[i][a] = true;
        watchList.push(a);
    }

    // ------------------------------------------------------------------ the step

    function step(uint256 seed) external {
        require(msg.sender == address(handler), "handler only");
        ++steps;
        Policy[2] memory before = [registry.policy(address(accts[0])), registry.policy(address(accts[1]))];
        uint256 kind = _pick(seed);
        if (kind < POSITIVE) {
            _positive(kind, seed);
            ++stepSuccesses;
        } else {
            _negative(kind, seed);
            ++stepExpectedReverts;
        }
        ++okCount[kind];
        // No path but a matured queued item may loosen a policy (spec 5.6); EXECUTE checks its own merge.
        for (uint256 i; i < 2; ++i) {
            if (kind != EXECUTE) {
                assertTrue(
                    AgentPolicyLib.isNarrowing(before[i], registry.policy(address(accts[i]))), "loosened outside queue"
                );
            }
            _sync(i);
            _assertAgentsAreKnown(i);
        }
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        if (steps % 3 != 0) {
            for (uint256 k; k < KINDS; ++k) {
                if (okCount[k] == 0) return k;
            }
        }
        uint256 r = _r(seed, 99) % 100;
        uint8[16] memory w = [16, 3, 11, 5, 5, 10, 9, 3, 5, 5, 5, 3, 3, 2, 6, 1]; // sums to 92
        for (uint256 k; k < 16; ++k) {
            if (r < w[k]) return k;
            r -= w[k];
        }
        // The remaining 8%: a negative kind (coverage already reaches each one every run).
        return POSITIVE + _r(seed, 98) % (KINDS - POSITIVE);
    }

    function _positive(uint256 kind, uint256 seed) internal {
        if (kind == BUY) _actBuy(seed);
        else if (kind == GRAD_BUY) _actGradBuy(seed);
        else if (kind == SELL) _actSell(seed);
        else if (kind == SELL_GIFTED) _actSellGifted(seed);
        else if (kind == LAUNCH) _actLaunch(seed);
        else if (kind == POOL_BUY) _actPoolBuy(seed);
        else if (kind == POOL_SELL) _actPoolSell(seed);
        else if (kind == CLAIM) _actClaim(seed);
        else if (kind == SWEEP) _actSweep(seed);
        else if (kind == WITHDRAW) _actWithdraw(seed);
        else if (kind == TIGHTEN) _actTighten(seed % 2, seed);
        else if (kind == QUEUE_WIDEN) _actQueueWiden(seed % 2, seed);
        else if (kind == EXECUTE) _actExecute(seed);
        else if (kind == ROTATE) _actRotate(seed % 2, seed);
        else if (kind == MARKET) _actMarket(seed);
        else _actTransferOwner(seed);
    }

    function _negative(uint256 kind, uint256 seed) internal {
        if (kind == N_STRANGER) _negStranger(seed);
        else if (kind == N_OWNER_TRADE) _negOwnerTrade(seed);
        else if (kind == N_REVOKED) _negRevoked(seed);
        else if (kind == N_EXPIRED) _negExpired(seed);
        else if (kind == N_OWNER_PAUSED) _negOwnerPaused(seed);
        else if (kind == N_FACTORY_PAUSED) _negFactoryPaused(seed);
        else if (kind == N_EARLY) _negEarly(seed);
        else if (kind == N_CROSS) _negCross(seed);
        else if (kind == N_OVER_CAP) _negOverCap(seed);
        else if (kind == N_SPEND_CAP) _negSpendCap(seed, false);
        else if (kind == N_TOKEN_CAP) _negSpendCap(seed, true);
        else if (kind == N_SELL_CAP) _negSellCap(seed);
        else if (kind == N_ACTION_LIMIT) _negActionLimit(seed);
        else if (kind == N_LAUNCH_LIMIT) _negLaunchLimit(seed);
        else _negCeiling(seed);
    }

    // ------------------------------------------------------------------ small helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _pid() internal view returns (uint64) {
        return uint64(_now() / PERIOD);
    }

    function _dl() internal view returns (uint256) {
        return _now() + 60;
    }

    function _r(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// @dev `lo + x mod (hi - lo + 1)`, without forge-std's logging.
    function _b(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + x % (hi - lo + 1);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _curve(address t) internal view returns (BondingCurve) {
        return BondingCurve(factory.curveOf(t));
    }

    function _acct(uint256 i) internal view returns (address) {
        return address(accts[i]);
    }

    function _policy(uint256 i) internal view returns (Policy memory) {
        return registry.policy(_acct(i));
    }

    function _nextPeriod() internal {
        vm.warp((_now() / PERIOD + 1) * PERIOD);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Moves to the next period when this period cannot fit the action (headroom per registry), and has the
    ///      owner top the account up when long runs have spent it down.
    function _ensureRoom(uint256 i, uint256 spend, uint256 sell, bool launch) internal {
        if (_acct(i).balance < 2_000e18) _deposit(i, 50_000e18);
        (uint64 spendLeft, uint64 sellLeft, uint32 actionsLeft, uint16 launchesLeft) = registry.headroom(_acct(i));
        if (spendLeft < spend || sellLeft < sell || actionsLeft < 6 || (launch && launchesLeft == 0)) _nextPeriod();
    }

    function _tokenLeft(uint256 i, address t) internal view returns (uint256) {
        uint256 cap = _policy(i).perTokenPeriodCap;
        uint256 used = registry.tokenSpent(_acct(i), t);
        return cap > used ? cap - used : 0;
    }

    function _spendLeft(uint256 i) internal view returns (uint256 left) {
        (left,,,) = registry.headroom(_acct(i));
    }

    function _sellLeft(uint256 i) internal view returns (uint256 left) {
        (, left,,) = registry.headroom(_acct(i));
    }

    function _agentWith(uint256 i, uint16 perm, uint256 seed) internal view returns (address) {
        address[] storage list = agentsOf[i];
        address[] memory c = new address[](list.length);
        uint256 n;
        for (uint256 k; k < list.length; ++k) {
            Agent memory a = registry.agent(_acct(i), list[k]);
            // A margin, so an action's own warps (at most a period end) cannot expire the key mid-action.
            if (a.active && _now() + 3 hours < a.expiresAt && a.permissions & perm != 0) c[n++] = list[k];
        }
        require(n != 0, "no agent for the permission");
        return c[seed % n];
    }

    function _passSnipe(BondingCurve c) internal {
        if (c.currentSnipeBps() > 0) vm.roll(c.launchBlock() + c.snipeBlocks());
    }

    function _newToken(uint256 seed) internal returns (LaunchToken t, BondingCurve c) {
        (t, c) = _createOrdered(seed % 2 == 0);
        toks.push(t);
    }

    /// @dev A trading curve token that `probeWei` of buying would not sell out, past its snipe window.
    function _tradingToken(uint256 seed, uint256 probeWei) internal returns (LaunchToken t, BondingCurve c) {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            t = toks[(seed % n + k) % n];
            c = _curve(address(t));
            if (c.phase() != BondingCurve.Phase.Trading) continue;
            (uint256 out,,,) = c.quoteBuy(probeWei);
            if (out < c.curveSupply() - c.sold()) {
                _passSnipe(c);
                return (t, c);
            }
        }
        (t, c) = _newToken(seed);
        _passSnipe(c);
    }

    function _graduatedToken(uint256 seed) internal returns (LaunchToken t) {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            t = toks[(seed % n + k) % n];
            if (_curve(address(t)).phase() == BondingCurve.Phase.Graduated) return t;
        }
        BondingCurve c;
        (t, c) = _newToken(seed);
        vm.deal(bob, 1_000_000e18);
        _graduate(c);
    }

    /// @dev Cost-basis value of `rec` recorded tokens, mirroring the account's rule (usdc6).
    function _recV(address acct, address t, uint256 rec) internal view returns (uint256) {
        (uint128 cost, uint128 tokens, uint256 hw) = AgentAccount(payable(acct)).basis(t);
        if (rec == 0 || tokens == 0) return 0;
        uint256 v = Math.mulDiv(rec, cost, tokens, Math.Rounding.Ceil);
        uint256 h = Math.mulDiv(rec, hw, 1e36);
        return h > v ? h : v;
    }

    /// @dev The largest amount at most `target` whose recorded value is at most `limit` (value is monotonic).
    function _fitRecorded(address acct, address t, uint256 target, uint256 limit) internal view returns (uint256) {
        if (_recV(acct, t, target) <= limit) return target;
        uint256 lo;
        uint256 hi = target;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_recV(acct, t, mid) <= limit) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function _poolQuote(uint256 i, address t, bool buyToken, uint256 amountIn) internal returns (uint256 out) {
        PoolKey memory key = gm.poolKey(t);
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(
                key, buyToken == usdcIs0, uint128(amountIn), abi.encode(uint256(uint160(_acct(i))))
            )
        );
    }

    // ------------------------------------------------------------------ conservation and isolation

    struct Pre {
        uint256 sysNative;
        bytes32 watchNative;
        uint256 sysTok;
        bytes32 watchTok;
        bytes32 other;
        uint256 acctNative;
        uint256 acctTok;
        uint256 ownerNative;
        uint256 ownerTok;
    }

    function _pre(uint256 i, address t) internal view returns (Pre memory s) {
        s.sysNative = _sysNative(address(0));
        s.watchNative = _watch(address(0));
        s.other = _digest(1 - i);
        s.acctNative = _acct(i).balance;
        s.ownerNative = owners[i].balance;
        if (t != address(0)) {
            s.sysTok = _sysTok(t);
            s.watchTok = _watch(t);
            s.acctTok = IERC20(t).balanceOf(_acct(i));
            s.ownerTok = IERC20(t).balanceOf(owners[i]);
        }
    }

    /// @dev Invariant 1 per call: value stays inside {accounts, owners, Launch and Uniswap contracts}, no outside
    ///      address moves, and account `1 - i` is untouched by a call made through account `i`.
    function _post(uint256 i, address t, Pre memory s, address newCurve) internal view {
        assertEq(_sysNative(newCurve), s.sysNative, "native USDC left the system");
        assertEq(_watch(address(0)), s.watchNative, "native USDC reached an outside address");
        if (t != address(0)) {
            assertEq(_sysTok(t), s.sysTok, "tokens left the system");
            assertEq(_watch(t), s.watchTok, "tokens reached an outside address");
        }
        assertEq(_digest(1 - i), s.other, "a call through one account changed the other");
        assertEq(IERC20(USDC).balanceOf(_acct(i)), _acct(i).balance / 1e12, "USDC view is the native balance");
        assertEq(IERC20(USDC).balanceOf(_acct(1 - i)), _acct(1 - i).balance / 1e12);
    }

    function _sysNative(address extra) internal view returns (uint256 sum) {
        address[9] memory core = [
            _acct(0),
            _acct(1),
            owners[0],
            owners[1],
            address(feeManager),
            address(gm),
            address(hook),
            address(locker),
            address(poolManager)
        ];
        for (uint256 k; k < core.length; ++k) {
            sum += core[k].balance;
        }
        sum += address(posm).balance + address(factory).balance + extra.balance;
        for (uint256 k; k < toks.length; ++k) {
            sum += address(_curve(address(toks[k]))).balance;
        }
    }

    function _sysTok(address t) internal view returns (uint256 sum) {
        address[11] memory core = [
            _acct(0),
            _acct(1),
            owners[0],
            owners[1],
            address(_curve(t)),
            address(gm),
            address(poolManager),
            address(locker),
            address(posm),
            address(hook),
            address(feeManager)
        ];
        for (uint256 k; k < core.length; ++k) {
            sum += IERC20(t).balanceOf(core[k]);
        }
    }

    function _watch(address t) internal view returns (bytes32 h) {
        for (uint256 k; k < watchList.length; ++k) {
            address a = watchList[k];
            h = keccak256(abi.encode(h, t == address(0) ? a.balance : IERC20(t).balanceOf(a)));
        }
    }

    /// @dev Everything the registry and the account hold for account `j`.
    function _digest(uint256 j) internal view returns (bytes32 h) {
        address a = _acct(j);
        h = keccak256(
            abi.encode(
                registry.owner(a),
                registry.policy(a),
                registry.increaseDelay(a),
                registry.activeAgentCount(a),
                registry.ownerPaused(a),
                registry.writeSeq(a),
                registry.epoch(a),
                registry.delayWrite(a),
                a.balance,
                AgentAccount(payable(a)).referrer()
            )
        );
        {
            (uint64 p, uint64 sp, uint64 so, uint32 ac, uint16 la) = registry.usage(a);
            h = keccak256(abi.encode(h, p, sp, so, ac, la));
        }
        for (uint256 k; k < 11; ++k) {
            h = keccak256(abi.encode(h, registry.policyWrite(a, k)));
        }
        for (uint256 k; k < watchList.length; ++k) {
            address x = watchList[k];
            h = keccak256(abi.encode(h, registry.agent(a, x), registry.retired(a, x), registry.agentWrite(a, x)));
        }
        for (uint256 k; k < toks.length; ++k) {
            address t = address(toks[k]);
            (uint128 c, uint128 n, uint256 hw) = AgentAccount(payable(a)).basis(t);
            h = keccak256(
                abi.encode(
                    h,
                    registry.tokenSpent(a, t),
                    registry.tokenAllowed(a, t),
                    registry.tokenWrite(a, t),
                    IERC20(t).balanceOf(a),
                    c,
                    n,
                    hw
                )
            );
        }
        for (uint256 id = 1; id <= lastQueueId[j]; ++id) {
            (uint8 kind, uint40 eta, uint64 ep, uint64 seq, bytes memory payload) = registry.queued(a, id);
            h = keccak256(abi.encode(h, kind, eta, ep, seq, payload));
        }
    }

    // ------------------------------------------------------------------ ghosts: invariant 2

    /// @dev Rolls the ghost period and raises the period's highest caps to the policy now in force.
    function _sync(uint256 i) internal {
        Ghost storage g = ghost[i];
        Policy memory p = _policy(i);
        if (g.period != _pid()) {
            g.period = _pid();
            g.spent = 0;
            g.sold = 0;
            g.maxSpendCap = 0;
            g.maxSellCap = 0;
            g.maxTokenCap = 0;
        }
        if (p.periodSpendCap > g.maxSpendCap) g.maxSpendCap = p.periodSpendCap;
        if (p.periodSellCap > g.maxSellCap) g.maxSellCap = p.periodSellCap;
        if (p.perTokenPeriodCap > g.maxTokenCap) g.maxTokenCap = p.perTokenPeriodCap;
    }

    /// @dev Adds one action's measured spend (or computed sell value) to the ghost, checks every cap as it stood at
    ///      the call, and checks that the registry charged exactly that (unit consistency, spec 5.8).
    function _charge(uint256 i, address t, uint256 spent, uint256 sold) internal {
        Policy memory p = _policy(i);
        Ghost storage g = ghost[i];
        assertEq(g.period, _pid(), "ghost period");
        g.spent += spent;
        g.sold += sold;
        uint256 tokSpent = ghostTokSpent[i][g.period][t] += spent;
        assertLe(spent > sold ? spent : sold, p.maxTradeUsdc, "an action above maxTradeUsdc");
        // A cap may have been lowered below this period's usage since; only what this action charged is checked
        // against the cap now in force, as the registry does.
        if (spent != 0) {
            assertLe(g.spent, p.periodSpendCap, "period spend above its cap");
            assertLe(tokSpent, p.perTokenPeriodCap, "per-token spend above its cap");
        }
        if (sold != 0) assertLe(g.sold, p.periodSellCap, "period sells above their cap");
        (, uint64 rSpent, uint64 rSold,,) = registry.usage(_acct(i));
        assertEq(rSpent, g.spent, "registry spend equals the measured spend");
        assertEq(rSold, g.sold, "registry sells equal the computed values");
        assertEq(registry.tokenSpent(_acct(i), t), tokSpent, "registry token spend");
    }

    // ------------------------------------------------------------------ agent calls (wrapped)

    function _agentBuy(uint256 i, address agent, address t, uint256 amt) internal returns (uint256 out) {
        Pre memory s = _pre(i, t);
        (uint128 cost0, uint128 tok0,) = accts[i].basis(t);
        _sync(i);
        uint256 dl = _dl();
        vm.prank(agent);
        out = accts[i].buy(t, amt, 1, dl);
        _post(i, t, s, address(0));
        ++okCalls;
        uint256 paid = s.acctNative - _acct(i).balance;
        assertLe(paid, amt * 1e12, "a buy took more than its input");
        assertEq(IERC20(t).balanceOf(_acct(i)) - s.acctTok, out, "tokens received");
        assertEq(owners[i].balance, s.ownerNative, "owner untouched");
        uint256 spent = Math.ceilDiv(paid, 1e12);
        _charge(i, t, spent, 0);
        (uint128 cost1, uint128 tok1,) = accts[i].basis(t);
        assertEq(cost1, cost0 + spent, "basis cost grows by the spend");
        assertEq(tok1, tok0 + out, "basis tokens grow by the tokens");
    }

    function _agentSell(uint256 i, address agent, address t, uint256 tokensIn, uint256 value) internal {
        Pre memory s = _pre(i, t);
        (uint128 cost0, uint128 tok0, uint256 hw0) = accts[i].basis(t);
        _sync(i);
        uint256 dl = _dl();
        vm.prank(agent);
        uint256 usdcOut = accts[i].sell(t, tokensIn, 1, dl);
        _post(i, t, s, address(0));
        ++okCalls;
        _afterSell(i, t, s, tokensIn, usdcOut, value, cost0, tok0, hw0);
    }

    function _afterSell(
        uint256 i,
        address t,
        Pre memory s,
        uint256 tokensIn,
        uint256 usdcOut,
        uint256 value,
        uint128 cost0,
        uint128 tok0,
        uint256 hw0
    ) internal {
        assertEq(s.acctTok - IERC20(t).balanceOf(_acct(i)), tokensIn, "sold exactly tokensIn");
        uint256 received = _acct(i).balance - s.acctNative;
        assertEq(usdcOut, received / 1e12, "proceeds round down");
        assertEq(owners[i].balance, s.ownerNative, "owner untouched");
        _charge(i, t, 0, value);
        (uint128 cost1, uint128 tok1, uint256 hw1) = accts[i].basis(t);
        uint256 rec = tokensIn < tok0 ? tokensIn : tok0;
        if (rec == tok0) {
            assertEq(tok1, 0, "closed");
            assertEq(cost1, 0, "closed cost");
            assertEq(hw1, 0, "closed high-water");
        } else {
            assertEq(tok1, tok0 - rec, "basis tokens cut");
            assertEq(cost1, cost0 - Math.mulDiv(cost0, rec, tok0), "basis cost cut pro rata");
            assertEq(hw1, hw0, "high-water kept");
        }
    }

    function _agentPoolBuy(uint256 i, address agent, address t, uint256 amt) internal {
        Pre memory s = _pre(i, t);
        (uint128 cost0, uint128 tok0,) = accts[i].basis(t);
        _sync(i);
        uint256 dl = _dl();
        vm.prank(agent);
        uint256 out = accts[i].swapExactIn(t, true, amt, 1, dl);
        _post(i, t, s, address(0));
        ++okCalls;
        assertEq(s.acctNative - _acct(i).balance, amt * 1e12, "a pool buy takes exactly its input");
        assertEq(IERC20(t).balanceOf(_acct(i)) - s.acctTok, out, "tokens received");
        assertEq(owners[i].balance, s.ownerNative, "owner untouched");
        _charge(i, t, amt, 0);
        (uint128 cost1, uint128 tok1,) = accts[i].basis(t);
        assertEq(cost1, cost0 + amt);
        assertEq(tok1, tok0 + out);
    }

    function _agentPoolSell(uint256 i, address agent, address t, uint256 amountIn, uint256 recordedValue) internal {
        Pre memory s = _pre(i, t);
        (uint128 cost0, uint128 tok0, uint256 hw0) = accts[i].basis(t);
        _sync(i);
        uint256 dl = _dl();
        vm.prank(agent);
        uint256 out = accts[i].swapExactIn(t, false, amountIn, 1, dl);
        _post(i, t, s, address(0));
        ++okCalls;
        uint256 receivedWei = _acct(i).balance - s.acctNative;
        uint256 value = recordedValue;
        if (amountIn > tok0) {
            value += Math.ceilDiv(Math.mulDiv(receivedWei, amountIn - tok0, amountIn, Math.Rounding.Ceil), 1e12);
        }
        _afterSell(i, t, s, amountIn, out, value, cost0, tok0, hw0);
    }

    // ------------------------------------------------------------------ positive actions

    function _actBuy(uint256 seed) internal {
        uint256 i = seed % 2;
        _buyOn(i, seed, address(0));
    }

    /// @dev One bounded curve buy for account `i` (on `want` when it is a trading token, else on any).
    function _buyOn(uint256 i, uint256 seed, address want) internal returns (address t, uint256 out) {
        _ensureRoom(i, 2e6, 0, false);
        BondingCurve c;
        if (want != address(0) && _curve(want).phase() == BondingCurve.Phase.Trading) {
            t = want;
            c = _curve(want);
            _passSnipe(c);
        } else {
            LaunchToken lt;
            (lt, c) = _tradingToken(_r(seed, 1), 200e18);
            t = address(lt);
        }
        Policy memory p = _policy(i);
        uint256 cap = _min(_min(p.maxTradeUsdc, _spendLeft(i)), _tokenLeft(i, t));
        if (cap < 1e6) {
            _nextPeriod();
            _passSnipe(c);
            cap = _min(_min(p.maxTradeUsdc, p.periodSpendCap), p.perTokenPeriodCap);
        }
        uint256 amt = _b(_r(seed, 2), 1e6, cap) - _r(seed, 3) % 1e6; // at least 1 usdc6, odd amounts
        // Keep it a non-graduating buy within the impact limit.
        for (uint256 k; k < 40; ++k) {
            (uint256 q, uint256 used, uint256 fee, uint256 tax) = c.quoteBuy(amt * 1e12);
            bool fits = q != 0 && q < c.curveSupply() - c.sold()
                && AgentPolicyLib.buyImpactBps(used - fee - tax, q, c.price()) <= p.maxPriceImpactBps;
            if (fits) break;
            amt = amt / 2 + 1;
        }
        out = _agentBuy(i, _agentWith(i, P_BUY, seed), t, amt);
    }

    /// @dev Bob fills a curve to leave less than one capped buy (plus odd wei, so the refund is not a multiple of
    ///      1e12); the agent's buy then sells it out and graduates it inside the call (Review Focus 3).
    function _actGradBuy(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 5e6, 0, false);
        (LaunchToken lt, BondingCurve c) = _tradingToken(_r(seed, 1), 0);
        address t = address(lt);
        Policy memory p = _policy(i);
        uint256 cap = _min(_min(p.maxTradeUsdc, _spendLeft(i)), _tokenLeft(i, t));
        if (cap < 5e6) {
            _nextPeriod();
            (lt, c) = _newToken(seed);
            t = address(lt);
            _passSnipe(c);
            cap = _min(_min(p.maxTradeUsdc, p.periodSpendCap), p.perTokenPeriodCap);
        }
        uint256 leave = _b(_r(seed, 2), 1e18, cap * 1e12 * 8 / 10) + _r(seed, 3) % 1e12;
        (, uint256 full,,) = c.quoteBuy(1e30);
        if (full > leave) {
            vm.deal(bob, 1_000_000e18);
            vm.prank(bob);
            c.buy{value: full - leave}(0, address(0), type(uint256).max);
        }
        (uint256 q, uint256 used,,) = c.quoteBuy(cap * 1e12);
        assertEq(q, c.curveSupply() - c.sold(), "the capped buy is the final buy");
        uint256 out = _agentBuy(i, _agentWith(i, P_BUY, seed), t, cap);
        assertEq(out, q);
        assertEq(uint8(c.phase()), uint8(BondingCurve.Phase.Graduated), "graduated inside the buy");
        assertLe(used, cap * 1e12);
        ++graduatingBuys;
    }

    function _actSell(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 5e6, 2e6, false);
        address agent = _agentWith(i, P_SELL, seed);
        address t = _heldOnCurve(i, seed);
        if (t == address(0)) {
            (t,) = _buyOn(i, seed, address(0));
            ++okCount[BUY];
        }
        uint256 limit = _min(_policy(i).maxTradeUsdc, _sellLeft(i));
        (, uint128 held,) = accts[i].basis(t);
        uint256 tokensIn = _fitRecorded(_acct(i), t, _b(_r(seed, 4), 1, held), limit);
        BondingCurve c = _curve(t);
        (uint256 q,) = c.quoteSell(tokensIn);
        if (q < 1e12) {
            // Dust: sell the largest amount the caps allow instead, or a fresh lot.
            tokensIn = _fitRecorded(_acct(i), t, held, limit);
            (q,) = c.quoteSell(tokensIn);
            if (q < 1e12) {
                (t,) = _buyOn(i, _r(seed, 5), address(0));
                ++okCount[BUY];
                (, held,) = accts[i].basis(t);
                c = _curve(t);
                limit = _min(_policy(i).maxTradeUsdc, _sellLeft(i));
                tokensIn = _fitRecorded(_acct(i), t, held, limit);
            }
        }
        tokensIn = _fitCurveSellImpact(i, c, tokensIn);
        _agentSell(i, agent, t, tokensIn, _recV(_acct(i), t, tokensIn));
    }

    function _fitCurveSellImpact(uint256 i, BondingCurve c, uint256 tokensIn) internal view returns (uint256) {
        uint256 maxBps = _policy(i).maxPriceImpactBps;
        for (uint256 k; k < 40; ++k) {
            (uint256 q, uint256 fee) = c.quoteSell(tokensIn);
            if (AgentPolicyLib.sellImpactBps(q + fee, tokensIn, c.price()) <= maxBps) break;
            tokensIn /= 2;
        }
        return tokensIn;
    }

    /// @dev A curve token (trading or pending) with a recorded position worth selling.
    function _heldOnCurve(uint256 i, uint256 seed) internal view returns (address) {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            address t = address(toks[(seed % n + k) % n]);
            BondingCurve c = _curve(t);
            if (c.phase() == BondingCurve.Phase.Graduated) continue;
            (, uint128 held,) = accts[i].basis(t);
            if (held == 0) continue;
            (uint256 q,) = c.quoteSell(held);
            if (q >= 2e12) return t;
        }
        return address(0);
    }

    /// @dev A stranger (Bob) sends tokens to the account; the stolen-key-style sell of recorded plus gifted tokens
    ///      must not revert, is valued at cost plus the excess's quote, and gives no spend headroom (Review Focus 4).
    function _actSellGifted(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 0, 10e6, false);
        uint256 limit = _min(_policy(i).maxTradeUsdc, _sellLeft(i));
        // A trading token whose recorded position is worth at most half the limit.
        (LaunchToken lt, BondingCurve c) = _tradingToken(_r(seed, 1), 200e18);
        address t = address(lt);
        (, uint128 held,) = accts[i].basis(t);
        if (_recV(_acct(i), t, held) > limit / 2) {
            (lt, c) = _newToken(seed);
            t = address(lt);
            _passSnipe(c);
            held = 0;
        }
        // Bob buys 1-20 USDC (odd wei) and sends the tokens over.
        uint256 giftWei = _b(_r(seed, 2), 1e18, _min(20e18, (limit / 2) * 1e12)) + _r(seed, 3) % 1e12;
        uint256 bobBefore = lt.balanceOf(bob);
        vm.deal(bob, 1_000_000e18);
        vm.prank(bob);
        c.buy{value: giftWei}(0, address(0), type(uint256).max);
        uint256 gift = lt.balanceOf(bob) - bobBefore;
        vm.prank(bob);
        lt.transfer(_acct(i), gift);
        // Sell the recorded position plus part of what is unrecorded.
        uint256 unrecorded = lt.balanceOf(_acct(i)) - held;
        uint256 excess = _b(_r(seed, 4), 1, unrecorded);
        uint256 tokensIn = held + excess;
        (uint256 qx,) = c.quoteSell(excess);
        uint256 value = _recV(_acct(i), t, held) + Math.ceilDiv(qx, 1e12);
        (uint256 q,) = c.quoteSell(tokensIn);
        if (value > limit || q < 1e12) {
            // Sell only stranger tokens' worth: the whole gift alone.
            tokensIn = held + gift;
            (qx,) = c.quoteSell(gift);
            value = _recV(_acct(i), t, held) + Math.ceilDiv(qx, 1e12);
        }
        assertLe(value, limit, "gift sized within the caps");
        (uint64 spendHeadroom,,,) = registry.headroom(_acct(i));
        _agentSell(i, _agentWith(i, P_SELL, seed), t, tokensIn, value);
        (uint64 spendAfter,,,) = registry.headroom(_acct(i));
        assertEq(spendAfter, spendHeadroom, "stranger tokens give no buy headroom");
    }

    function _actLaunch(uint256 seed) internal {
        uint256 i = seed % 2;
        _launchFor(i, seed);
    }

    function _launchFor(uint256 i, uint256 seed) internal returns (address token) {
        _ensureRoom(i, 2e6, 0, true);
        Policy memory p = _policy(i);
        uint256 feeUsdc = Math.ceilDiv(cfg.launchFee, 1e12);
        uint256 room = _min(_min(p.maxTradeUsdc, _spendLeft(i)), p.perTokenPeriodCap);
        if (room < feeUsdc) {
            _nextPeriod();
            room = _min(_min(p.maxTradeUsdc, p.periodSpendCap), p.perTokenPeriodCap);
        }
        LaunchRequest memory r;
        r.name = "Invariant Token";
        r.symbol = "INV";
        r.metadataURI = "https://example.invalid/inv.json";
        r.salt = bytes32(++nonce);
        r.expectedConfigHash = factory.configHash();
        r.initialBuyUsdc = _b(_r(seed, 1), 0, _min(room - feeUsdc, 50e6));
        r.minTokensOut = r.initialBuyUsdc == 0 ? 0 : 1;
        r.deadline = _dl();
        address agent = _agentWith(i, P_LAUNCH, seed);

        Pre memory s = _pre(i, address(0));
        _sync(i);
        vm.prank(agent);
        (address t, address c) = accts[i].launch(r);
        _post(i, address(0), s, c);
        ++okCalls;
        uint256 paid = s.acctNative - _acct(i).balance;
        assertLe(paid, cfg.launchFee + r.initialBuyUsdc * 1e12, "a launch took more than fee plus buy");
        assertEq(feeManagerCreator(t), _acct(i), "the account is the creator");
        toks.push(LaunchToken(t));
        launcherOf[t] = i + 1;
        uint256 spent = Math.ceilDiv(paid, 1e12);
        _charge(i, t, spent, 0);
        (uint128 cost, uint128 tokens,) = accts[i].basis(t);
        assertEq(tokens, IERC20(t).balanceOf(_acct(i)), "initial buy recorded");
        assertEq(cost, tokens == 0 ? 0 : spent - feeUsdc, "basis excludes the launch fee");
        return t;
    }

    function feeManagerCreator(address t) internal view returns (address) {
        return feeManager.tokenInfo(t).creator;
    }

    function _actPoolBuy(uint256 seed) internal {
        uint256 i = seed % 2;
        _poolBuyFor(i, seed);
    }

    function _poolBuyFor(uint256 i, uint256 seed) internal returns (address t) {
        _ensureRoom(i, 2e6, 0, false);
        t = address(_graduatedToken(_r(seed, 1)));
        Policy memory p = _policy(i);
        uint256 cap = _min(_min(p.maxTradeUsdc, _spendLeft(i)), _tokenLeft(i, t));
        if (cap < 1e6) {
            _nextPeriod();
            cap = _min(_min(p.maxTradeUsdc, p.periodSpendCap), p.perTokenPeriodCap);
        }
        uint256 amt = _b(_r(seed, 2), 1e6, cap) - _r(seed, 3) % 1e6;
        _agentPoolBuy(i, _agentWith(i, P_POOL_SWAP, seed), t, amt);
    }

    function _actPoolSell(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 5e6, 5e6, false);
        address agent = _agentWith(i, P_POOL_SWAP, seed);
        address t = _heldInPool(i, seed);
        if (t == address(0)) {
            t = _poolBuyFor(i, _r(seed, 1));
            ++okCount[POOL_BUY];
        }
        uint256 limit = _min(_policy(i).maxTradeUsdc, _sellLeft(i));
        (, uint128 held,) = accts[i].basis(t);
        bool gifted = _r(seed, 2) % 3 == 0;
        uint256 amountIn;
        uint256 recValue;
        if (gifted) {
            // Recorded part worth at most half the limit, plus a stranger's tokens worth at most a quarter.
            amountIn = _fitRecorded(_acct(i), t, held, limit / 2);
            recValue = _recV(_acct(i), t, amountIn);
            if (amountIn == held) {
                uint256 gift = _giftFromBob(i, t, _r(seed, 3), limit / 4);
                amountIn += gift;
                ++giftedPoolSells;
            }
        } else {
            amountIn = _fitRecorded(_acct(i), t, _b(_r(seed, 4), 1, held), limit);
            recValue = _recV(_acct(i), t, amountIn);
        }
        if (_poolQuote(i, t, false, amountIn) == 0) {
            amountIn = _fitRecorded(_acct(i), t, held, limit);
            recValue = _recV(_acct(i), t, amountIn);
            if (_poolQuote(i, t, false, amountIn) == 0) {
                t = _poolBuyFor(i, _r(seed, 5));
                ++okCount[POOL_BUY];
                (, held,) = accts[i].basis(t);
                amountIn = _fitRecorded(_acct(i), t, held, _min(_policy(i).maxTradeUsdc, _sellLeft(i)));
                recValue = _recV(_acct(i), t, amountIn);
            }
        }
        _agentPoolSell(i, agent, t, amountIn, recValue);
    }

    /// @dev Bob sends the account graduated tokens quoted at about `maxUsdc6` or less; returns the amount sent.
    function _giftFromBob(uint256 i, address t, uint256 seed, uint256 maxUsdc6) internal returns (uint256 gift) {
        uint256 bobBal = IERC20(t).balanceOf(bob);
        if (bobBal == 0 || maxUsdc6 < 2) return 0;
        gift = _b(seed, 1, bobBal / 1000);
        for (uint256 k; k < 60 && gift > 1; ++k) {
            if (_poolQuote(i, t, false, gift) <= maxUsdc6) break;
            gift /= 2;
        }
        vm.prank(bob);
        IERC20(t).transfer(_acct(i), gift);
    }

    function _heldInPool(uint256 i, uint256 seed) internal returns (address) {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            address t = address(toks[(seed % n + k) % n]);
            if (_curve(t).phase() != BondingCurve.Phase.Graduated) continue;
            (, uint128 held,) = accts[i].basis(t);
            if (held == 0) continue;
            if (_poolQuote(i, t, false, held) >= 2) return t;
        }
        return address(0);
    }

    function _actClaim(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 2e6, 0, true);
        if (feeManager.balances(_acct(i)) == 0) {
            address t = _launchedTrading(i);
            if (t == address(0)) {
                t = _launchFor(i, _r(seed, 1));
                ++okCount[LAUNCH];
            }
            // A third party trades the account's token, accruing creator fees to it.
            vm.deal(bob, 1_000_000e18);
            vm.prank(bob);
            _curve(t).buy{value: _b(_r(seed, 2), 1e18, 50e18)}(0, address(0), type(uint256).max);
        }
        uint256 owed = feeManager.balances(_acct(i));
        assertGt(owed, 0, "fees owed");
        address agent = _agentWith(i, P_CLAIM, seed);
        Pre memory s = _pre(i, address(0));
        _sync(i);
        vm.prank(agent);
        uint256 claimed = accts[i].claimFees();
        _post(i, address(0), s, address(0));
        ++okCalls;
        assertEq(_acct(i).balance - s.acctNative, owed, "the whole balance is claimed to the account");
        assertEq(claimed, owed / 1e12, "claimed rounds down");
        assertEq(feeManager.balances(_acct(i)), 0);
        assertEq(owners[i].balance, s.ownerNative, "owner untouched");
        _charge(i, address(0), 0, 0);
    }

    function _launchedTrading(uint256 i) internal view returns (address) {
        for (uint256 k; k < toks.length; ++k) {
            address t = address(toks[k]);
            if (launcherOf[t] == i + 1 && _curve(t).phase() == BondingCurve.Phase.Trading) return t;
        }
        return address(0);
    }

    function _actSweep(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 0, 0, false);
        address agent = _agentWith(i, P_SWEEP_TO_OWNER, seed);
        address t = _r(seed, 1) % 2 == 0 ? address(0) : _heldToken(i, seed);
        uint256 amt = t == address(0)
            ? _b(_r(seed, 2), 1, _min(_acct(i).balance, 100e18))
            : _b(_r(seed, 2), 1, IERC20(t).balanceOf(_acct(i)));
        (uint128 cost0, uint128 tok0, uint256 hw0) = accts[i].basis(t);
        uint256 bal0 = t == address(0) ? 0 : IERC20(t).balanceOf(_acct(i));
        Pre memory s = _pre(i, t);
        _sync(i);
        vm.prank(agent);
        accts[i].sweepToOwner(t, amt);
        _post(i, t, s, address(0));
        ++okCalls;
        if (t == address(0)) {
            assertEq(s.acctNative - _acct(i).balance, amt, "swept native");
            assertEq(owners[i].balance - s.ownerNative, amt, "native swept to the owner");
            ownerIn[i] += amt;
        } else {
            assertEq(s.acctTok - IERC20(t).balanceOf(_acct(i)), amt, "swept tokens");
            assertEq(IERC20(t).balanceOf(owners[i]) - s.ownerTok, amt, "tokens swept to the owner");
            assertEq(owners[i].balance, s.ownerNative);
            ownerTokIn[owners[i]][t] += amt;
            _checkCut(i, t, cost0, tok0, hw0, amt, bal0);
        }
        _charge(i, t, 0, 0);
    }

    /// @dev Mirrors the pro-rata basis cut of a withdrawal or sweep of `amt` out of `bal`.
    function _checkCut(uint256 i, address t, uint128 cost0, uint128 tok0, uint256 hw0, uint256 amt, uint256 bal)
        internal
        view
    {
        (uint128 cost1, uint128 tok1, uint256 hw1) = accts[i].basis(t);
        if (tok0 == 0) {
            assertEq(tok1, 0);
            return;
        }
        uint256 cut = Math.mulDiv(tok0, amt, bal, Math.Rounding.Ceil);
        if (cut >= tok0) {
            assertEq(tok1, 0, "cut closes");
            assertEq(cost1, 0);
            assertEq(hw1, 0);
        } else {
            assertEq(tok1, tok0 - cut, "cut tokens");
            assertEq(cost1, cost0 - Math.mulDiv(cost0, cut, tok0), "cut cost");
            assertEq(hw1, hw0);
        }
    }

    function _heldToken(uint256 i, uint256 seed) internal view returns (address) {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            address t = address(toks[(seed % n + k) % n]);
            if (IERC20(t).balanceOf(_acct(i)) != 0) return t;
        }
        return address(0);
    }

    // ------------------------------------------------------------------ owner actions

    /// @dev Snapshot around an owner call: the other account must not move, and value stays in the system.
    function _ownerPre(uint256 i) internal view returns (Pre memory s) {
        s.other = _digest(1 - i);
        s.sysNative = _sysNative(address(0));
    }

    function _ownerPost(uint256 i, Pre memory s) internal view {
        assertEq(_digest(1 - i), s.other, "an owner call on one account changed the other");
        assertEq(_sysNative(address(0)), s.sysNative, "owner call leaked value");
    }

    function _actWithdraw(uint256 seed) internal {
        uint256 i = seed % 2;
        _withdrawFor(i, seed);
    }

    function _withdrawFor(uint256 i, uint256 seed) internal {
        uint256 v = _r(seed, 1) % 8;
        Pre memory s = _ownerPre(i);
        if (v == 0) {
            // Everything out, then the owner funds the account again.
            address[] memory list = new address[](toks.length + 1);
            for (uint256 k; k < toks.length; ++k) {
                list[k + 1] = address(toks[k]);
            }
            uint256[] memory bals = new uint256[](list.length);
            bals[0] = _acct(i).balance;
            for (uint256 k = 1; k < list.length; ++k) {
                bals[k] = IERC20(list[k]).balanceOf(_acct(i));
            }
            uint256 own0 = owners[i].balance;
            vm.prank(owners[i]);
            accts[i].withdrawMany(list);
            ++okCalls;
            assertEq(_acct(i).balance, 0, "drained");
            assertEq(owners[i].balance - own0, bals[0]);
            ownerIn[i] += bals[0];
            for (uint256 k = 1; k < list.length; ++k) {
                assertEq(IERC20(list[k]).balanceOf(_acct(i)), 0);
                ownerTokIn[owners[i]][list[k]] += bals[k];
                (, uint128 tokens,) = accts[i].basis(list[k]);
                assertEq(tokens, 0, "withdrawMany clears the basis");
            }
            _ownerPost(i, s);
            _deposit(i, 50_000e18);
        } else if (v < 5) {
            _withdrawNative(i, seed);
            _ownerPost(i, s);
        } else {
            address t = _heldToken(i, seed);
            if (t == address(0)) {
                _withdrawNative(i, seed);
                _ownerPost(i, s);
                return;
            }
            uint256 bal = IERC20(t).balanceOf(_acct(i));
            uint256 amt = _b(_r(seed, 2), 1, bal);
            (uint128 cost0, uint128 tok0, uint256 hw0) = accts[i].basis(t);
            vm.prank(owners[i]);
            accts[i].withdraw(t, amt);
            ++okCalls;
            ownerTokIn[owners[i]][t] += amt;
            _checkCut(i, t, cost0, tok0, hw0, amt, bal);
            _ownerPost(i, s);
        }
    }

    function _withdrawNative(uint256 i, uint256 seed) internal {
        uint256 amt = _b(_r(seed, 2), 1, _acct(i).balance / 20);
        uint256 own0 = owners[i].balance;
        uint256 acct0 = _acct(i).balance;
        vm.prank(owners[i]);
        accts[i].withdraw(address(0), amt);
        ++okCalls;
        assertEq(owners[i].balance - own0, amt, "withdrawn to the owner");
        assertEq(acct0 - _acct(i).balance, amt);
        ownerIn[i] += amt;
    }

    function _deposit(uint256 i, uint256 amt) internal {
        vm.prank(owners[i]);
        (bool ok,) = _acct(i).call{value: amt}("");
        assertTrue(ok);
        ownerOut[i] += amt;
    }

    function _actTighten(uint256 i, uint256 seed) internal {
        Policy memory cur = _policy(i);
        Policy memory base = _base();
        Policy memory next = _policy(i); // a separate copy: `cur` must keep the old values
        uint256 f = _r(seed, 1) % 4;
        uint256[4] memory curV =
            [uint256(cur.maxTradeUsdc), cur.periodSpendCap, cur.perTokenPeriodCap, cur.periodSellCap];
        uint256[4] memory floorV = [
            uint256(base.maxTradeUsdc) / 3, base.periodSpendCap / 3, base.perTokenPeriodCap / 3, base.periodSellCap / 3
        ];
        uint64 v = uint64(curV[f] <= floorV[f] ? curV[f] : _b(_r(seed, 2), floorV[f], curV[f] - 1));
        if (f == 0) next.maxTradeUsdc = v;
        else if (f == 1) next.periodSpendCap = v;
        else if (f == 2) next.perTokenPeriodCap = v;
        else next.periodSellCap = v;
        Pre memory s = _ownerPre(i);
        vm.prank(owners[i]);
        assertEq(registry.setPolicy(_acct(i), next), 0, "a tightening is immediate");
        ++okCalls;
        assertEq(abi.encode(_policy(i)), abi.encode(next), "tightening applied");
        _ghostWrite(i, cur, next, true);
        _ownerPost(i, s);
        _sync(i);
    }

    /// @dev Records a policy write in the test-side ghost: one sequence number per write, stamped on every field whose
    ///      value changed (and, for a tightening, the value it was tightened to).
    function _ghostWrite(uint256 i, Policy memory from, Policy memory to, bool tightening) internal {
        uint256[11] memory a = AgentPolicyLib.words(from);
        uint256[11] memory b = AgentPolicyLib.words(to);
        bool any;
        for (uint256 f; f < 11; ++f) {
            if (a[f] != b[f]) any = true;
        }
        if (!any) return;
        uint256 sq = ++ghostSeq[i];
        for (uint256 f; f < 11; ++f) {
            if (a[f] == b[f]) continue;
            fieldSeq[i][f] = sq;
            if (tightening) {
                tightSeq[i][f] = sq;
                tightVal[i][f] = b[f];
            }
        }
    }

    function _killPending(uint256 i) internal {
        Pending[] storage list = pendingOf[i];
        for (uint256 k; k < list.length; ++k) {
            list[k].killed = true;
        }
    }

    /// @dev Queues a widening back to the base policy (tightening first when the policy is already the base).
    function _actQueueWiden(uint256 i, uint256 seed) internal returns (uint256 id) {
        if (keccak256(abi.encode(_policy(i))) == keccak256(abi.encode(_base()))) {
            _actTighten(i, seed);
            ++okCount[TIGHTEN];
        }
        Policy memory cur = _policy(i);
        Pre memory s = _ownerPre(i);
        vm.prank(owners[i]);
        id = registry.setPolicy(_acct(i), _base());
        assertGt(id, 0, "a widening is queued");
        ++okCalls;
        assertEq(abi.encode(_policy(i)), abi.encode(cur), "nothing loosens at queue time");
        lastQueueId[i] = id;
        pendingOf[i].push(Pending(id, ghostSeq[i], _now(), false, _base()));
        _ownerPost(i, s);
    }

    /// @dev Executes the oldest pending widening at (or after) its ETA and checks the merge against TEST-SIDE ghosts
    ///      only (no registry write stamp or epoch is read): a killed item (pause or ownership change since queueing)
    ///      applies nothing; otherwise each field written since queueing keeps its value, every field tightened since
    ///      queueing stays at or below that tightening, and every other field takes the target (Review Focus 2).
    function _actExecute(uint256 seed) internal {
        uint256 i = seed % 2;
        // The first EXECUTE of every run, and about one in sixteen after it, first lets a fresh widening lapse.
        if (queueExpiries == 0 || _r(seed, 7) % 16 == 0) _expireFresh(i, seed);
        _executeOldest(i, seed);
    }

    /// @dev Queues a fresh widening and warps one second past its expiry (ETA + QUEUE_TTL, about 8 days): anyone's
    ///      execution then reverts `QueuedExpired` and changes nothing. Every older live item has lapsed too, so the
    ///      execution that follows takes the expiry branch of `_executeOldest` for each of them.
    function _expireFresh(uint256 i, uint256 seed) internal {
        uint256 id = _actQueueWiden(i, seed);
        ++okCount[QUEUE_WIDEN];
        pendingOf[i].pop(); // the item just queued; it never applies
        (, uint40 eta,,,) = registry.queued(_acct(i), id);
        assertEq(eta, _now() + 1 hours, "eta is the delay after queueing");
        vm.warp(uint256(eta) + QUEUE_TTL + 1);
        vm.roll(vm.getBlockNumber() + 1);
        Pre memory s = _ownerPre(i);
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(stranger);
        vm.expectRevert(IAgentPolicyRegistry.QueuedExpired.selector);
        registry.executeQueued(_acct(i), id);
        _unchanged(d0, d1);
        ++refusedCalls;
        ++queueExpiries;
        _ownerPost(i, s);
    }

    function _executeOldest(uint256 i, uint256 seed) internal {
        if (pendingOf[i].length == 0) {
            _actQueueWiden(i, seed);
            ++okCount[QUEUE_WIDEN];
        }
        Pending memory q = pendingOf[i][0];
        _dropPending(i, 0);
        address a = _acct(i);
        Policy memory cur = _policy(i);
        Pre memory s = _ownerPre(i);
        uint256 eta = q.queuedAt + 1 hours; // the delay never changes in this suite
        if (q.killed) {
            if (_now() < eta) {
                vm.warp(eta);
                vm.roll(vm.getBlockNumber() + 1);
                s = _ownerPre(i);
            }
            vm.prank(stranger);
            registry.executeQueued(a, q.id);
            ++okCalls;
            assertEq(abi.encode(_policy(i)), abi.encode(cur), "a killed item applies nothing");
            ++cancelledExecutions;
            _ownerPost(i, s);
            return;
        }
        if (_now() > eta + QUEUE_TTL) {
            vm.prank(stranger);
            vm.expectRevert(IAgentPolicyRegistry.QueuedExpired.selector);
            registry.executeQueued(a, q.id);
            ++refusedCalls;
            ++queueExpiries;
            _ownerPost(i, s);
            _executeOldest(i, seed);
            return;
        }
        if (_now() < eta) {
            vm.warp(eta);
            vm.roll(vm.getBlockNumber() + 1);
        }
        cur = _policy(i);
        uint256[11] memory c = AgentPolicyLib.words(cur);
        uint256[11] memory t = AgentPolicyLib.words(q.target);
        for (uint256 f; f < 11; ++f) {
            if (fieldSeq[i][f] <= q.seq) c[f] = t[f];
        }
        s = _ownerPre(i);
        vm.prank(stranger);
        registry.executeQueued(a, q.id);
        ++okCalls;
        Policy memory after_ = _policy(i);
        uint256[11] memory n = AgentPolicyLib.words(after_);
        assertEq(abi.encode(n), abi.encode(c), "merge keeps every write made since queueing");
        for (uint256 f; f < 11; ++f) {
            if (tightSeq[i][f] > q.seq) {
                if (f == 8 || f == 10) assertGe(n[f], tightVal[i][f], "a later tightening survives");
                else assertLe(n[f], tightVal[i][f], "a later tightening survives");
            }
        }
        assertGe(_now(), eta, "never before the ETA");
        _ghostWrite(i, cur, after_, false);
        _ownerPost(i, s);
        _sync(i);
    }

    function _dropPending(uint256 i, uint256 k) internal {
        Pending[] storage list = pendingOf[i];
        for (uint256 m = k; m + 1 < list.length; ++m) {
            list[m] = list[m + 1];
        }
        list.pop();
    }

    /// @dev The owner hands the account to a fresh address after the delay. The handover kills every queued item of
    ///      the previous owner; the owner ghosts move to the new owner and the old one joins the watched outsiders.
    function _actTransferOwner(uint256 seed) internal {
        uint256 i = seed % 2;
        address old = owners[i];
        address heir = makeAddr(string.concat("heir ", vm.toString(++nonce)));
        vm.deal(heir, 10_000_000e18);
        Pre memory s = _ownerPre(i);
        vm.prank(old);
        uint256 id = registry.transferOwnership(_acct(i), heir);
        ++okCalls;
        lastQueueId[i] = id;
        _ownerPost(i, s);
        // Not before the delay (checked on half the transfers).
        if (_r(seed, 1) % 2 == 0) {
            vm.prank(heir);
            vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, uint40(_now() + 1 hours)));
            registry.acceptOwnership(_acct(i), id);
            ++refusedCalls;
        }
        vm.warp(_now() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        s = _ownerPre(i);
        vm.prank(heir);
        registry.acceptOwnership(_acct(i), id);
        ++okCalls;
        _ownerPost(i, s);
        assertEq(registry.owner(_acct(i)), heir);
        _killPending(i);
        // Freeze the old owner's tally: it must still match, then it becomes an outsider.
        assertEq(old.balance + ownerOut[i], ownerStart[i] + ownerIn[i], "old owner native");
        // The old owner holds exactly the tokens withdrawn or swept to it, nothing the handover moved.
        for (uint256 k; k < toks.length; ++k) {
            address t = address(toks[k]);
            assertEq(IERC20(t).balanceOf(old), ownerTokIn[old][t], "old owner tokens");
        }
        // The heir starts with no tokens, so its tally starts at zero.
        for (uint256 k; k < toks.length; ++k) {
            assertEq(IERC20(address(toks[k])).balanceOf(heir), 0, "heir starts empty");
        }
        owners[i] = heir;
        ownerStart[i] = heir.balance;
        ownerIn[i] = 0;
        ownerOut[i] = 0;
        watchList.push(old);
        // The old owner can no longer withdraw (checked on the transfers that skipped the early accept).
        if (_r(seed, 1) % 2 == 1) {
            vm.prank(old);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            accts[i].withdraw(address(0), 1);
            ++refusedCalls;
        }
        ++ownershipTransfers;
    }

    /// @dev Revokes a key (immediately) and queues its replacement, which activates only once executed after the
    ///      delay.
    function _actRotate(uint256 i, uint256 seed) internal {
        address[] storage list = agentsOf[i];
        uint256 n = list.length;
        address old;
        uint256 idx;
        for (uint256 k; k < n; ++k) {
            idx = (seed % n + k) % n;
            if (list[idx] != expiring[i]) {
                old = list[idx];
                break;
            }
        }
        uint16 perms = registry.agent(_acct(i), old).permissions;
        address fresh = makeAddr(string.concat("rotated agent ", vm.toString(++nonce)));
        Pre memory s = _ownerPre(i);
        vm.prank(owners[i]);
        uint256 id = registry.rotateAgent(_acct(i), old, fresh, uint40(_now() + 170 days), perms);
        ++okCalls;
        lastQueueId[i] = id;
        assertFalse(registry.agent(_acct(i), old).active, "revocation is immediate");
        assertTrue(registry.retired(_acct(i), old));
        assertFalse(registry.agent(_acct(i), fresh).active, "the replacement waits for the delay");
        list[idx] = list[n - 1];
        list.pop();
        isCurrentAgent[i][old] = false;
        revokedOf[i].push(old);
        _ownerPost(i, s);
        watchList.push(fresh);

        // Spec 5.5: a queued key can do nothing before its addition executes, even once the ETA has passed.
        // Before the ETA or after it (but before execution), by seed: either way it is not an agent yet.
        bool afterEta = _r(seed, 7) % 2 == 0;
        (, uint40 eta,,,) = registry.queued(_acct(i), id);
        if (afterEta) {
            vm.warp(eta);
            vm.roll(vm.getBlockNumber() + 1);
        }
        _try(fresh, i, _r(seed, 8) % 6, abi.encodeWithSelector(IAgentPolicyRegistry.NotAgent.selector));
        ++notYetActiveRefusals;
        if (!afterEta) {
            vm.warp(eta);
            vm.roll(vm.getBlockNumber() + 1);
        }
        s = _ownerPre(i);
        vm.prank(stranger);
        registry.executeQueued(_acct(i), id);
        ++okCalls;
        assertTrue(registry.agent(_acct(i), fresh).active);
        agentsOf[i].push(fresh);
        isCurrentAgent[i][fresh] = true;
        _ownerPost(i, s);
    }

    /// @dev Only agents the run activated through the creation or a matured queued item are active.
    function _assertAgentsAreKnown(uint256 i) internal view {
        for (uint256 k; k < watchList.length; ++k) {
            address x = watchList[k];
            if (registry.agent(_acct(i), x).active) assertTrue(isCurrentAgent[i][x], "an unknown agent is active");
        }
    }

    /// @dev Bob trades, time and blocks pass, and strangers donate.
    function _actMarket(uint256 seed) internal {
        vm.deal(bob, 1_000_000e18);
        uint256 v = _r(seed, 1) % 4;
        if (v == 0) {
            (, BondingCurve c) = _tradingToken(_r(seed, 2), 3_000e18);
            vm.prank(bob);
            c.buy{value: _b(_r(seed, 3), 1e18, 3_000e18)}(0, address(0), type(uint256).max);
        } else if (v == 1) {
            (LaunchToken t, BondingCurve c) = _tradingToken(_r(seed, 2), 0);
            uint256 amt = t.balanceOf(bob) * _b(_r(seed, 3), 1, 50) / 100;
            (uint256 q, uint256 fee) = c.quoteSell(amt);
            if (amt != 0 && q + fee != 0) {
                vm.startPrank(bob);
                t.approve(address(c), amt);
                c.sell(amt, 0, address(0), type(uint256).max);
                vm.stopPrank();
            }
        } else if (v == 2) {
            vm.prank(bob);
            (bool ok,) = _acct(_r(seed, 2) % 2).call{value: _b(_r(seed, 3), 1, 10e18)}("");
            assertTrue(ok);
        }
        vm.warp(_now() + _b(_r(seed, 4), 0, 2 hours));
        vm.roll(vm.getBlockNumber() + _b(_r(seed, 5), 0, 300));
    }

    // ------------------------------------------------------------------ negative actions (expected reverts)

    function _snap() internal view returns (bytes32, bytes32) {
        return (_digest(0), _digest(1));
    }

    function _unchanged(bytes32 d0, bytes32 d1) internal view {
        assertEq(_digest(0), d0, "a refused call changed account 0");
        assertEq(_digest(1), d1, "a refused call changed account 1");
    }

    /// @dev `caller` tries `fn` (0 buy, 1 sell, 2 pool swap, 3 launch, 4 claim, 5 sweep) on account `i`.
    function _try(address caller, uint256 i, uint256 fn, bytes memory err) internal {
        (LaunchToken lt,) = _tradingToken(fn, 0);
        address t = address(lt);
        uint256 dl = _dl();
        LaunchRequest memory r;
        r.name = "X";
        r.symbol = "X";
        r.salt = bytes32(++nonce);
        r.expectedConfigHash = factory.configHash();
        r.deadline = dl;
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(caller);
        vm.expectRevert(err);
        if (fn == 0) accts[i].buy(t, 1e6, 1, dl);
        else if (fn == 1) accts[i].sell(t, 1e18, 1, dl);
        else if (fn == 2) accts[i].swapExactIn(t, true, 1e6, 1, dl);
        else if (fn == 3) accts[i].launch(r);
        else if (fn == 4) accts[i].claimFees();
        else accts[i].sweepToOwner(address(0), 1);
        _unchanged(d0, d1);
        ++refusedCalls;
    }

    function _negStranger(uint256 seed) internal {
        uint256 i = seed % 2;
        uint256 v = _r(seed, 1) % 8;
        if (v < 6) {
            _try(stranger, i, v, abi.encodeWithSelector(IAgentPolicyRegistry.NotAgent.selector));
            return;
        }
        (bytes32 d0, bytes32 d1) = _snap();
        if (v == 6) {
            vm.prank(stranger);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            accts[i].withdraw(address(0), 1);
            ++refusedCalls;
        } else {
            Policy memory p = _base();
            vm.prank(stranger);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.setPolicy(_acct(i), p);
            ++refusedCalls;
        }
        _unchanged(d0, d1);
    }

    function _negOwnerTrade(uint256 seed) internal {
        uint256 i = seed % 2;
        _try(owners[i], i, _r(seed, 1) % 6, abi.encodeWithSelector(IAgentPolicyRegistry.NotAgent.selector));
    }

    function _negRevoked(uint256 seed) internal {
        uint256 i = seed % 2;
        if (revokedOf[i].length == 0) {
            _actRotate(i, seed);
            ++okCount[ROTATE];
        }
        address old = revokedOf[i][seed % revokedOf[i].length];
        _try(old, i, _r(seed, 1) % 6, abi.encodeWithSelector(IAgentPolicyRegistry.NotAgent.selector));
    }

    function _negExpired(uint256 seed) internal {
        uint256 i = seed % 2;
        Agent memory a = registry.agent(_acct(i), expiring[i]);
        if (_now() < a.expiresAt) {
            vm.warp(a.expiresAt);
            vm.roll(vm.getBlockNumber() + 1);
        }
        _try(expiring[i], i, _r(seed, 1) % 6, abi.encodeWithSelector(IAgentPolicyRegistry.AgentExpired.selector));
    }

    function _negOwnerPaused(uint256 seed) internal {
        uint256 i = seed % 2;
        vm.prank(owners[i]);
        registry.pauseAgents(_acct(i), true);
        ++okCalls;
        _killPending(i);
        // The pause check comes first, so every agent action of every key is refused. Three of the six actions per
        // pause, rotating, so two pauses cover all six (and `pausedFnsTried` shows each was tried).
        address agent = _agentWith(i, P_BUY, seed);
        for (uint256 k; k < 3; ++k) {
            uint256 fn = pausedFnCursor++ % 6;
            _try(agent, i, fn, abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector));
            ++pausedFnsTried[fn];
        }
        _ownerExit(i, seed);
        vm.prank(owners[i]);
        registry.pauseAgents(_acct(i), false);
        ++okCalls;
    }

    /// @dev Owner exits and narrowing still work while agents are paused.
    function _ownerExit(uint256 i, uint256 seed) internal {
        Pre memory s = _ownerPre(i);
        _withdrawNative(i, seed);
        _ownerPost(i, s);
        Policy memory p = _policy(i);
        vm.prank(owners[i]);
        assertEq(registry.setPolicy(_acct(i), p), 0, "narrowing works while paused");
        ++okCalls;
        ++ownerExitsDuringPause;
    }

    function _negFactoryPaused(uint256 seed) internal {
        if (_now() < guardianReadyAt || agentFactory.isPaused()) {
            _negOwnerPaused(seed);
            return;
        }
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        guardianReadyAt = _now() + 144 hours;
        for (uint256 i; i < 2; ++i) {
            _try(
                _agentWith(i, P_BUY, seed),
                i,
                _r(seed, i) % 6,
                abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector)
            );
            _ownerExit(i, _r(seed, 10 + i));
        }
        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(uint40(_now()));
        assertFalse(agentFactory.isPaused());
    }

    function _negEarly(uint256 seed) internal {
        uint256 i = seed % 2;
        uint256 id = _actQueueWiden(i, seed);
        uint40 eta = uint40(_now() + 1 hours);
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, eta));
        registry.executeQueued(_acct(i), id);
        _unchanged(d0, d1);
        ++refusedCalls;
    }

    function _negCross(uint256 seed) internal {
        uint256 i = seed % 2;
        address other = _agentWith(1 - i, P_BUY, seed);
        _try(other, i, _r(seed, 1) % 6, abi.encodeWithSelector(IAgentPolicyRegistry.NotAgent.selector));
    }

    function _negOverCap(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 0, 0, false);
        (LaunchToken t,) = _tradingToken(_r(seed, 1), 0);
        uint256 maxT = _policy(i).maxTradeUsdc;
        address agent = _agentWith(i, P_BUY, seed);
        uint256 dl = _dl();
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, maxT));
        accts[i].buy(address(t), maxT + 1, 1, dl);
        _unchanged(d0, d1);
        ++refusedCalls;
    }

    // ------------------------------------------------------------------ over-cap refusals (spec 5.2)
    //
    // Each runs inside a snapshot: the owner narrows one cap so the headroom is exactly h, the agent asks for h + 1
    // (or a native cost of h * 1e12 + r wei), the call must revert with that cap's error carrying h, nothing may
    // change, and the snapshot then restores the run.

    function _narrowTo(uint256 i, Policy memory p) internal {
        vm.prank(owners[i]);
        assertEq(registry.setPolicy(_acct(i), p), 0, "narrowing is immediate");
    }

    function _negSpendCap(uint256 seed, bool perToken) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 5e6, 0, false);
        uint256 snap = vm.snapshotState();
        (LaunchToken lt, BondingCurve c) = _tradingToken(_r(seed, 1), 200e18);
        Policy memory p = _policy(i);
        if (_tokenLeft(i, address(lt)) < 5e6) {
            (lt, c) = _newToken(seed);
            _passSnipe(c);
        }
        address t = address(lt);
        uint256 room = _min(_min(p.maxTradeUsdc, _spendLeft(i)), _tokenLeft(i, t));
        uint256 h;
        uint256 usdcIn;
        bool odd = _r(seed, 2) % 2 == 0;
        if (odd) {
            // A graduating buy whose native cost is h * 1e12 + r wei, r in (0, 1e12).
            uint256 leave = _b(_r(seed, 3), 1e18, (room - 1) * 1e12 * 8 / 10) + _r(seed, 4) % 1e12 + 1;
            (, uint256 full,,) = c.quoteBuy(1e30);
            if (full > leave) {
                vm.deal(bob, 1_000_000e18);
                vm.prank(bob);
                c.buy{value: full - leave}(0, address(0), type(uint256).max);
            }
            (uint256 q, uint256 used,,) = c.quoteBuy(room * 1e12);
            assertEq(q, c.curveSupply() - c.sold(), "final buy");
            odd = used % 1e12 != 0;
            h = used / 1e12;
            usdcIn = room;
        }
        if (!odd) {
            h = _b(_r(seed, 5), 1, room - 1);
            usdcIn = h + 1;
        }
        bytes memory err;
        if (perToken) {
            p.perTokenPeriodCap = uint64(registry.tokenSpent(_acct(i), t) + h);
            err = abi.encodeWithSelector(IAgentPolicyRegistry.TokenCapExceeded.selector, h);
        } else {
            (, uint64 spent,,,) = registry.usage(_acct(i));
            p.periodSpendCap = uint64(spent + h);
            err = abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, h);
        }
        _narrowTo(i, p);
        address agent = _agentWith(i, P_BUY, seed);
        uint256 dl = _dl();
        (bytes32 d0, bytes32 d1) = _snap();
        uint256 bal = _acct(i).balance;
        vm.prank(agent);
        vm.expectRevert(err);
        accts[i].buy(t, usdcIn, 1, dl);
        _unchanged(d0, d1);
        assertEq(_acct(i).balance, bal);
        vm.revertToState(snap);
        ++refusedCalls;
        if (odd) ++oddWeiSpendRefusals;
    }

    function _negSellCap(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 25e6, 25e6, false);
        uint256 snap = vm.snapshotState();
        (LaunchToken lt, BondingCurve c) = _newToken(seed);
        _passSnipe(c);
        address t = address(lt);
        _agentBuy(i, _agentWith(i, P_BUY, seed), t, 20e6);
        (, uint128 held,) = accts[i].basis(t);
        uint256 tokensIn = _b(_r(seed, 1), held / 4, held / 2);
        uint256 value = _recV(_acct(i), t, tokensIn);
        Policy memory p = _policy(i);
        (,, uint64 sold,,) = registry.usage(_acct(i));
        p.periodSellCap = uint64(sold + value - 1);
        _narrowTo(i, p);
        address agent = _agentWith(i, P_SELL, seed);
        uint256 dl = _dl();
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, value - 1));
        accts[i].sell(t, tokensIn, 1, dl);
        _unchanged(d0, d1);
        vm.revertToState(snap);
        ++refusedCalls;
    }

    function _negActionLimit(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 2e6, 0, false);
        uint256 snap = vm.snapshotState();
        (LaunchToken t,) = _tradingToken(_r(seed, 1), 200e18);
        Policy memory p = _policy(i);
        (,,, uint32 actions,) = registry.usage(_acct(i));
        p.maxActionsPerPeriod = actions;
        _narrowTo(i, p);
        address agent = _agentWith(i, P_BUY, seed);
        uint256 dl = _dl();
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(agent);
        vm.expectRevert(IAgentPolicyRegistry.ActionLimit.selector);
        accts[i].buy(address(t), 1e6, 1, dl);
        _unchanged(d0, d1);
        vm.revertToState(snap);
        ++refusedCalls;
    }

    function _negLaunchLimit(uint256 seed) internal {
        uint256 i = seed % 2;
        _ensureRoom(i, 2e6, 0, false);
        uint256 snap = vm.snapshotState();
        Policy memory p = _policy(i);
        (,,,, uint16 launches) = registry.usage(_acct(i));
        p.launchesPerPeriod = launches;
        _narrowTo(i, p);
        LaunchRequest memory r;
        r.name = "Over";
        r.symbol = "OVR";
        r.salt = bytes32(++nonce);
        r.expectedConfigHash = factory.configHash();
        r.deadline = _dl();
        address agent = _agentWith(i, P_LAUNCH, seed);
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(agent);
        vm.expectRevert(IAgentPolicyRegistry.LaunchLimit.selector);
        accts[i].launch(r);
        _unchanged(d0, d1);
        vm.revertToState(snap);
        ++refusedCalls;
    }

    /// @dev Spec 5.6: a write above a beta ceiling, in any limited field, is refused.
    function _negCeiling(uint256 seed) internal {
        uint256 i = seed % 2;
        uint8[9] memory fields = [0, 1, 2, 3, 4, 5, 6, 7, 9];
        uint8 f = fields[_r(seed, 1) % 9];
        uint256[11] memory w = AgentPolicyLib.words(_policy(i));
        w[f] = AgentPolicyLib.words(agentFactory.ceilings())[f] + 1;
        Policy memory p = abi.decode(abi.encode(w), (Policy));
        (bytes32 d0, bytes32 d1) = _snap();
        vm.prank(owners[i]);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.BetaCeiling.selector, f));
        registry.setPolicy(_acct(i), p);
        _unchanged(d0, d1);
        ++refusedCalls;
    }

    // ------------------------------------------------------------------ invariants

    /// @dev Spec 5.1: the owners received exactly what was withdrawn or swept to them (net of their deposits).
    function invariant_OwnersReceiveExactlyWithdrawalsAndSweeps() public view {
        for (uint256 i; i < 2; ++i) {
            assertEq(owners[i].balance + ownerOut[i], ownerStart[i] + ownerIn[i], "owner native");
            for (uint256 k; k < toks.length; ++k) {
                address t = address(toks[k]);
                assertEq(IERC20(t).balanceOf(owners[i]), ownerTokIn[owners[i]][t], "owner tokens");
            }
        }
    }

    /// @dev Spec 5.2 and 5.8: this period's totals across all agents equal the registry's and stay within the
    ///      highest cap in force during the period.
    function invariant_PeriodCapsAcrossAllAgents() public view {
        for (uint256 i; i < 2; ++i) {
            Ghost memory g = ghost[i];
            if (g.period != _pid()) continue;
            (, uint64 spent, uint64 sold,,) = registry.usage(_acct(i));
            assertEq(spent, g.spent, "spend");
            assertEq(sold, g.sold, "sells");
            assertLe(g.spent, g.maxSpendCap, "spend cap");
            assertLe(g.sold, g.maxSellCap, "sell cap");
            for (uint256 k; k < toks.length; ++k) {
                address t = address(toks[k]);
                assertLe(ghostTokSpent[i][g.period][t], g.maxTokenCap, "token cap");
                assertEq(registry.tokenSpent(_acct(i), t), ghostTokSpent[i][g.period][t], "token spend");
            }
        }
    }

    /// @dev Spec 5.3: no ERC-20 or Permit2 allowance from either account survives.
    function invariant_NoAllowanceSurvives() public view {
        for (uint256 i; i < 2; ++i) {
            address a = _acct(i);
            for (uint256 k; k <= toks.length; ++k) {
                address t = k == toks.length ? USDC : address(toks[k]);
                if (t != USDC) assertEq(IERC20(t).allowance(a, address(_curve(t))), 0, "to the curve");
                assertEq(IERC20(t).allowance(a, address(permit2)), 0, "to Permit2");
                assertEq(IERC20(t).allowance(a, address(router)), 0, "to the router");
                assertEq(IERC20(t).allowance(a, address(poolManager)), 0, "to the PoolManager");
                (uint160 amount,,) = permit2.allowance(a, t, address(router));
                assertEq(amount, 0, "Permit2 to the router");
            }
        }
    }

    /// @dev Spec 5.4: referrers never change and every launched token's creator is its account.
    function invariant_ReferrerFixedAndCreatorIsTheAccount() public view {
        for (uint256 i; i < 2; ++i) {
            assertEq(accts[i].referrer(), referrer);
            assertEq(feeManager.referrerOf(_acct(i)), referrer);
            assertEq(registry.owner(_acct(i)), owners[i]);
        }
        for (uint256 k; k < toks.length; ++k) {
            address t = address(toks[k]);
            if (launcherOf[t] != 0) assertEq(feeManagerCreator(t), _acct(launcherOf[t] - 1), "creator");
        }
    }

    /// @dev Spec 5.6: every stored policy is within the factory's ceilings.
    function invariant_PolicyWithinCeilings() public view {
        uint256[11] memory c = AgentPolicyLib.words(agentFactory.ceilings());
        for (uint256 i; i < 2; ++i) {
            uint256[11] memory p = AgentPolicyLib.words(_policy(i));
            for (uint256 f; f < 10; ++f) {
                if (f == 8) assertGe(p[f], c[f], "minTokenAgeBlocks floor");
                else assertLe(p[f], c[f], "ceiling");
            }
        }
    }

    /// @dev Spec 5.7.
    function invariant_SignatureNeverValid() public view {
        for (uint256 i; i < 2; ++i) {
            bytes32 h = keccak256(abi.encode(steps, i));
            assertTrue(accts[i].isValidSignature(h, abi.encode(h, owners[i])) != ERC1271_MAGIC);
            assertTrue(accts[i].isValidSignature(h, "") != ERC1271_MAGIC);
        }
    }

    /// @dev The run is evidence only if most calls did something: more than 60% of steps succeeded and every
    ///      kind, positive and negative, happened at least once. Set AGENT_INVARIANT_STATS=true to append the
    ///      per-run counts to test-export/agent-invariant-stats.csv.
    function afterInvariant() public {
        assertGt(steps, 0, "steps");
        assertGt(stepSuccesses * 100, steps * 60, "successful-step ratio above 60%");
        assertGt(okCalls * 100, (okCalls + refusedCalls) * 60, "successful account-call ratio above 60%");
        for (uint256 k; k < KINDS; ++k) {
            assertGt(okCount[k], 0, string.concat("kind never reached: ", vm.toString(k)));
        }
        assertGt(queueExpiries, 0, "queue expiry never reached");
        if (vm.envOr("AGENT_INVARIANT_STATS", false)) {
            string memory line = string.concat(
                vm.toString(steps),
                ",",
                vm.toString(stepSuccesses),
                ",",
                vm.toString(stepExpectedReverts),
                ",",
                vm.toString(graduatingBuys),
                ",",
                vm.toString(cancelledExecutions),
                ",",
                vm.toString(giftedPoolSells),
                ",",
                vm.toString(queueExpiries),
                ",",
                vm.toString(ownerExitsDuringPause),
                ",",
                vm.toString(notYetActiveRefusals),
                ",",
                vm.toString(okCalls),
                ",",
                vm.toString(refusedCalls),
                ",",
                vm.toString(ownershipTransfers),
                ",",
                vm.toString(oddWeiSpendRefusals)
            );
            for (uint256 k; k < KINDS; ++k) {
                line = string.concat(line, ",", vm.toString(okCount[k]));
            }
            vm.writeLine("test-export/agent-invariant-stats.csv", line);
        }
    }
}
