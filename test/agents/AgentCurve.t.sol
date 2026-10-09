// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/agents/interfaces/IAgentPolicyRegistry.sol";
import {Policy, P_BUY, P_SELL, ACTION_BUY, ACTION_SELL} from "../../src/agents/AgentTypes.sol";

/// @dev Task 3: capped curve buys and sells with cost basis (spec sections 4.2, 4.5 and 4.6).
contract AgentCurveTest is AgentFixture {
    AgentAccount internal account;
    LaunchToken internal token;
    BondingCurve internal curve;

    function setUp() public override {
        super.setUp();
        account = _account();
        vm.deal(address(account), 10_000e18);
        (token, curve) = _create(bytes32(uint256(1)));
    }

    // ---------------------------------------------------------------- helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _dl() internal view returns (uint256) {
        return _now() + 60;
    }

    function _pid() internal view returns (uint64) {
        return uint64(_now() / 1 days);
    }

    function _buy(uint256 usdcIn) internal returns (uint256) {
        return _buyOf(address(token), usdcIn);
    }

    function _buyOf(address t, uint256 usdcIn) internal returns (uint256) {
        vm.prank(agentKey);
        return account.buy(t, usdcIn, 1, _dl());
    }

    function _sell(uint256 tokensIn) internal returns (uint256) {
        vm.prank(agentKey);
        return account.sell(address(token), tokensIn, 1, _dl());
    }

    function _narrow(Policy memory p) internal {
        vm.prank(accountOwner);
        assertEq(registry.setPolicy(address(account), p), 0, "narrowing only");
    }

    function _expectBuyRevert(bytes memory err, uint256 usdcIn) internal {
        vm.prank(agentKey);
        vm.expectRevert(err);
        account.buy(address(token), usdcIn, 1, _dl());
    }

    function _expectSellRevert(bytes memory err, uint256 tokensIn) internal {
        vm.prank(agentKey);
        vm.expectRevert(err);
        account.sell(address(token), tokensIn, 1, _dl());
    }

    function _usageSpent() internal view returns (uint64 spent) {
        (, spent,,,) = registry.usage(address(account));
    }

    function _usageSold() internal view returns (uint64 sold) {
        (,, sold,,) = registry.usage(address(account));
    }

    function _usageActions() internal view returns (uint32 actions) {
        (,,, actions,) = registry.usage(address(account));
    }

    /// @dev Bob buys the curve up to `leftWei` (approximately) of gross USDC before it sells out.
    function _fillCurveLeaving(uint256 leftWei) internal {
        (, uint256 full,,) = curve.quoteBuy(1e30);
        vm.prank(bob);
        curve.buy{value: full - leftWei}(0, address(0), type(uint256).max);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
    }

    // ---------------------------------------------------------------- happy paths

    function test_BuyCreditsAccountPaysReferrerAndRecordsBasis() public {
        (uint256 out,,,) = curve.quoteBuy(50e18);
        uint256 refBefore = feeManager.balances(referrer);
        uint256 bal0 = address(account).balance;

        vm.expectEmit(true, false, false, false, address(curve));
        emit BondingCurve.Buy(address(account), 0, 0, 0, 0, 0, 0);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentAction(agentKey, ACTION_BUY, address(token), 50e6, 0, int256(out), 50e6, _pid());
        assertEq(_buy(50e6), out);

        assertEq(token.balanceOf(address(account)), out);
        assertEq(bal0 - address(account).balance, 50e18);
        (uint128 cost, uint128 held) = account.basis(address(token));
        assertEq(cost, 50e6);
        assertEq(held, out);
        (uint64 pid, uint64 spent, uint64 sold, uint32 actions, uint16 launches) = registry.usage(address(account));
        assertEq(pid, _pid());
        assertEq(spent, 50e6);
        assertEq(sold, 0);
        assertEq(actions, 1);
        assertEq(launches, 0);
        assertEq(registry.tokenSpent(address(account), address(token)), 50e6);
        assertEq(feeManager.referrerOf(address(account)), referrer);
        assertGt(feeManager.balances(referrer), refBefore, "referrer earns its share");
        (uint64 hs, uint64 hsell, uint32 ha, uint16 hl) = registry.headroom(address(account));
        assertEq(hs, 450e6);
        assertEq(hsell, 500e6);
        assertEq(ha, 499);
        assertEq(hl, 3);
    }

    function test_SellReturnsNativeUsdcAndReducesBasisProRata() public {
        uint256 held = _buy(50e6);
        uint256 half = held / 3;
        (uint256 usdcOut,) = curve.quoteSell(half);
        uint256 value = Math.mulDiv(half, 50e6, held, Math.Rounding.Ceil);
        uint256 bal0 = address(account).balance;

        vm.expectEmit(true, false, false, false, address(curve));
        emit BondingCurve.Sell(address(account), 0, 0, 0, 0, 0);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentAction(
            agentKey, ACTION_SELL, address(token), 0, usdcOut / 1e12, -int256(half), value, _pid()
        );
        assertEq(_sell(half), usdcOut / 1e12);

        assertEq(address(account).balance - bal0, usdcOut, "native USDC in");
        assertEq(token.balanceOf(address(account)), held - half);
        assertEq(token.allowance(address(account), address(curve)), 0);
        (uint128 cost, uint128 tokens) = account.basis(address(token));
        assertEq(tokens, held - half);
        assertEq(cost, 50e6 - Math.mulDiv(50e6, half, held));
        assertEq(_usageSold(), value);
        assertEq(_usageSpent(), 50e6, "proceeds create no headroom");
        assertEq(_usageActions(), 2);

        // Selling the rest clears the basis exactly.
        _sell(held - half);
        (cost, tokens) = account.basis(address(token));
        assertEq(cost, 0);
        assertEq(tokens, 0);
        // Values round up and the basis reduction rounds down, so a split exit is charged its cost plus at most
        // one usdc6 unit per sell, never less.
        assertGe(_usageSold(), 50e6, "a full exit is charged at least its cost");
        assertLe(_usageSold(), 50e6 + 2);
    }

    // ---------------------------------------------------------------- who may trade

    function test_OnlyActiveAgentsWithThePermissionTrade() public {
        uint256 dl = _dl();
        vm.prank(stranger);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.buy(address(token), 1e6, 1, dl);
        // The owner has no trade path.
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.buy(address(token), 1e6, 1, dl);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.sell(address(token), 1, 1, dl);

        uint40 exp = registry.agent(address(account), agentKey).expiresAt;
        vm.prank(accountOwner);
        registry.setAgent(address(account), agentKey, exp, P_BUY);
        _buy(1e6);
        _expectSellRevert(abi.encodeWithSelector(IAgentPolicyRegistry.MissingPermission.selector), 1);
        // Swapping the bit is a widening: queue it and execute after the delay.
        vm.prank(accountOwner);
        uint256 id = registry.setAgent(address(account), agentKey, exp, P_SELL);
        vm.warp(_now() + 1 hours);
        registry.executeQueued(address(account), id);
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.MissingPermission.selector), 1e6);

        vm.warp(exp);
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.AgentExpired.selector), 1e6);

        vm.prank(accountOwner);
        registry.revokeAgent(address(account), agentKey);
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.NotAgent.selector), 1e6);
    }

    function test_OwnerAndFactoryPausesStopAgents() public {
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), true);
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector), 1e6);
        _expectSellRevert(abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector), 1);
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), false);
        _buy(1e6);

        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector), 1e6);
        _expectSellRevert(abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector), 1);
    }

    function test_DeadlineMustBeWithinWindow() public {
        uint256 t = _now();
        vm.startPrank(agentKey);
        vm.expectRevert(IAgentPolicyRegistry.DeadlineOutOfRange.selector);
        account.buy(address(token), 1e6, 1, t - 1);
        vm.expectRevert(IAgentPolicyRegistry.DeadlineOutOfRange.selector);
        account.buy(address(token), 1e6, 1, t + 121);
        vm.expectRevert(IAgentPolicyRegistry.DeadlineOutOfRange.selector);
        account.sell(address(token), 1, 1, t + 121);
        account.buy(address(token), 1e6, 1, t);
        account.buy(address(token), 1e6, 1, t + 120);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- token checks

    function test_UnregisteredTokenReverts() public {
        uint256 dl = _dl();
        vm.startPrank(agentKey);
        vm.expectRevert(IAgentAccount.TokenNotRegistered.selector);
        account.buy(stranger, 1e6, 1, dl);
        vm.expectRevert(IAgentAccount.TokenNotRegistered.selector);
        account.sell(stranger, 1, 1, dl);
        vm.stopPrank();
    }

    function test_AllowlistBlocksBuysNotSells() public {
        uint256 held = _buy(10e6);
        Policy memory p = _defaultPolicy();
        p.allowlistOnly = true;
        _narrow(p);
        _expectBuyRevert(abi.encodeWithSelector(IAgentAccount.TokenNotAllowed.selector), 1e6);
        _sell(held);
        assertEq(token.balanceOf(address(account)), 0);
    }

    function test_TokenTooNew() public {
        Policy memory p = _defaultPolicy();
        p.minTokenAgeBlocks = uint32(cfg.snipeBlocks + 1);
        _narrow(p);
        _expectBuyRevert(abi.encodeWithSelector(IAgentAccount.TokenTooNew.selector), 1e6);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(1e6);
    }

    function test_SnipeTaxTooHighDuringSnipeWindow() public {
        bytes32 pinned = factory.configHash();
        vm.prank(alice);
        (address t, address c) = factory.createToken{value: cfg.launchFee}(_params(bytes32(uint256(77))), pinned, 0);
        uint256 snipe = BondingCurve(c).currentSnipeBps();
        assertGt(snipe, 0);
        uint256 dl = _dl();
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.SnipeTaxTooHigh.selector, snipe));
        account.buy(t, 1e6, 1, dl);
    }

    function test_PriceImpactTooHighOnABigBuy() public {
        Policy memory p = _defaultPolicy();
        p.maxPriceImpactBps = 100;
        _narrow(p);
        vm.prank(agentKey);
        vm.expectPartialRevert(IAgentAccount.PriceImpactTooHigh.selector);
        account.buy(address(token), 100e6, 1, _now() + 60);
        // A small buy passes.
        _buy(10e6);
        // A big sell back fails too.
        p.maxPriceImpactBps = 1;
        _narrow(p);
        uint256 held = token.balanceOf(address(account));
        vm.prank(agentKey);
        vm.expectPartialRevert(IAgentAccount.PriceImpactTooHigh.selector);
        account.sell(address(token), held, 1, _now() + 60);
    }

    function test_ZeroInputsRevert() public {
        uint256 dl = _dl();
        vm.startPrank(agentKey);
        vm.expectRevert(IAgentAccount.ZeroMinOut.selector);
        account.buy(address(token), 1e6, 0, dl);
        vm.expectRevert(IAgentAccount.ZeroAmount.selector);
        account.buy(address(token), 0, 1, dl);
        uint256 held = account.buy(address(token), 1e6, 1, dl);
        vm.expectRevert(IAgentAccount.ZeroMinOut.selector);
        account.sell(address(token), held, 0, dl);
        vm.expectRevert(IAgentAccount.ZeroAmount.selector);
        account.sell(address(token), 0, 1, dl);
        vm.stopPrank();
    }

    function test_HugeMinOutRevertsAmountTooLarge() public {
        uint256 held = _buy(1e6);
        uint256 dl = _dl();
        vm.prank(agentKey);
        vm.expectRevert(IAgentAccount.AmountTooLarge.selector);
        account.sell(address(token), held, type(uint256).max / 1e12 + 1, dl);
        // The largest convertible value reaches the curve and fails its slippage check, not with a panic.
        vm.prank(agentKey);
        vm.expectRevert(BondingCurve.Slippage.selector);
        account.sell(address(token), held, type(uint256).max / 1e12, dl);
    }

    // ---------------------------------------------------------------- caps

    function test_TradeTooLarge() public {
        _expectBuyRevert(abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 100e6), 100e6 + 1);
        uint256 held = _buy(100e6);
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 50e6;
        _narrow(p);
        // The sell is valued at cost (100), not at its proceeds (about 98).
        _expectSellRevert(abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 50e6), held);
        _sell(held / 2);
    }

    function test_PeriodSpendExceeded() public {
        (LaunchToken t2,) = _create(bytes32(uint256(2)));
        Policy memory p = _defaultPolicy();
        p.periodSpendCap = 150e6;
        _narrow(p);
        _buy(100e6);
        vm.prank(agentKey);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 50e6));
        account.buy(address(t2), 60e6, 1, _now() + 60);
        _buyOf(address(t2), 50e6);
        assertEq(_usageSpent(), 150e6);
    }

    function test_TokenCapExceeded() public {
        _buy(60e6);
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TokenCapExceeded.selector, 40e6), 60e6);
        _buy(40e6);
        assertEq(registry.tokenSpent(address(account), address(token)), 100e6);
    }

    function test_PeriodSellExceeded() public {
        uint256 held = _buy(100e6);
        Policy memory p = _defaultPolicy();
        p.periodSellCap = 50e6;
        _narrow(p);
        _expectSellRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, 50e6), held);
        _sell(held / 2);
        assertEq(_usageSold(), 50e6);
        _expectSellRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, 0), held / 4);
    }

    function test_ActionLimit() public {
        Policy memory p = _defaultPolicy();
        p.maxActionsPerPeriod = 2;
        _narrow(p);
        uint256 held = _buy(1e6);
        _sell(held / 2);
        _expectBuyRevert(abi.encodeWithSelector(IAgentPolicyRegistry.ActionLimit.selector), 1e6);
        _expectSellRevert(abi.encodeWithSelector(IAgentPolicyRegistry.ActionLimit.selector), 1);
    }

    function test_GraduatedCurveRevertsNotTradingWithoutPanic() public {
        uint256 held = _buy(10e6);
        _graduate(curve);
        _expectBuyRevert(abi.encodeWithSelector(IAgentAccount.NotTrading.selector), 1e6);
        _expectSellRevert(abi.encodeWithSelector(IAgentAccount.NotTrading.selector), held);
    }

    // ---------------------------------------------------------------- periods

    function test_PeriodRolloverResetsUsage() public {
        // Several blocks may share a timestamp; usage accumulates within the period.
        _buy(10e6);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(10e6);
        vm.roll(vm.getBlockNumber() + 1);
        (uint64 pid, uint64 spent,, uint32 actions,) = registry.usage(address(account));
        assertEq(pid, _pid());
        assertEq(spent, 20e6);
        assertEq(actions, 2);
        assertEq(registry.tokenSpent(address(account), address(token)), 20e6);

        // The last second of the period still counts in it.
        vm.warp((uint256(_pid()) + 1) * 1 days - 1);
        _buy(10e6);
        (, spent,, actions,) = registry.usage(address(account));
        assertEq(spent, 30e6);

        vm.warp((uint256(_pid()) + 1) * 1 days);
        (pid, spent,, actions,) = registry.usage(address(account));
        assertEq(pid, _pid());
        assertEq(spent, 0);
        assertEq(actions, 0);
        assertEq(registry.tokenSpent(address(account), address(token)), 0, "per-token spend is per period");
        (uint64 hs,,,) = registry.headroom(address(account));
        assertEq(hs, 500e6);
        _buy(100e6);
        (, spent,, actions,) = registry.usage(address(account));
        assertEq(spent, 100e6);
        assertEq(actions, 1);
    }

    // ---------------------------------------------------------------- graduation inside a buy (Review Focus 3)

    function test_BuyThatGraduatesCountsOnlyWhatTheCurveTook() public {
        _fillCurveLeaving(60e18 + 123_456_789);
        uint256 remaining = curve.curveSupply() - curve.sold();
        (uint256 qOut, uint256 used,,) = curve.quoteBuy(100e18);
        assertEq(qOut, remaining, "final buy");
        assertLt(used, 100e18, "refund expected");
        uint256 bal0 = address(account).balance;

        vm.prank(agentKey);
        uint256 out = account.buy{gas: 2_500_000}(address(token), 100e6, 1, _now() + 60);

        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(out, remaining);
        uint256 delta = bal0 - address(account).balance;
        assertEq(delta, used, "refund netted");
        uint256 spent6 = Math.ceilDiv(delta, 1e12);
        assertEq(_usageSpent(), spent6);
        assertEq(registry.tokenSpent(address(account), address(token)), spent6);
        (uint128 cost, uint128 tokens) = account.basis(address(token));
        assertEq(cost, spent6);
        assertEq(tokens, remaining);
    }

    function test_GraduatingBuyRevertsWholeWithTooLittleGas() public {
        _fillCurveLeaving(60e18 + 123_456_789);
        uint256 bal0 = address(account).balance;
        uint256 dl = _dl();
        vm.prank(agentKey);
        (bool ok,) =
            address(account).call{gas: 1_000_000}(abi.encodeCall(AgentAccount.buy, (address(token), 100e6, 1, dl)));
        assertFalse(ok, "starved graduating buy must revert");
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
        assertEq(address(account).balance, bal0);
        assertEq(token.balanceOf(address(account)), 0);
        assertEq(_usageActions(), 0);
    }

    /// @dev Finds the smallest call gas for a graduating buy by bisection. Before each probe every contract the
    ///      buy touches is cooled (`vm.cool`), so each probe pays cold access like a fresh transaction (the 21k
    ///      intrinsic cost is not part of call gas). Every successful probe must have graduated: a probe that
    ///      succeeded with a deferred graduation would fail here.
    function test_GraduatingBuyGasFloorBisection() public {
        _fillCurveLeaving(60e18 + 123_456_789);
        uint256 dl = _dl();
        bytes memory data = abi.encodeCall(AgentAccount.buy, (address(token), 100e6, 1, dl));
        uint256 lo = 1_000_000;
        uint256 hi = 2_500_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            _coolAll();
            vm.prank(agentKey);
            (bool ok,) = address(account).call{gas: mid}(data);
            if (ok) assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated), "no silent deferral");
            else assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading), "whole buy reverted");
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("graduating agent buy: minimum call gas (cold)", hi);
        assertLt(hi, 2_500_000);
    }

    function _coolAll() internal {
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address[17] memory list = [
            address(account),
            address(agentImpl),
            address(registry),
            address(agentFactory),
            address(factory),
            address(uint160(uint256(vm.load(address(factory), implSlot)))),
            address(feeManager),
            address(uint160(uint256(vm.load(address(feeManager), implSlot)))),
            address(gm),
            address(uint160(uint256(vm.load(address(gm), implSlot)))),
            address(curve),
            address(token),
            address(hook),
            address(locker),
            address(poolManager),
            address(posm),
            address(permit2)
        ];
        for (uint256 i; i < list.length; ++i) {
            vm.cool(list[i]);
        }
        vm.cool(USDC);
    }

    // ---------------------------------------------------------------- tokens the account did not buy (Review Focus 4)

    function test_StrangerTokensSellAtQuoteAndGiveNoBuyHeadroom() public {
        uint256 held = _buy(50e6);
        vm.prank(bob);
        curve.buy{value: 20e18}(0, address(0), type(uint256).max);
        uint256 extra = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(address(account), extra);
        (uint64 hsBefore,,,) = registry.headroom(address(account));

        (uint256 quoteExtra,) = curve.quoteSell(extra);
        uint256 expected = 50e6 + Math.ceilDiv(quoteExtra, 1e12);
        uint256 total = held + extra;
        _sell(total);

        assertEq(_usageSold(), expected, "recorded at cost plus excess at quote");
        (uint128 cost, uint128 tokens) = account.basis(address(token));
        assertEq(cost, 0);
        assertEq(tokens, 0);
        (uint64 hsAfter,,,) = registry.headroom(address(account));
        assertEq(hsAfter, hsBefore, "no buy headroom from proceeds");
        assertEq(_usageSpent(), 50e6);
    }

    function test_SellOfOnlyStrangerTokensWorksWithZeroBasis() public {
        vm.prank(bob);
        curve.buy{value: 20e18}(0, address(0), type(uint256).max);
        uint256 extra = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(address(account), extra);
        (uint256 q,) = curve.quoteSell(extra);
        _sell(extra);
        assertEq(_usageSold(), Math.ceilDiv(q, 1e12));
        assertEq(_usageSpent(), 0);
    }

    // ---------------------------------------------------------------- fuzz (Review Focus 1)

    function testFuzz_UnitsRoundTheSafeWay(uint256 preBuy, uint256 usdcIn, uint256 sellAmt) public {
        (, uint256 full,,) = curve.quoteBuy(1e30);
        preBuy = bound(preBuy, 0, full - 2e18);
        if (preBuy != 0) {
            vm.prank(bob);
            curve.buy{value: preBuy}(0, address(0), type(uint256).max);
        }
        usdcIn = bound(usdcIn, 1, 100e6);
        uint256 bal0 = address(account).balance;
        _buy(usdcIn);
        uint256 delta = bal0 - address(account).balance;
        uint64 spent6 = _usageSpent();
        assertGe(uint256(spent6) * 1e12, delta, "spent rounds up");
        assertLt(uint256(spent6) * 1e12 - delta, 1e12);
        assertLe(spent6, usdcIn);
        (uint128 cost, uint128 tokens) = account.basis(address(token));
        assertEq(cost, spent6, "basis is what was spent");
        assertEq(tokens, token.balanceOf(address(account)));

        if (curve.phase() != BondingCurve.Phase.Trading) return;
        sellAmt = bound(sellAmt, 1, tokens);
        (uint256 q,) = curve.quoteSell(sellAmt);
        if (q < 1e12) return; // below the 1 usdc6 minimum out
        bal0 = address(account).balance;
        uint256 got6 = _sell(sellAmt);
        delta = address(account).balance - bal0;
        assertLe(got6 * 1e12, delta, "received rounds down");
        assertLt(delta - got6 * 1e12, 1e12);
        (uint128 cost2, uint128 tokens2) = account.basis(address(token));
        assertLe(cost2, cost, "basis never grows on a sell");
        assertEq(tokens2, tokens - sellAmt);
        assertGe(uint256(_usageSold()) + cost2, cost, "sold value plus remaining cost covers the cost");
        if (tokens2 == 0) assertEq(cost2, 0);
    }
}
