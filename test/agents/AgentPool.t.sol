// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchHook} from "@mercuri/launch/LaunchHook.sol";
import {GraduationManager} from "@mercuri/launch/GraduationManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {ICanonicalRouter} from "../integration/UniversalRouterSwap.t.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentPolicyLib} from "../../src/agents/AgentPolicyLib.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/agents/interfaces/IAgentPolicyRegistry.sol";
import {Policy, InitParams, P_BUY, P_SELL, ACTION_POOL_BUY, ACTION_POOL_SELL} from "../../src/agents/AgentTypes.sol";

/// @dev Task 5: capped graduated-pool swaps through the Universal Router (spec section 4.6, `swapExactIn`).
contract AgentPoolTest is AgentFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    AgentAccount internal account;
    /// @dev Graduated tokens: index 0 sorts below USDC, index 1 above it.
    LaunchToken[2] internal toks;
    BondingCurve[2] internal curves;

    function setUp() public override {
        super.setUp();
        InitParams memory ip = _defaults();
        ip.policy.maxPriceImpactBps = 2_000;
        account = _account(accountOwner, bytes32(0), ip);
        vm.deal(address(account), 10_000e18);
        for (uint256 i; i < 2; ++i) {
            (toks[i], curves[i]) = _createOrdered(i == 0);
            _graduate(curves[i]);
        }
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

    function _swap(LaunchToken t, bool buyToken, uint256 amountIn, uint256 minOut) internal returns (uint256) {
        vm.prank(agentKey);
        return account.swapExactIn(address(t), buyToken, amountIn, minOut, _dl());
    }

    function _expectSwapRevert(bytes memory err, LaunchToken t, bool buyToken, uint256 amountIn, uint256 minOut)
        internal
    {
        uint256 dl = _dl();
        vm.prank(agentKey);
        vm.expectRevert(err);
        account.swapExactIn(address(t), buyToken, amountIn, minOut, dl);
    }

    function _quote(LaunchToken t, bool buyToken, uint256 amountIn) internal returns (uint256 out) {
        PoolKey memory key = gm.poolKey(address(t));
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(
                key, buyToken == usdcIs0, uint128(amountIn), abi.encode(uint256(uint160(address(account))))
            )
        );
    }

    function _sqrt(PoolKey memory key) internal view returns (uint160 s) {
        (s,,,) = poolManager.getSlot0(key.toId());
    }

    /// @dev The exact router inputs the account must build for `token`'s derived key.
    function _routerInputs(LaunchToken t, bool buyToken, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (bytes[] memory inputs)
    {
        PoolKey memory key = gm.poolKey(address(t));
        address input = buyToken ? USDC : address(t);
        address output = buyToken ? address(t) : USDC;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams(
                key,
                input == Currency.unwrap(key.currency0),
                uint128(amountIn),
                uint128(minOut),
                0,
                abi.encode(uint256(uint160(address(account))))
            )
        );
        params[1] = abi.encode(Currency.wrap(input), amountIn);
        params[2] = abi.encode(Currency.wrap(output), minOut);
        bytes memory actions = hex"060c0f";
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _assertNoAllowance(address input) internal view {
        assertEq(IERC20(input).allowance(address(account), address(permit2)), 0, "erc20 allowance to permit2");
        (uint160 amt,,) = permit2.allowance(address(account), input, address(router));
        assertEq(amt, 0, "permit2 allowance to router");
    }

    function _narrow(Policy memory p) internal {
        vm.prank(accountOwner);
        assertEq(registry.setPolicy(address(account), p), 0, "narrowing only");
    }

    function _policy() internal pure returns (Policy memory p) {
        p = _defaultPolicy();
        p.maxPriceImpactBps = 2_000;
    }

    function _usage() internal view returns (uint64 spent, uint64 sold, uint32 actions) {
        (, spent, sold, actions,) = registry.usage(address(account));
    }

    function _recordedValue(address t, uint256 rec) internal view returns (uint256) {
        (uint128 cost, uint128 tokens, uint256 hw) = account.basis(t);
        if (tokens == 0) return 0;
        uint256 v = Math.mulDiv(rec, cost, tokens, Math.Rounding.Ceil);
        uint256 hwValue = Math.mulDiv(rec, hw, 1e36);
        return hwValue > v ? hwValue : v;
    }

    /// @dev Bob's tokens of `t`, bought on the curve before graduation.
    function _gift(LaunchToken t, uint256 amount) internal {
        vm.prank(bob);
        t.transfer(address(account), amount);
    }

    // ---------------------------------------------------------------- happy paths, both orderings

    function test_PoolBuyAndSellBothOrderings() public {
        for (uint256 i; i < 2; ++i) {
            LaunchToken t = toks[i];
            PoolKey memory key = gm.poolKey(address(t));
            assertEq(Currency.unwrap(i == 0 ? key.currency1 : key.currency0), USDC, "ordering");

            // Buy.
            uint256 quoted = _quote(t, true, 20e6);
            uint256 bal0 = address(account).balance;
            (uint64 spent0, uint64 sold0, uint32 actions0) = _usage();
            vm.expectEmit(true, true, false, false, address(hook));
            emit LaunchHook.HookFee(address(t), address(account), 0);
            vm.expectEmit(address(account));
            emit IAgentAccount.AgentAction(agentKey, ACTION_POOL_BUY, address(t), 20e6, 0, int256(quoted), 20e6, _pid());
            assertEq(_swap(t, true, 20e6, quoted), quoted);
            assertEq(t.balanceOf(address(account)), quoted, "tokens land in the account");
            assertEq(bal0 - address(account).balance, 20e18, "native delta is the usdc6 input");
            _assertNoAllowance(USDC);
            (uint128 cost, uint128 held, uint256 hw) = account.basis(address(t));
            assertEq(cost, 20e6);
            assertEq(held, quoted);
            assertEq(hw, Math.mulDiv(20e6, 1e36, quoted, Math.Rounding.Ceil));
            (uint64 spent1, uint64 sold1, uint32 actions1) = _usage();
            assertEq(spent1 - spent0, 20e6);
            assertEq(sold1, sold0);
            assertEq(actions1 - actions0, 1);
            assertEq(registry.tokenSpent(address(account), address(t)), 20e6);

            // Sell half.
            uint256 half = quoted / 2;
            uint256 value = _recordedValue(address(t), half);
            uint256 out = _quote(t, false, half);
            uint256 bal1 = address(account).balance;
            vm.expectEmit(true, true, false, false, address(hook));
            emit LaunchHook.HookFee(address(t), address(account), 0);
            vm.expectEmit(address(account));
            emit IAgentAccount.AgentAction(agentKey, ACTION_POOL_SELL, address(t), 0, out, -int256(half), value, _pid());
            assertEq(_swap(t, false, half, out), out);
            assertEq(address(account).balance - bal1, out * 1e12, "USDC lands in the account");
            assertEq(t.balanceOf(address(account)), quoted - half);
            _assertNoAllowance(address(t));
            (cost, held, hw) = account.basis(address(t));
            assertEq(held, quoted - half);
            assertEq(cost, 20e6 - Math.mulDiv(20e6, half, quoted));
            (uint64 spent2, uint64 sold2,) = _usage();
            assertEq(spent2, spent1, "proceeds give no buy headroom");
            assertEq(sold2 - sold1, value);
        }
    }

    function test_RouterCallUsesTheDerivedKeyAndExactEncoding() public {
        for (uint256 i; i < 2; ++i) {
            LaunchToken t = toks[i];
            uint256 q = _quote(t, true, 10e6);
            vm.expectCall(
                address(router),
                abi.encodeCall(ICanonicalRouter.execute, (hex"10", _routerInputs(t, true, 10e6, q), _dl()))
            );
            _swap(t, true, 10e6, q);
            uint256 held = t.balanceOf(address(account));
            uint256 out = _quote(t, false, held);
            vm.expectCall(
                address(router),
                abi.encodeCall(ICanonicalRouter.execute, (hex"10", _routerInputs(t, false, held, out), _dl()))
            );
            _swap(t, false, held, out);
            assertEq(t.balanceOf(address(account)), 0);
        }
    }

    function test_CurveBasisCarriesIntoThePool() public {
        // Bought on the curve, sold in the pool after graduation: valued at its curve cost.
        (LaunchToken t, BondingCurve c) = _createOrdered(true);
        vm.prank(agentKey);
        uint256 held = account.buy(address(t), 50e6, 1, _dl());
        _graduate(c);
        (, uint64 sold0,) = _usage();
        uint256 out = _quote(t, false, held);
        _swap(t, false, held, out);
        (, uint64 sold1,) = _usage();
        assertEq(sold1 - sold0, 50e6, "a single lot exits at exactly its cost");
        (uint128 cost, uint128 tokens, uint256 hw) = account.basis(address(t));
        assertEq(cost, 0);
        assertEq(tokens, 0);
        assertEq(hw, 0);
    }

    // ---------------------------------------------------------------- phase and pool identity

    function test_NotGraduated() public {
        (LaunchToken t,) = _createOrdered(false);
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.NotGraduated.selector), t, true, 1e6, 1);
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.NotGraduated.selector), t, false, 1e18, 1);
        _expectSwapRevert(
            abi.encodeWithSelector(IAgentAccount.TokenNotRegistered.selector), LaunchToken(USDC), true, 1e6, 1
        );
    }

    function test_MaliciousPoolForTheSameTokenIsNeverReached() public {
        for (uint256 i; i < 2; ++i) {
            LaunchToken t = toks[i];
            // An attacker opens a pool for the same pair with its own hook (none here) and liquidity.
            PoolKey memory evil = gm.poolKey(address(t));
            evil.hooks = IHooks(address(0));
            evil.fee = 3000;
            evil.tickSpacing = 60;
            poolManager.initialize(evil, uint160(1 << 96));
            PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
            vm.prank(bob);
            t.transfer(address(this), 1e18);
            t.approve(address(lp), type(uint256).max);
            IERC20(USDC).approve(address(lp), type(uint256).max);
            lp.modifyLiquidity(evil, ModifyLiquidityParams(-887220, 887220, 1e9, bytes32(0)), "");
            uint160 evilBefore = _sqrt(evil);
            uint160 launchBefore = _sqrt(gm.poolKey(address(t)));

            uint256 q = _quote(t, true, 10e6);
            vm.expectCall(
                address(router),
                abi.encodeCall(ICanonicalRouter.execute, (hex"10", _routerInputs(t, true, 10e6, q), _dl()))
            );
            vm.expectEmit(true, true, false, false, address(hook));
            emit LaunchHook.HookFee(address(t), address(account), 0);
            _swap(t, true, 10e6, q);
            assertEq(_sqrt(evil), evilBefore, "attacker pool untouched");
            assertTrue(_sqrt(gm.poolKey(address(t))) != launchBefore, "Launch pool moved");
        }
    }

    function test_KeyWithoutTheLaunchHookOrUsdcReverts() public {
        LaunchToken t = toks[0];
        PoolKey memory bad = gm.poolKey(address(t));
        bad.hooks = IHooks(makeAddr("attacker hook"));
        vm.mockCall(address(gm), abi.encodeCall(GraduationManager.poolKey, (address(t))), abi.encode(bad));
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.UnexpectedPool.selector), t, true, 1e6, 1);

        bad = gm.poolKey(address(toks[1]));
        vm.clearMockedCalls();
        // Another token's genuine key, returned for this token.
        vm.mockCall(address(gm), abi.encodeCall(GraduationManager.poolKey, (address(t))), abi.encode(bad));
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.UnexpectedPool.selector), t, true, 1e6, 1);
    }

    // ---------------------------------------------------------------- impact, slippage, allowances

    function test_PriceImpactTooHigh() public {
        for (uint256 i; i < 2; ++i) {
            uint256 iter = vm.snapshotState();
            LaunchToken t = toks[i];
            PoolKey memory key = gm.poolKey(address(t));

            // Buy: measure the impact in a snapshot, then allow one basis point less.
            uint256 snap = vm.snapshotState();
            uint160 before = _sqrt(key);
            _swap(t, true, 50e6, 1);
            uint256 bps = AgentPolicyLib.poolImpactBps(before, _sqrt(key));
            vm.revertToState(snap);
            assertGt(bps, 0, "a 50 USDC buy moves the pool");
            Policy memory p = _policy();
            p.maxPriceImpactBps = uint16(bps - 1);
            _narrow(p);
            _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.PriceImpactTooHigh.selector, bps), t, true, 50e6, 1);
            vm.revertToState(snap);
            p.maxPriceImpactBps = uint16(bps);
            _narrow(p);
            _swap(t, true, 50e6, 1);
            // Back to the wide policy (and before the buy), then buy for the sell check.
            vm.revertToState(snap);
            _swap(t, true, 50e6, 1);

            // Sell: the same check.
            uint256 held = t.balanceOf(address(account));
            snap = vm.snapshotState();
            before = _sqrt(key);
            _swap(t, false, held, 1);
            uint256 sellBps = AgentPolicyLib.poolImpactBps(before, _sqrt(key));
            vm.revertToState(snap);
            assertGt(sellBps, 0);
            p.maxPriceImpactBps = uint16(sellBps - 1);
            _narrow(p);
            _expectSwapRevert(
                abi.encodeWithSelector(IAgentAccount.PriceImpactTooHigh.selector, sellBps), t, false, held, 1
            );
            vm.revertToState(iter);
        }
    }

    function test_PoolImpactMaths() public pure {
        uint256 s = 79228162514264337593543950336; // 1.0 in Q64.96
        assertEq(AgentPolicyLib.poolImpactBps(s, s), 0);
        // sqrt up exactly 1% -> price up 2.01%.
        assertEq(AgentPolicyLib.poolImpactBps(100 * s, 101 * s), 201);
        // sqrt down exactly 1% -> price down 1.99%.
        assertEq(AgentPolicyLib.poolImpactBps(100 * s, 99 * s), 199);
        // Rounded down: just under 2.01%.
        assertEq(AgentPolicyLib.poolImpactBps(s, s * 101 / 100), 200);
    }

    function test_MinOutNotMetBubblesTheRouterRevert() public {
        for (uint256 i; i < 2; ++i) {
            LaunchToken t = toks[i];
            uint256 q = _quote(t, true, 10e6);
            uint256 bal = address(account).balance;
            _expectSwapRevert(
                abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, q + 1, q), t, true, 10e6, q + 1
            );
            assertEq(address(account).balance, bal);
            _assertNoAllowance(USDC);
            _swap(t, true, 10e6, q);
            uint256 held = t.balanceOf(address(account));
            uint256 out = _quote(t, false, held);
            _expectSwapRevert(
                abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, out + 1, out), t, false, held, out + 1
            );
            _assertNoAllowance(address(t));
        }
    }

    function test_NoAllowanceSurvivesEitherDirection() public {
        for (uint256 i; i < 2; ++i) {
            LaunchToken t = toks[i];
            _swap(t, true, 5e6, 1);
            _assertNoAllowance(USDC);
            _assertNoAllowance(address(t));
            _swap(t, false, t.balanceOf(address(account)) / 3, 1);
            _assertNoAllowance(USDC);
            _assertNoAllowance(address(t));
        }
    }

    // ---------------------------------------------------------------- input validation and permissions

    function test_InputValidation() public {
        LaunchToken t = toks[0];
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.ZeroAmount.selector), t, true, 0, 1);
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.ZeroMinOut.selector), t, true, 1e6, 0);
        uint256 big = uint256(type(uint128).max) + 1;
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.AmountTooLarge.selector), t, false, big, 1);
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.AmountTooLarge.selector), t, true, 1e6, big);
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.AmountTooLarge.selector), t, true, type(uint256).max, 1);
    }

    function test_OnlyAgentsWithPoolSwapPermission() public {
        LaunchToken t = toks[0];
        uint256 dl = _dl();
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.swapExactIn(address(t), true, 1e6, 1, dl);
        vm.prank(stranger);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.swapExactIn(address(t), true, 1e6, 1, dl);

        uint40 exp = registry.agent(address(account), agentKey).expiresAt;
        vm.prank(accountOwner);
        registry.setAgent(address(account), agentKey, exp, P_BUY | P_SELL);
        _expectSwapRevert(abi.encodeWithSelector(IAgentPolicyRegistry.MissingPermission.selector), t, true, 1e6, 1);
        _expectSwapRevert(abi.encodeWithSelector(IAgentPolicyRegistry.MissingPermission.selector), t, false, 1e18, 1);
    }

    function test_PausedAndDeadline() public {
        LaunchToken t = toks[0];
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), true);
        _expectSwapRevert(abi.encodeWithSelector(IAgentPolicyRegistry.Paused.selector), t, true, 1e6, 1);
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), false);
        uint256 late = _now() + 121;
        vm.prank(agentKey);
        vm.expectRevert(IAgentPolicyRegistry.DeadlineOutOfRange.selector);
        account.swapExactIn(address(t), true, 1e6, 1, late);
    }

    // ---------------------------------------------------------------- caps

    function test_BuyCaps() public {
        LaunchToken t = toks[0];
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 100e6), t, true, 100e6 + 1, 1);
        _swap(t, true, 60e6, 1);
        _expectSwapRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.TokenCapExceeded.selector, 40e6), t, true, 41e6, 1
        );
        _swap(t, true, 40e6, 1);
        assertEq(registry.tokenSpent(address(account), address(t)), 100e6);

        Policy memory p = _policy();
        p.periodSpendCap = 150e6;
        _narrow(p);
        _swap(toks[1], true, 50e6, 1);
        _expectSwapRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 0), toks[1], true, 1e6, 1
        );
    }

    function test_AllowlistBlocksPoolBuysNotSells() public {
        LaunchToken t = toks[1];
        uint256 held = _swap(t, true, 10e6, 1);
        Policy memory p = _policy();
        p.allowlistOnly = true;
        _narrow(p);
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.TokenNotAllowed.selector), t, true, 1e6, 1);
        _swap(t, false, held, 1);
        assertEq(t.balanceOf(address(account)), 0);
    }

    function test_SellCapsAreValuedAtCostNotProceeds() public {
        LaunchToken t = toks[0];
        uint256 held = _swap(t, true, 100e6, 1);
        Policy memory p = _policy();
        p.maxTradeUsdc = 50e6;
        _narrow(p);
        // Valued at cost (100 USDC), not at its proceeds (less after fees and impact).
        _expectSwapRevert(abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 50e6), t, false, held, 1);
        p.periodSellCap = 30e6;
        _narrow(p);
        _expectSwapRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, 30e6), t, false, held / 2, 1
        );
        _swap(t, false, held * 3 / 10, 1);
        (, uint64 sold,) = _usage();
        assertEq(sold, _recordedValueAfterCut(held, held * 3 / 10));
    }

    /// @dev The value the account charged for `sold` of a single 100 USDC lot of `held`.
    function _recordedValueAfterCut(uint256 held, uint256 sold) internal pure returns (uint256) {
        uint256 v = Math.mulDiv(sold, 100e6, held, Math.Rounding.Ceil);
        uint256 hw = Math.mulDiv(100e6, 1e36, held, Math.Rounding.Ceil);
        uint256 hv = Math.mulDiv(sold, hw, 1e36);
        return hv > v ? hv : v;
    }

    function test_StrangerTokensSellAtProceedsProRataAndGiveNoBuyHeadroom() public {
        for (uint256 i; i < 2; ++i) {
            LaunchToken t = toks[i];
            uint256 held = _swap(t, true, 20e6, 1);
            uint256 extra = held + 123;
            _gift(t, extra);
            (uint64 hsBefore,,,) = registry.headroom(address(account));
            (, uint64 sold0,) = _usage();
            uint256 recordedValue = _recordedValue(address(t), held);
            uint256 total = held + extra;
            uint256 bal = address(account).balance;
            _swap(t, false, total, 1);
            uint256 receivedWei = address(account).balance - bal;
            uint256 expected =
                recordedValue + Math.ceilDiv(Math.mulDiv(receivedWei, extra, total, Math.Rounding.Ceil), 1e12);
            (, uint64 sold1,) = _usage();
            assertEq(sold1 - sold0, expected, "recorded at cost plus excess at its share of proceeds");
            (uint128 cost, uint128 tokens,) = account.basis(address(t));
            assertEq(cost, 0);
            assertEq(tokens, 0);
            (uint64 hsAfter,,,) = registry.headroom(address(account));
            assertEq(hsAfter, hsBefore, "no buy headroom from proceeds");
        }
    }

    function test_SellOfOnlyStrangerTokensWorks() public {
        LaunchToken t = toks[1];
        _gift(t, 500_000e18);
        uint256 out = _quote(t, false, 500_000e18);
        assertEq(_swap(t, false, 500_000e18, out), out);
        (uint64 spent, uint64 sold,) = _usage();
        assertEq(spent, 0);
        assertEq(sold, out, "valued at the measured proceeds");
    }

    // ---------------------------------------------------------------- fuzz: units

    function testFuzz_PoolUnitsRoundTheSafeWay(bool below, uint256 usdcIn, uint256 sellAmt) public {
        LaunchToken t = toks[below ? 0 : 1];
        usdcIn = bound(usdcIn, 100, 100e6);
        uint256 bal0 = address(account).balance;
        uint256 got = _swap(t, true, usdcIn, 1);
        assertEq(bal0 - address(account).balance, usdcIn * 1e12, "buy pulls exactly the usdc6 input");
        (uint64 spent,,) = _usage();
        assertEq(spent, usdcIn);
        (uint128 cost, uint128 tokens,) = account.basis(address(t));
        assertEq(cost, usdcIn);
        assertEq(tokens, got);

        // Sell an amount not a multiple of 1e12; proceeds round down, value rounds up.
        sellAmt = bound(sellAmt, 1, got);
        uint256 value = _recordedValue(address(t), sellAmt);
        uint256 out;
        try this.quoteSell(t, sellAmt) returns (uint256 q) {
            out = q;
        } catch {
            return;
        }
        if (out == 0) return;
        uint256 bal1 = address(account).balance;
        vm.prank(agentKey);
        try account.swapExactIn(address(t), false, sellAmt, 1, _dl()) returns (uint256 usdcOut) {
            uint256 deltaWei = address(account).balance - bal1;
            assertEq(usdcOut, deltaWei / 1e12, "proceeds round down");
            (, uint64 sold,) = _usage();
            assertEq(sold, value);
            assertGe(value * 1e12, Math.mulDiv(sellAmt, usdcIn * 1e12, got), "value covers the cost it removes");
        } catch (bytes memory err) {
            // A dust sell may quote below 1 usdc6 and fail the router's minimum.
            assertEq(bytes4(err), IV4Router.V4TooLittleReceived.selector);
        }
    }

    /// @dev External so the fuzz test can catch a quote revert.
    function quoteSell(LaunchToken t, uint256 amount) external returns (uint256) {
        return _quote(t, false, amount);
    }
}
