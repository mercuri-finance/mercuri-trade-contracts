// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {CreateParams} from "@mercuri/launch/libraries/LaunchTypes.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/agents/interfaces/IAgentPolicyRegistry.sol";
import {
    Policy,
    InitParams,
    LaunchRequest,
    P_ALL,
    P_LAUNCH,
    P_CLAIM,
    P_SWEEP_TO_OWNER,
    ACTION_LAUNCH,
    ACTION_CLAIM,
    ACTION_SWEEP
} from "../../src/agents/AgentTypes.sol";

/// @dev Task 4: agent launches, creator-fee claims and sweeps to the owner (spec section 4.6).
contract AgentLaunchTest is AgentFixture {
    AgentAccount internal account;

    function setUp() public override {
        super.setUp();
        account = _account();
        vm.deal(address(account), 10_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _pid() internal view returns (uint64) {
        return uint64(_now() / 1 days);
    }

    function _req(bytes32 salt, uint256 initialBuyUsdc) internal view returns (LaunchRequest memory r) {
        r.name = "Agent Token";
        r.symbol = "AGT";
        r.metadataURI = "https://example.invalid/agent.json";
        r.salt = salt;
        r.expectedConfigHash = factory.configHash();
        r.initialBuyUsdc = initialBuyUsdc;
        r.minTokensOut = initialBuyUsdc == 0 ? 0 : 1;
    }

    function _launch(bytes32 salt, uint256 initialBuyUsdc) internal returns (address token, address curve) {
        LaunchRequest memory r = _req(salt, initialBuyUsdc);
        vm.prank(agentKey);
        return account.launch(r);
    }

    function _expectLaunchRevert(bytes memory err, LaunchRequest memory r) internal {
        vm.prank(agentKey);
        vm.expectRevert(err);
        account.launch(r);
    }

    function _narrow(Policy memory p) internal {
        vm.prank(accountOwner);
        assertEq(registry.setPolicy(address(account), p), 0, "narrowing only");
    }

    function _dropPermission(uint16 bit) internal {
        uint40 exp = registry.agent(address(account), agentKey).expiresAt;
        vm.prank(accountOwner);
        assertEq(registry.setAgent(address(account), agentKey, exp, P_ALL & ~bit), 0, "narrowing only");
    }

    function _launches() internal view returns (uint16 launches) {
        (,,,, launches) = registry.usage(address(account));
    }

    function _spent() internal view returns (uint64 spent) {
        (, spent,,,) = registry.usage(address(account));
    }

    function _feeUsdc() internal view returns (uint256) {
        return Math.ceilDiv(cfg.launchFee, 1e12);
    }

    // ---------------------------------------------------------------- launch

    function test_LaunchCreatorIsTheAccount() public {
        (address token, address curve) = _launch(bytes32(uint256(1)), 0);
        assertEq(factory.curveOf(token), curve);
        IFeeManager.TokenInfo memory info = feeManager.tokenInfo(token);
        assertEq(info.creator, address(account), "creator is the account");
        assertEq(info.curve, curve);
        assertEq(LaunchToken(token).name(), "Agent Token");
        assertEq(LaunchToken(token).symbol(), "AGT");
    }

    function test_LaunchAddressesMatchThePredictionForTheAccount() public {
        LaunchRequest memory r = _req(bytes32(uint256(7)), 0);
        (address predictedToken, address predictedCurve) = factory.computeAddresses(address(account), _cp(r));
        vm.prank(agentKey);
        (address token, address curve) = account.launch(r);
        assertEq(token, predictedToken);
        assertEq(curve, predictedCurve);
    }

    function test_LaunchUsesTheAccountsReferrer() public {
        uint256 refBefore = feeManager.balances(referrer);
        (address token,) = _launch(bytes32(uint256(1)), 20e6);
        assertEq(feeManager.referrerOf(address(account)), referrer);
        assertGt(feeManager.balances(referrer), refBefore, "referrer earns its share of the initial buy");
        assertGt(LaunchToken(token).balanceOf(address(account)), 0);
    }

    function test_LaunchWithoutReferrerPassesZero() public {
        InitParams memory p = _defaults();
        p.referrer = address(0);
        address owner2 = makeAddr("owner two");
        AgentAccount acct = _account(owner2, bytes32(0), p);
        vm.deal(address(acct), 1_000e18);
        uint256 refBefore = feeManager.balances(referrer);
        LaunchRequest memory r = _req(bytes32(uint256(1)), 20e6);
        vm.prank(agentKey);
        acct.launch(r);
        assertEq(feeManager.referrerOf(address(acct)), address(0));
        assertEq(feeManager.balances(referrer), refBefore);
    }

    function test_LaunchInitialBuyTokensLandInAccountAndRecordBasis() public {
        uint256 bal0 = address(account).balance;
        bytes32 salt = bytes32(uint256(1));
        LaunchRequest memory r = _req(salt, 20e6);
        (address predicted,) = factory.computeAddresses(address(account), _cp(r));

        vm.expectEmit(true, false, true, false, address(account));
        emit IAgentAccount.AgentAction(agentKey, ACTION_LAUNCH, predicted, 0, 0, 0, 0, 0);
        vm.prank(agentKey);
        (address token,) = account.launch(r);

        uint256 held = LaunchToken(token).balanceOf(address(account));
        assertGt(held, 0, "initial-buy tokens land in the account");
        uint256 spent = Math.ceilDiv(bal0 - address(account).balance, 1e12);
        assertEq(spent, 21e6, "launch fee plus initial buy");
        (uint128 cost, uint128 tokens, uint256 hw) = account.basis(token);
        assertEq(cost, spent - _feeUsdc(), "basis excludes the launch fee");
        assertEq(tokens, held);
        assertEq(hw, Math.mulDiv(cost, 1e36, tokens, Math.Rounding.Ceil));

        (uint64 pid, uint64 used,, uint32 actions, uint16 launches) = registry.usage(address(account));
        assertEq(pid, _pid());
        assertEq(used, spent);
        assertEq(actions, 1);
        assertEq(launches, 1);
        assertEq(registry.tokenSpent(address(account), token), spent, "per-token keyed by the new token");
    }

    function test_LaunchEventCarriesMeasuredValues() public {
        uint256 bal0 = address(account).balance;
        (address token,) = _launch(bytes32(uint256(1)), 20e6);
        uint256 held = LaunchToken(token).balanceOf(address(account));
        uint256 spent = Math.ceilDiv(bal0 - address(account).balance, 1e12);
        (uint128 cost,,) = account.basis(token);
        // A second, identical launch on a fresh curve spends and receives the same; match its event exactly.
        bal0 = address(account).balance;
        LaunchRequest memory r = _req(bytes32(uint256(2)), 20e6);
        (address predicted,) = factory.computeAddresses(address(account), _cp(r));
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentAction(agentKey, ACTION_LAUNCH, predicted, spent, 0, int256(held), cost, _pid());
        vm.prank(agentKey);
        account.launch(r);
        assertEq(Math.ceilDiv(bal0 - address(account).balance, 1e12), spent);
    }

    function test_LaunchWithoutInitialBuy() public {
        uint256 bal0 = address(account).balance;
        (address token,) = _launch(bytes32(uint256(1)), 0);
        assertEq(LaunchToken(token).balanceOf(address(account)), 0);
        assertEq(bal0 - address(account).balance, cfg.launchFee);
        (uint128 cost, uint128 tokens, uint256 hw) = account.basis(token);
        assertEq(cost, 0);
        assertEq(tokens, 0);
        assertEq(hw, 0);
        assertEq(_spent(), _feeUsdc(), "the fee is a spend");
        assertEq(_launches(), 1);
        assertEq(registry.tokenSpent(address(account), token), _feeUsdc());
    }

    function test_LaunchThenBuyKeepsHighWater() public {
        (address token,) = _launch(bytes32(uint256(1)), 20e6);
        (,, uint256 hw0) = account.basis(token);
        vm.roll(vm.getBlockNumber() + cfg.snipeBlocks);
        vm.prank(agentKey);
        account.buy(token, 30e6, 1, _now() + 60);
        (uint128 cost, uint128 tokens, uint256 hw1) = account.basis(token);
        assertEq(cost, 20e6 + 30e6, "launch basis and buy basis add up");
        assertEq(hw1, Math.mulDiv(cost, 1e36, tokens, Math.Rounding.Ceil));
        assertGt(hw1, hw0, "a later buy at a higher price raises the high-water");
    }

    function test_LaunchLimit() public {
        for (uint256 i = 1; i <= 3; ++i) {
            _launch(bytes32(i), 0);
        }
        assertEq(_launches(), 3);
        _expectLaunchRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.LaunchLimit.selector), _req(bytes32(uint256(4)), 0)
        );

        vm.warp(_now() + 1 days);
        _launch(bytes32(uint256(4)), 0);
        assertEq(_launches(), 1, "the limit resets with the period");
    }

    function test_LaunchWrongConfigHashBubblesFactoryError() public {
        LaunchRequest memory r = _req(bytes32(uint256(1)), 10e6);
        r.expectedConfigHash = bytes32(uint256(123));
        _expectLaunchRevert(abi.encodeWithSelector(LaunchFactory.ConfigChanged.selector), r);
        r.expectedConfigHash = bytes32(0);
        _expectLaunchRevert(abi.encodeWithSelector(LaunchFactory.ConfigChanged.selector), r);
    }

    function test_LaunchSpendHitsPeriodSpendCap() public {
        Policy memory p = _defaultPolicy();
        p.periodSpendCap = 30e6;
        _narrow(p);
        _launch(bytes32(uint256(1)), 19e6); // 20e6 spent
        _expectLaunchRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 10e6),
            _req(bytes32(uint256(2)), 10e6)
        );
        _launch(bytes32(uint256(2)), 9e6); // exactly the cap
        assertEq(_spent(), 30e6);
    }

    function test_LaunchSpendHitsPerTokenCap() public {
        Policy memory p = _defaultPolicy();
        p.perTokenPeriodCap = 20e6;
        _narrow(p);
        _expectLaunchRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.TokenCapExceeded.selector, 20e6),
            _req(bytes32(uint256(1)), 20e6)
        );
        _launch(bytes32(uint256(1)), 19e6);
    }

    function test_LaunchTotalAboveMaxTradeReverts() public {
        // 100e6 initial buy plus the 1 USDC fee exceeds maxTradeUsdc = 100e6.
        _expectLaunchRevert(
            abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 100e6), _req(bytes32(uint256(1)), 100e6)
        );
        _launch(bytes32(uint256(1)), 99e6);
        assertEq(_spent(), 100e6);
    }

    function test_LaunchHugeInitialBuyRevertsTyped() public {
        _expectLaunchRevert(
            abi.encodeWithSelector(IAgentAccount.TradeTooLarge.selector, 100e6),
            _req(bytes32(uint256(1)), type(uint256).max)
        );
    }

    function test_LaunchNeedsPermission() public {
        _dropPermission(P_LAUNCH);
        _expectLaunchRevert(
            abi.encodeWithSelector(IAgentPolicyRegistry.MissingPermission.selector), _req(bytes32(uint256(1)), 0)
        );
    }

    function test_LaunchOnlyByAgent() public {
        LaunchRequest memory r = _req(bytes32(uint256(1)), 0);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.launch(r);
    }

    function testFuzz_LaunchBasisIsSpendMinusFee(uint256 initialBuyUsdc) public {
        initialBuyUsdc = bound(initialBuyUsdc, 0, 99e6);
        uint256 bal0 = address(account).balance;
        LaunchRequest memory r = _req(bytes32(uint256(1)), initialBuyUsdc);
        vm.prank(agentKey);
        (address token,) = account.launch(r);
        uint256 spent = Math.ceilDiv(bal0 - address(account).balance, 1e12);
        assertEq(_spent(), spent);
        assertLe(spent, initialBuyUsdc + _feeUsdc());
        (uint128 cost, uint128 tokens,) = account.basis(token);
        assertEq(tokens, LaunchToken(token).balanceOf(address(account)));
        if (tokens == 0) assertEq(cost, 0);
        else assertEq(cost, spent - _feeUsdc());
    }

    // ---------------------------------------------------------------- claim

    function _launchAndTrade() internal returns (address token) {
        (token,) = _launch(bytes32(uint256(1)), 0);
        BondingCurve curve = BondingCurve(factory.curveOf(token));
        vm.roll(vm.getBlockNumber() + cfg.snipeBlocks);
        vm.prank(bob);
        curve.buy{value: 500e18}(0, address(0), type(uint256).max);
        vm.startPrank(bob);
        LaunchToken(token).approve(address(curve), type(uint256).max);
        curve.sell(LaunchToken(token).balanceOf(bob) / 2, 0, address(0), type(uint256).max);
        vm.stopPrank();
    }

    function test_ClaimMovesCreatorFeesToTheAccountOnly() public {
        _launchAndTrade();
        uint256 owed = feeManager.balances(address(account));
        assertGt(owed, 0, "creator fees accrued to the account");
        uint256 acct0 = address(account).balance;
        uint256 agent0 = agentKey.balance;
        uint256 owner0 = accountOwner.balance;
        (,,, uint32 actions0,) = registry.usage(address(account));
        uint64 spent0 = _spent();

        vm.expectEmit(address(account));
        emit IAgentAccount.AgentAction(agentKey, ACTION_CLAIM, address(0), 0, owed / 1e12, 0, 0, _pid());
        vm.prank(agentKey);
        uint256 claimed = account.claimFees();

        assertEq(claimed, owed / 1e12);
        assertEq(feeManager.balances(address(account)), 0);
        assertEq(address(account).balance - acct0, owed, "every wei lands in the account");
        assertEq(agentKey.balance, agent0, "nothing to the agent");
        assertEq(accountOwner.balance, owner0, "nothing to the owner");
        (,,, uint32 actions1,) = registry.usage(address(account));
        assertEq(actions1, actions0 + 1);
        assertEq(_spent(), spent0, "a claim is not a spend");
    }

    function test_ClaimWithNothingOwedBubbles() public {
        vm.prank(agentKey);
        vm.expectRevert(IFeeManager.NothingToClaim.selector);
        account.claimFees();
    }

    function test_ClaimNeedsPermission() public {
        _launchAndTrade();
        _dropPermission(P_CLAIM);
        vm.prank(agentKey);
        vm.expectRevert(IAgentPolicyRegistry.MissingPermission.selector);
        account.claimFees();
    }

    // ---------------------------------------------------------------- sweep

    function test_SweepNativeToOwner() public {
        uint256 owner0 = accountOwner.balance;
        uint256 acct0 = address(account).balance;
        uint256 amount = 5e18 + 123; // not a multiple of 1e12
        vm.expectEmit(address(account));
        emit IAgentAccount.AccountWithdrawn(address(0), amount);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentAction(agentKey, ACTION_SWEEP, address(0), 0, 0, -int256(amount), 0, _pid());
        vm.prank(agentKey);
        account.sweepToOwner(address(0), amount);
        assertEq(accountOwner.balance - owner0, amount);
        assertEq(acct0 - address(account).balance, amount);
        assertEq(_spent(), 0, "a sweep is not a spend");
    }

    function test_SweepTokenToOwnerCutsBasisProRata() public {
        (address token,) = _launch(bytes32(uint256(1)), 20e6);
        uint256 held = LaunchToken(token).balanceOf(address(account));
        (uint128 cost0, uint128 tokens0, uint256 hw0) = account.basis(token);
        uint256 half = held / 2;

        vm.expectEmit(address(account));
        emit IAgentAccount.AgentAction(agentKey, ACTION_SWEEP, token, 0, 0, -int256(half), 0, _pid());
        vm.prank(agentKey);
        account.sweepToOwner(token, half);

        assertEq(LaunchToken(token).balanceOf(accountOwner), half);
        assertEq(LaunchToken(token).balanceOf(address(account)), held - half);
        uint256 cut = Math.mulDiv(tokens0, half, held, Math.Rounding.Ceil);
        (uint128 cost1, uint128 tokens1, uint256 hw1) = account.basis(token);
        assertEq(tokens1, tokens0 - cut);
        assertEq(cost1, cost0 - Math.mulDiv(cost0, cut, tokens0));
        assertEq(hw1, hw0, "high-water stays while the position is open");

        uint256 rest = held - half;
        vm.prank(agentKey);
        account.sweepToOwner(token, rest);
        (uint128 cost2, uint128 tokens2, uint256 hw2) = account.basis(token);
        assertEq(cost2, 0);
        assertEq(tokens2, 0);
        assertEq(hw2, 0);
        assertEq(LaunchToken(token).balanceOf(accountOwner), held);
    }

    function test_SweepFollowsOwnershipInRegistry() public {
        address newOwner = makeAddr("new owner");
        vm.prank(accountOwner);
        uint256 id = registry.transferOwnership(address(account), newOwner);
        vm.warp(_now() + 1 hours);
        vm.prank(newOwner);
        registry.acceptOwnership(address(account), id);
        assertEq(account.owner(), newOwner);
        uint256 old0 = accountOwner.balance;
        uint256 b0 = newOwner.balance;
        vm.prank(agentKey);
        account.sweepToOwner(address(0), 1e18);
        assertEq(newOwner.balance - b0, 1e18, "the sweep goes to the current owner");
        assertEq(accountOwner.balance, old0);
    }

    function test_SweepUnregisteredTokenReverts() public {
        vm.prank(agentKey);
        vm.expectRevert(IAgentAccount.TokenNotRegistered.selector);
        account.sweepToOwner(USDC, 1);
        vm.prank(agentKey);
        vm.expectRevert(IAgentAccount.TokenNotRegistered.selector);
        account.sweepToOwner(stranger, 1);
    }

    function test_SweepZeroAmountReverts() public {
        vm.prank(agentKey);
        vm.expectRevert(IAgentAccount.ZeroAmount.selector);
        account.sweepToOwner(address(0), 0);
    }

    function test_SweepNeedsPermission() public {
        _dropPermission(P_SWEEP_TO_OWNER);
        vm.prank(agentKey);
        vm.expectRevert(IAgentPolicyRegistry.MissingPermission.selector);
        account.sweepToOwner(address(0), 1e18);
        vm.prank(stranger);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.sweepToOwner(address(0), 1e18);
    }

    function testFuzz_SweepNativeAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, address(account).balance);
        uint256 owner0 = accountOwner.balance;
        vm.prank(agentKey);
        account.sweepToOwner(address(0), amount);
        assertEq(accountOwner.balance - owner0, amount);
    }

    // ---------------------------------------------------------------- utils

    /// @dev The factory parameters the account builds from `r`: creator the account, referrer the account's.
    function _cp(LaunchRequest memory r) internal view returns (CreateParams memory) {
        return CreateParams(r.name, r.symbol, r.metadataURI, address(account), account.referrer(), r.salt);
    }
}
