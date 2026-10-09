// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {CreateParams} from "@mercuri/launch/libraries/LaunchTypes.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/agents/interfaces/IAgentPolicyRegistry.sol";
import {AgentPolicyLib} from "../../src/agents/AgentPolicyLib.sol";
import {Policy, InitParams, P_ALL, P_BUY, QUEUE_TTL} from "../../src/agents/AgentTypes.sol";

/// @dev A token a stranger sends to an account. Every transfer out of the account tries to re-enter it.
contract ReentrantToken is ERC20 {
    AgentAccount public target;
    uint256 public attempts;
    uint256 public blocked;
    bytes4[3] public errors;

    constructor() ERC20("Evil", "EVIL") {
        _mint(msg.sender, 1e24);
    }

    function arm(AgentAccount target_) external {
        target = target_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) == address(0) || from != address(target)) return;
        bytes[3] memory calls = [
            abi.encodeCall(AgentAccount.withdraw, (address(0), 1)),
            abi.encodeCall(AgentAccount.sweepToOwner, (address(0), 1)),
            abi.encodeCall(AgentAccount.buy, (address(this), 1, 1, block.timestamp))
        ];
        for (uint256 k; k < 3; ++k) {
            ++attempts;
            (bool ok, bytes memory err) = address(target).call(calls[k]);
            if (!ok) {
                ++blocked;
                errors[k] = bytes4(err);
            }
        }
    }
}

/// @dev Task 6: one test per attack scenario of spec section 10, plus the five Review Focus items.
contract AgentAttacksTest is AgentFixture {
    AgentAccount internal account;
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        account = _account();
        vm.deal(address(account), 100_000e18);
        vm.deal(attacker, 1_000_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _dl() internal view returns (uint256) {
        return _now() + 60;
    }

    function _withPolicy(Policy memory p) internal returns (AgentAccount a) {
        InitParams memory ip = _defaults();
        ip.policy = p;
        a = _account(accountOwner, keccak256(abi.encode(p)), ip);
        vm.deal(address(a), 100_000e18);
    }

    /// @dev `n` tokens launched by the attacker (creator: the attacker), past their snipe windows.
    function _attackerTokens(uint256 n) internal returns (address[] memory list) {
        list = new address[](n);
        bytes32 pinned = factory.configHash();
        for (uint256 k; k < n; ++k) {
            CreateParams memory p =
                CreateParams("Bait", "BAIT", "https://example.invalid/b.json", attacker, address(0), bytes32(k));
            vm.prank(attacker);
            (list[k],) = factory.createToken{value: cfg.launchFee}(p, pinned, 0);
        }
        vm.roll(vm.getBlockNumber() + cfg.snipeBlocks);
    }

    function _buy(AgentAccount a, address t, uint256 usdcIn) internal returns (uint256) {
        uint256 dl = _dl();
        vm.prank(agentKey);
        return a.buy(t, usdcIn, 1, dl);
    }

    function _sell(AgentAccount a, address t, uint256 tokensIn) internal returns (uint256) {
        uint256 dl = _dl();
        vm.prank(agentKey);
        return a.sell(t, tokensIn, 1, dl);
    }

    function _expectBuyRevert(AgentAccount a, address t, uint256 usdcIn, bytes memory err) internal {
        uint256 dl = _dl();
        vm.prank(agentKey);
        vm.expectRevert(err);
        a.buy(t, usdcIn, 1, dl);
    }

    function _usage(AgentAccount a) internal view returns (uint64 spent, uint64 sold, uint32 actions) {
        (, spent, sold, actions,) = registry.usage(address(a));
    }

    function _recV(AgentAccount a, address t, uint256 rec) internal view returns (uint256) {
        (uint128 cost, uint128 tokens, uint256 hw) = a.basis(t);
        if (rec == 0 || tokens == 0) return 0;
        uint256 v = Math.mulDiv(rec, cost, tokens, Math.Rounding.Ceil);
        uint256 h = Math.mulDiv(rec, hw, 1e36);
        return h > v ? h : v;
    }

    function _setPolicy(Policy memory p) internal returns (uint256 id) {
        vm.prank(accountOwner);
        id = registry.setPolicy(address(account), p);
    }

    function _eta(uint256 id) internal view returns (uint40 eta) {
        (, eta,,,) = registry.queued(address(account), id);
    }

    function _fillCurveLeaving(BondingCurve c, uint256 leftWei) internal {
        (, uint256 full,,) = c.quoteBuy(1e30);
        vm.prank(bob);
        c.buy{value: full - leftWei}(0, address(0), type(uint256).max);
        require(c.phase() == BondingCurve.Phase.Trading, "still trading");
    }

    // ---------------------------------------------------------------- spec 10: stolen key against caps

    /// @dev A stolen key buys the attacker's own tokens. Per token it stops at `perTokenPeriodCap`; across tokens at
    ///      `periodSpendCap`. The fixed window allows one more cap right after the boundary (spec 4.5 loss bound).
    function test_StolenKeyBuysAttackerTokensUntilTheCaps() public {
        address[] memory bait = _attackerTokens(10);
        uint256 bal0 = address(account).balance;
        // Late in a period.
        vm.warp((_now() / 1 days + 1) * 1 days - 10);
        _buy(account, bait[0], 100e6);
        _expectBuyRevert(account, bait[0], 1, abi.encodeWithSelector(IAgentPolicyRegistry.TokenCapExceeded.selector, 0));
        for (uint256 k = 1; k < 5; ++k) {
            _buy(account, bait[k], 100e6);
        }
        _expectBuyRevert(
            account, bait[5], 1, abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 0)
        );
        assertEq(bal0 - address(account).balance, 500e18, "loss this period is exactly the spend cap");

        // Ten seconds later a new period opens: one more cap, then nothing.
        vm.warp(_now() + 10);
        for (uint256 k = 5; k < 10; ++k) {
            _buy(account, bait[k], 100e6);
        }
        _expectBuyRevert(
            account, bait[0], 1, abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 0)
        );
        assertEq(bal0 - address(account).balance, 1_000e18, "two caps across the boundary, no more");
        (uint64 spent,,) = _usage(account);
        assertEq(spent, 500e6);
    }

    /// @dev The attacker (Bob) crashes a token the account holds, then a stolen key dumps the holdings into it. Sells
    ///      are valued at cost, so the sell cap bounds the share of holdings dumped per period, not the proceeds.
    function test_StolenKeyCrashesPriceThenSellCapBindsAtCost() public {
        Policy memory p = _defaultPolicy();
        p.perTokenPeriodCap = 500e6;
        p.periodSellCap = 150e6;
        p.maxPriceImpactBps = 2_000;
        AgentAccount a = _withPolicy(p);
        (LaunchToken t, BondingCurve c) = _create(bytes32("crash"));
        vm.prank(bob);
        c.buy{value: 8_000e18}(0, address(0), type(uint256).max);
        for (uint256 k; k < 5; ++k) {
            _buy(a, address(t), 100e6);
        }
        uint256 held = t.balanceOf(address(a));
        (uint128 cost,,) = a.basis(address(t));
        assertEq(cost, 500e6);
        uint256 priceBefore = c.price();
        // Bob dumps everything: the price falls by more than half.
        uint256 bobHeld = t.balanceOf(bob);
        vm.startPrank(bob);
        t.approve(address(c), bobHeld);
        c.sell(bobHeld, 0, address(0), type(uint256).max);
        vm.stopPrank();
        assertLt(c.price() * 2, priceBefore, "crashed");

        // The whole position is valued at cost (500), above maxTradeUsdc.
        uint256 dl = _dl();
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 100e6));
        a.sell(address(t), held, 1, dl);

        // Dump in chunks valued at 50 at cost: three fit the 150 cap, the fourth does not.
        uint256 chunk = held / 10;
        uint256 proceeds;
        uint256 sold;
        for (uint256 k; k < 3; ++k) {
            proceeds += _sell(a, address(t), chunk);
            sold += chunk;
        }
        (, uint64 soldValue,) = _usage(a);
        assertLe(soldValue, 150e6);
        assertGe(soldValue, 150e6 - 3, "charged at cost, not at the crashed proceeds");
        assertLt(proceeds, soldValue, "proceeds are below the cost charged");
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, 150e6 - soldValue));
        a.sell(address(t), chunk, 1, dl);
        assertEq(t.balanceOf(address(a)), held - sold);
        assertGe(t.balanceOf(address(a)) * 10, held * 7, "at least 70% of the holdings survive the period");
    }

    /// @dev Selling (and claiming) returns USDC to the account but never spend headroom.
    function test_ProceedsRecyclingCreatesNoSpendHeadroom() public {
        Policy memory p = _defaultPolicy();
        p.perTokenPeriodCap = 500e6;
        p.maxPriceImpactBps = 2_000;
        AgentAccount a = _withPolicy(p);
        (LaunchToken t,) = _create(bytes32("recycle"));
        for (uint256 k; k < 5; ++k) {
            _buy(a, address(t), 100e6);
        }
        (uint64 spendLeft,,,) = registry.headroom(address(a));
        assertEq(spendLeft, 0);
        uint256 bal = address(a).balance;
        uint256 held = t.balanceOf(address(a));
        // Chunks below maxTradeUsdc at cost (the remaining average creeps up as each cut rounds down).
        for (uint256 k; k < 4; ++k) {
            _sell(a, address(t), held / 6);
        }
        assertGt(address(a).balance - bal, 250e18, "proceeds came back");
        (spendLeft,,,) = registry.headroom(address(a));
        assertEq(spendLeft, 0, "no headroom from proceeds");
        _expectBuyRevert(a, address(t), 1, abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 0));
        (uint64 spent,,) = _usage(a);
        assertEq(spent, 500e6);
    }

    // ---------------------------------------------------------------- spec 10: the queue (Review Focus 2)

    function test_OldQueuedWideningNeverUndoesALaterTightening() public {
        Policy memory wide = _defaultPolicy();
        wide.maxTradeUsdc = 200e6;
        wide.periodSpendCap = 1_000e6;
        uint256 id = _setPolicy(wide);
        assertGt(id, 0);
        Policy memory tight = _defaultPolicy();
        tight.maxTradeUsdc = 50e6;
        assertEq(_setPolicy(tight), 0, "tightening is immediate");
        vm.warp(_eta(id));
        registry.executeQueued(address(account), id);
        Policy memory now_ = registry.policy(address(account));
        assertEq(now_.maxTradeUsdc, 50e6, "the later tightening survives");
        assertEq(now_.periodSpendCap, 1_000e6, "untouched fields widen");
    }

    /// @dev A -> B -> A: an old widening W1 (to 200) is queued, the field is tightened to 50, then a second widening
    ///      W2 back to 100 executes. W1 must not resurrect: the field was written after W1 was queued.
    function test_QueueABAKeepsTheNewerWrite() public {
        Policy memory w1 = _defaultPolicy();
        w1.maxTradeUsdc = 200e6;
        uint256 id1 = _setPolicy(w1);
        Policy memory b = _defaultPolicy();
        b.maxTradeUsdc = 50e6;
        _setPolicy(b);
        uint256 id2 = _setPolicy(_defaultPolicy());
        assertGt(id2, id1);
        vm.warp(_eta(id2));
        registry.executeQueued(address(account), id2);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6, "back to A");
        registry.executeQueued(address(account), id1);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6, "W1 does not resurrect");
    }

    function test_ExpiredQueueItem() public {
        Policy memory wide = _defaultPolicy();
        wide.maxTradeUsdc = 200e6;
        uint256 id = _setPolicy(wide);
        uint40 eta = _eta(id);
        uint256 snap = vm.snapshotState();
        vm.warp(eta + QUEUE_TTL);
        registry.executeQueued(address(account), id);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 200e6, "the last second still executes");
        vm.revertToState(snap);
        vm.warp(eta + QUEUE_TTL + 1);
        vm.expectRevert(IAgentPolicyRegistry.QueuedExpired.selector);
        registry.executeQueued(address(account), id);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, eta));
        registry.executeQueued(address(account), id);
    }

    /// @dev Pausing cancels every queued widening (policy, agent, allowlist); so does an ownership change.
    function test_PauseAndOwnershipChangeCancelQueuedWidenings() public {
        Policy memory wide = _defaultPolicy();
        wide.maxTradeUsdc = 200e6;
        address newKey = makeAddr("queued key");
        address tok = makeAddr("some token");
        vm.startPrank(accountOwner);
        uint256 idPolicy = registry.setPolicy(address(account), wide);
        uint256 idAgent = registry.addAgent(address(account), newKey, uint40(_now() + 10 days), P_BUY);
        uint256 idToken = registry.setTokenAllowed(address(account), tok, true);
        registry.pauseAgents(address(account), true);
        registry.pauseAgents(address(account), false);
        vm.stopPrank();
        vm.warp(_now() + 2 hours);
        uint256[3] memory ids = [idPolicy, idAgent, idToken];
        for (uint256 k; k < 3; ++k) {
            vm.expectEmit(address(registry));
            emit IAgentPolicyRegistry.QueuedCancelled(address(account), ids[k]);
            registry.executeQueued(address(account), ids[k]);
        }
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6);
        assertFalse(registry.agent(address(account), newKey).active);
        assertFalse(registry.tokenAllowed(address(account), tok));

        // Ownership change: a widening queued by the previous owner dies with the handover.
        address heir = makeAddr("heir");
        vm.startPrank(accountOwner);
        uint256 idWide = registry.setPolicy(address(account), wide);
        uint256 idOwner = registry.transferOwnership(address(account), heir);
        vm.stopPrank();
        vm.warp(_eta(idOwner));
        vm.prank(heir);
        registry.acceptOwnership(address(account), idOwner);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.QueuedCancelled(address(account), idWide);
        registry.executeQueued(address(account), idWide);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6);
    }

    function test_PolicyAboveACeilingReverts() public {
        Policy memory c = agentFactory.ceilings();
        for (uint8 f; f < 10; ++f) {
            if (f == 8) continue; // minTokenAgeBlocks is a floor at zero
            uint256[11] memory w = AgentPolicyLib.words(_defaultPolicy());
            uint256[11] memory cw = AgentPolicyLib.words(c);
            w[f] = cw[f] + 1;
            Policy memory p = abi.decode(abi.encode(w), (Policy));
            vm.prank(accountOwner);
            vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.BetaCeiling.selector, f));
            registry.setPolicy(address(account), p);
            // At creation too.
            InitParams memory ip = _defaults();
            ip.policy = p;
            vm.prank(accountOwner);
            vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.BetaCeiling.selector, f));
            agentFactory.createAccount(bytes32(uint256(100 + f)), ip);
        }
        assertEq(abi.encode(registry.policy(address(account))), abi.encode(_defaultPolicy()));
    }

    // ---------------------------------------------------------------- spec 10: tokens and reentrancy

    /// @dev A malicious token sent by a stranger: an agent can neither sweep it (not a Launch token, so no transfer
    ///      ever reaches it) nor buy it.
    function test_SweepAndBuyRejectUnregisteredTokens() public {
        ReentrantToken evil = new ReentrantToken();
        evil.transfer(address(account), 1e21);
        evil.arm(account);
        vm.expectCall(address(evil), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.prank(agentKey);
        vm.expectRevert(IAgentAccount.TokenNotRegistered.selector);
        account.sweepToOwner(address(evil), 1e21);
        // USDC's ERC-20 view is not a Launch token either.
        vm.prank(agentKey);
        vm.expectRevert(IAgentAccount.TokenNotRegistered.selector);
        account.sweepToOwner(USDC, 1);
        _expectBuyRevert(account, address(evil), 1e6, abi.encodeWithSelector(IAgentAccount.TokenNotRegistered.selector));
        assertEq(evil.balanceOf(address(account)), 1e21);
        assertEq(evil.attempts(), 0, "no call reached the token");
    }

    /// @dev The owner can withdraw a malicious token; its transfer hook tries to re-enter the account three ways
    ///      (withdraw, sweep, buy) and each is stopped by the lock.
    function test_MaliciousTokenCannotReenterOnOwnerWithdraw() public {
        ReentrantToken evil = new ReentrantToken();
        evil.transfer(address(account), 1e21);
        evil.arm(account);
        uint256 bal = address(account).balance;
        vm.prank(accountOwner);
        account.withdraw(address(evil), 1e21);
        assertEq(evil.balanceOf(accountOwner), 1e21);
        assertEq(evil.attempts(), 3);
        assertEq(evil.blocked(), 3, "every re-entry was refused");
        for (uint256 k; k < 3; ++k) {
            assertEq(
                evil.errors(k),
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                "withdraw, sweep and buy are each locked"
            );
        }
        assertEq(address(account).balance, bal, "nothing else moved");
    }

    /// @dev The curve's refund on a graduating buy lands in `receive`, which runs no code: a plain value call writes
    ///      no storage and reads none, and a call with data finds no fallback. The buy records only what the curve
    ///      kept.
    function test_CurveRefundLandsInAnEmptyReceive() public {
        vm.record();
        (bool ok,) = address(account).call{value: 1, gas: 10_000}("");
        assertTrue(ok);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(account));
        assertEq(reads.length, 0, "receive reads no storage");
        assertEq(writes.length, 0, "receive writes no storage");
        (ok,) = address(account).call{value: 1}(hex"deadbeef");
        assertFalse(ok, "no fallback");

        (LaunchToken t, BondingCurve c) = _create(bytes32("refund"));
        _fillCurveLeaving(c, 40e18 + 777);
        (, uint256 used,,) = c.quoteBuy(100e18);
        assertLt(used, 100e18, "a refund is due");
        uint256 bal = address(account).balance;
        _buy(account, address(t), 100e6);
        assertEq(uint8(c.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(bal - address(account).balance, used, "the refund came back");
        (uint64 spent,,) = _usage(account);
        assertEq(spent, Math.ceilDiv(used, 1e12));
    }

    // ---------------------------------------------------------------- Review Focus 1: unit mixing

    /// @dev Graduating buys leave refunds that are not multiples of 1e12. The usdc6 spend is the native delta rounded
    ///      up, everywhere (usage, per-token, basis), and proceeds round down.
    function testFuzz_RefundsNotDivisibleBy1e12AreChargedRoundedUp(uint256 leaveWei, uint256 sellPart) public {
        (LaunchToken t, BondingCurve c) = _create(bytes32("units"));
        leaveWei = bound(leaveWei, 1e15, 99e18);
        if (leaveWei % 1e12 == 0) leaveWei += 1;
        _fillCurveLeaving(c, leaveWei);
        uint256 remaining = c.curveSupply() - c.sold();
        uint256 bal = address(account).balance;
        uint256 out = _buy(account, address(t), 100e6);
        uint256 delta = bal - address(account).balance;
        assertEq(out, remaining);
        assertEq(uint8(c.phase()), uint8(BondingCurve.Phase.Graduated), "graduated inside the buy");
        uint256 spent6 = Math.ceilDiv(delta, 1e12);
        (uint64 spent,,) = _usage(account);
        assertEq(spent, spent6);
        assertGe(uint256(spent) * 1e12, delta, "never below the native delta");
        assertLt(uint256(spent) * 1e12 - delta, 1e12);
        assertEq(registry.tokenSpent(address(account), address(t)), spent6);
        (uint128 cost, uint128 tokens,) = account.basis(address(t));
        assertEq(cost, spent6, "basis counts only what the curve kept");
        assertEq(tokens, out);

        // A pool sell of a part not divisible by 1e12: proceeds round down.
        sellPart = bound(sellPart, 1e12 + 1, out / 10);
        uint256 bal2 = address(account).balance;
        uint256 dl = _dl();
        vm.prank(agentKey);
        try account.swapExactIn(address(t), false, sellPart, 1, dl) returns (uint256 usdcOut) {
            assertEq(usdcOut, (address(account).balance - bal2) / 1e12);
        } catch (bytes memory err) {
            // Price impact or a dust output are the only acceptable refusals here.
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == IAgentAccount.PriceImpactTooHigh.selector || sel == IV4Router.V4TooLittleReceived.selector,
                "refusal"
            );
        }
    }

    /// @dev An 18-decimal delta one wei over a 6-decimal cap never passes: with exactly X usdc6 of headroom, a buy
    ///      whose native cost is X * 1e12 + r (0 < r < 1e12) is charged X + 1 and reverts.
    function test_NativeDeltaJustAboveTheCapReverts() public {
        (LaunchToken t, BondingCurve c) = _create(bytes32("edge"));
        _fillCurveLeaving(c, 60e18 + 123_456_789);
        (, uint256 used,,) = c.quoteBuy(100e18);
        assertTrue(used % 1e12 != 0, "a cost with sub-usdc6 wei");
        uint64 x = uint64(used / 1e12);
        Policy memory p = _defaultPolicy();
        p.periodSpendCap = x;
        assertEq(_setPolicy(p), 0);
        _expectBuyRevert(
            account, address(t), 100e6, abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, x)
        );
        p.periodSpendCap = x + 1;
        // Widening by one unit is queued; a fresh account with the cap at x + 1 shows it passes exactly.
        AgentAccount a = _withPolicy(p);
        _buy(a, address(t), 100e6);
        (uint64 spent,,) = _usage(a);
        assertEq(spent, x + 1, "charged the rounded-up delta, exactly the cap");
    }

    // ---------------------------------------------------------------- Review Focus 4: tokens the account did not buy

    /// @dev After the stolen key has spent the whole cap, a stranger sends tokens; selling them works, is charged to
    ///      the sell cap at their quote, and never re-opens buying.
    function test_StrangerTokensNeverCreateBuyHeadroom() public {
        address[] memory bait = _attackerTokens(5);
        for (uint256 k; k < 5; ++k) {
            _buy(account, bait[k], 100e6);
        }
        (LaunchToken t, BondingCurve c) = _create(bytes32("gift"));
        vm.prank(bob);
        c.buy{value: 200e18}(0, address(0), type(uint256).max);
        uint256 gift = t.balanceOf(bob);
        vm.prank(bob);
        t.transfer(address(account), gift);
        (uint256 q,) = c.quoteSell(gift / 4);
        uint256 bal = address(account).balance;
        _sell(account, address(t), gift / 4);
        assertGt(address(account).balance, bal, "the sell of stranger tokens went through");
        (uint64 spent, uint64 sold,) = _usage(account);
        assertEq(spent, 500e6);
        assertEq(sold, Math.ceilDiv(q, 1e12), "charged at the pre-trade quote");
        _expectBuyRevert(
            account, address(t), 1, abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 0)
        );
    }

    // ---------------------------------------------------------------- Review Focus 5: owner exit under attack

    /// @dev A stolen key makes 500 dust buys across 500 attacker tokens (the action cap). With the guardian pause
    ///      active, the owner revokes the key and empties the account with one `withdrawMany` of 501 entries, all
    ///      cold, well inside a 30M block.
    function test_WithdrawManyAfter500DustBuysFitsInABlock() public {
        // Setting up 500 launches exceeds the test's own gas limit; metering resumes for the owner's exit.
        vm.pauseGasMetering();
        address[] memory bait = _attackerTokens(500);
        for (uint256 k; k < 500; ++k) {
            _buy(account, bait[k], 1);
        }
        _expectBuyRevert(account, bait[0], 1, abi.encodeWithSelector(IAgentPolicyRegistry.ActionLimit.selector));
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        assertTrue(agentFactory.isPaused());
        vm.resumeGasMetering();

        vm.prank(accountOwner);
        uint256 g0 = gasleft();
        registry.revokeAgent(address(account), agentKey);
        uint256 revokeGas = g0 - gasleft();

        address[] memory list = new address[](501);
        for (uint256 k; k < 500; ++k) {
            list[k + 1] = bait[k];
            vm.cool(bait[k]);
        }
        vm.cool(address(account));
        vm.cool(address(agentImpl));
        vm.cool(address(registry));
        // A 200-entry chunk (native plus 199 tokens, all cold) fits the 16,777,216 per-transaction gas cap
        // (EIP-7825), so an SDK can always split the exit into such chunks.
        uint256 snap = vm.snapshotState();
        address[] memory chunk = new address[](200);
        for (uint256 k = 1; k < 200; ++k) {
            chunk[k] = bait[k - 1];
        }
        vm.prank(accountOwner);
        g0 = gasleft();
        account.withdrawMany{gas: 16_777_216}(chunk);
        uint256 chunkGas = g0 - gasleft();
        emit log_named_uint("withdrawMany(200) gas", chunkGas);
        assertLt(chunkGas, 16_777_216);
        vm.revertToState(snap);

        uint256 native = address(account).balance;
        uint256 ownerBal = accountOwner.balance;
        vm.prank(accountOwner);
        g0 = gasleft();
        account.withdrawMany{gas: 29_000_000}(list);
        uint256 used = g0 - gasleft();
        emit log_named_uint("revokeAgent gas", revokeGas);
        emit log_named_uint("withdrawMany(501) gas", used);
        assertLt(used, 29_000_000);
        assertLt(revokeGas, 100_000);
        assertEq(accountOwner.balance - ownerBal, native);
        for (uint256 k; k < 500; ++k) {
            assertEq(IERC20(bait[k]).balanceOf(address(account)), 0);
            (, uint128 tokens,) = account.basis(bait[k]);
            assertEq(tokens, 0);
        }
    }

    /// @dev While the factory pause is active (also when the admin extends it to 30 days), agents are stopped and
    ///      every owner exit and narrowing still works.
    function test_GuardianPauseNeverBlocksOwnerExits() public {
        (LaunchToken t,) = _create(bytes32("exit"));
        _buy(account, address(t), 50e6);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(uint40(_now() + 30 days));
        vm.warp(_now() + 20 days);
        assertTrue(agentFactory.isPaused());
        _expectBuyRevert(account, address(t), 1e6, abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector));

        uint256 held = t.balanceOf(address(account));
        vm.startPrank(accountOwner);
        account.withdraw(address(0), 1e18 + 7);
        account.withdraw(address(t), held / 3);
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 10e6;
        assertEq(registry.setPolicy(address(account), p), 0);
        uint40 exp = registry.agent(address(account), agentKey).expiresAt;
        assertEq(registry.setAgent(address(account), agentKey, exp - 1, P_BUY), 0);
        uint256 id = registry.setTokenAllowed(address(account), address(t), true);
        registry.cancelQueued(address(account), id);
        registry.setTokenAllowed(address(account), address(t), false);
        registry.pauseAgents(address(account), true);
        registry.pauseAgents(address(account), false);
        registry.revokeAgent(address(account), agentKey);
        address[] memory list = new address[](2);
        list[1] = address(t);
        account.withdrawMany(list);
        vm.stopPrank();
        assertEq(address(account).balance, 0);
        assertEq(t.balanceOf(address(account)), 0);
        assertEq(t.balanceOf(accountOwner), held);
    }
}
