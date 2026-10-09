// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {AgentPolicyLib} from "../../src/agents/AgentPolicyLib.sol";
import {IAgentAccountFactory} from "../../src/agents/interfaces/IAgentAccountFactory.sol";
import {
    Policy,
    Agent,
    InitParams,
    P_ALL,
    P_BUY,
    P_SELL,
    MAX_AGENT_TTL,
    QUEUE_TTL,
    MAX_DELAY,
    Q_ADD_AGENT,
    Q_SET_AGENT,
    Q_POLICY,
    Q_ALLOW_TOKEN,
    Q_DELAY,
    Q_OWNER
} from "../../src/agents/AgentTypes.sol";

/// @dev Exposes the internal library helpers for direct checks.
contract PolicyLibHarness {
    function isNarrowing(Policy memory cur, Policy memory next) external pure returns (bool) {
        return AgentPolicyLib.isNarrowing(cur, next);
    }

    function tighten(Policy memory cur, Policy memory next) external pure returns (Policy memory) {
        return AgentPolicyLib.tighten(cur, next);
    }

    function merge(Policy memory cur, Policy memory snapshot, Policy memory target)
        external
        pure
        returns (Policy memory)
    {
        return AgentPolicyLib.merge(cur, snapshot, target);
    }
}

/// @dev An owner contract that tries to re-enter `withdraw` when paid.
contract ReentrantOwner {
    AgentAccount public account;
    bool public reentered;

    function create(IAgentAccountFactory factory, bytes32 salt, InitParams memory p) external {
        account = AgentAccount(payable(factory.createAccount(salt, p)));
    }

    function pull(uint256 amount) external {
        account.withdraw(address(0), amount);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            account.withdraw(address(0), 1);
        }
    }
}

contract AgentOwnerTest is AgentFixture {
    AgentAccount internal account;
    PolicyLibHarness internal lib;
    address internal newKey = makeAddr("new key");
    address internal newOwner = makeAddr("new owner");

    function setUp() public override {
        super.setUp();
        account = _account();
        lib = new PolicyLibHarness();
    }

    // ---------------------------------------------------------------- helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 t) internal {
        vm.warp(t);
    }

    function _eq(Policy memory a, Policy memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "policy");
    }

    function _setPolicy(Policy memory p) internal returns (uint256 id) {
        vm.prank(accountOwner);
        id = account.setPolicy(p);
    }

    function _eta(uint256 id) internal view returns (uint40 eta) {
        (, eta,,) = account.queued(id);
    }

    // ---------------------------------------------------------------- views and ids

    function test_InitialViews() public view {
        assertEq(account.referrer(), referrer);
        assertEq(account.periodSeconds(), 1 days);
        assertEq(account.increaseDelay(), 1 hours);
        assertEq(account.activeAgentCount(), 1);
        assertFalse(account.retired(agentKey));
        assertFalse(account.ownerPaused());
        assertEq(account.epoch(), 0);
        (uint8 kind, uint40 eta, uint64 ep, bytes memory payload) = account.queued(1);
        assertEq(kind, 0);
        assertEq(eta, 0);
        assertEq(ep, 0);
        assertEq(payload.length, 0);
    }

    function test_QueueIdsStartAtOne() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        assertEq(_setPolicy(p), 1);
        vm.prank(accountOwner);
        assertEq(account.addAgent(newKey, uint40(_now() + 30 days), P_BUY), 2);
        (uint8 kind, uint40 eta, uint64 ep, bytes memory payload) = account.queued(1);
        assertEq(kind, Q_POLICY);
        assertEq(eta, _now() + 1 hours);
        assertEq(ep, 0);
        (Policy memory target, Policy memory snap) = abi.decode(payload, (Policy, Policy));
        _eq(target, p);
        _eq(snap, _defaultPolicy());
        (kind,,,) = account.queued(2);
        assertEq(kind, Q_ADD_AGENT);
    }

    // ---------------------------------------------------------------- narrowing is immediate

    function test_PolicyNarrowingIsImmediateForEachField() public {
        // Start with room to tighten every field.
        InitParams memory ip = _defaults();
        ip.policy.maxSnipeBps = 500;
        AgentAccount acc = _account(accountOwner, bytes32(uint256(7)), ip);
        Policy memory p = ip.policy;
        for (uint8 f = 0; f <= 10; f++) {
            if (f == 0) p.maxTradeUsdc -= 1;
            if (f == 1) p.periodSpendCap -= 1;
            if (f == 2) p.perTokenPeriodCap -= 1;
            if (f == 3) p.periodSellCap -= 1;
            if (f == 4) p.maxActionsPerPeriod -= 1;
            if (f == 5) p.launchesPerPeriod -= 1;
            if (f == 6) p.maxPriceImpactBps -= 1;
            if (f == 7) p.maxSnipeBps -= 1;
            if (f == 8) p.minTokenAgeBlocks += 1;
            if (f == 9) p.maxDeadlineSeconds -= 1;
            if (f == 10) p.allowlistOnly = true;
            vm.expectEmit(address(acc));
            emit IAgentAccount.PolicyApplied(p);
            vm.prank(accountOwner);
            assertEq(acc.setPolicy(p), 0);
            _eq(acc.policy(), p);
        }
    }

    function test_AgentNarrowingIsImmediate() public {
        Agent memory before = account.agent(agentKey);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentActivated(agentKey, before.expiresAt - 1 days, P_BUY);
        vm.prank(accountOwner);
        assertEq(account.setAgent(agentKey, before.expiresAt - 1 days, P_BUY), 0);
        Agent memory a = account.agent(agentKey);
        assertTrue(a.active);
        assertEq(a.expiresAt, before.expiresAt - 1 days);
        assertEq(a.permissions, P_BUY);
    }

    function test_SetAgentOnInactiveReverts() public {
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.AgentNotActive.selector);
        account.setAgent(newKey, uint40(_now() + 1 days), P_BUY);
    }

    function test_RemoveTokenIsImmediateAddIsQueued() public {
        address token = makeAddr("token");
        vm.prank(accountOwner);
        uint256 id = account.setTokenAllowed(token, true);
        assertEq(id, 1);
        assertFalse(account.tokenAllowed(token));
        (uint8 kind,,,) = account.queued(id);
        assertEq(kind, Q_ALLOW_TOKEN);
        _warp(_eta(id));
        vm.expectEmit(address(account));
        emit IAgentAccount.TokenAllowed(token, true);
        account.executeQueued(id);
        assertTrue(account.tokenAllowed(token));
        vm.expectEmit(address(account));
        emit IAgentAccount.TokenAllowed(token, false);
        vm.prank(accountOwner);
        assertEq(account.setTokenAllowed(token, false), 0);
        assertFalse(account.tokenAllowed(token));
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.ZeroAddress.selector);
        account.setTokenAllowed(address(0), true);
    }

    // ---------------------------------------------------------------- widening is delayed

    function test_PolicyWideningQueuesAndExecutesAfterEta() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint40 eta = uint40(_now() + 1 hours);
        vm.expectEmit(address(account));
        emit IAgentAccount.PolicyQueued(1, eta, p);
        uint256 id = _setPolicy(p);
        _eq(account.policy(), _defaultPolicy());

        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.TooEarly.selector, eta));
        account.executeQueued(id);
        _warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.TooEarly.selector, eta));
        account.executeQueued(id);

        _warp(eta);
        vm.expectEmit(address(account));
        emit IAgentAccount.PolicyApplied(p);
        vm.prank(stranger);
        account.executeQueued(id);
        _eq(account.policy(), p);
        // Executed items are gone.
        (uint8 kind,,,) = account.queued(id);
        assertEq(kind, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.UnknownQueued.selector, id));
        account.executeQueued(id);
    }

    function test_QueuedItemExpiresSevenDaysAfterEta() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id1 = _setPolicy(p);
        p.maxTradeUsdc = 300e6;
        uint256 id2 = _setPolicy(p);
        uint40 eta = _eta(id1);
        _warp(eta + QUEUE_TTL + 1);
        vm.expectRevert(IAgentAccount.QueuedExpired.selector);
        account.executeQueued(id1);
        // The last executable second is ETA + 7 days.
        _warp(eta + QUEUE_TTL);
        account.executeQueued(id2);
        assertEq(account.policy().maxTradeUsdc, 300e6);
    }

    function test_AgentWideningQueues() public {
        Agent memory before = account.agent(agentKey);
        vm.prank(accountOwner);
        account.setAgent(agentKey, before.expiresAt, P_BUY);
        // Adding a permission back is a widening.
        uint40 eta = uint40(_now() + 1 hours);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentQueued(1, agentKey, before.expiresAt + 1, P_BUY | P_SELL, eta);
        vm.prank(accountOwner);
        uint256 id = account.setAgent(agentKey, before.expiresAt + 1, P_BUY | P_SELL);
        assertEq(id, 1);
        assertEq(account.agent(agentKey).permissions, P_BUY);
        (uint8 kind,,,) = account.queued(id);
        assertEq(kind, Q_SET_AGENT);
        _warp(eta);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentActivated(agentKey, before.expiresAt + 1, P_BUY | P_SELL);
        account.executeQueued(id);
        assertEq(account.agent(agentKey).permissions, P_BUY | P_SELL);
        assertEq(account.agent(agentKey).expiresAt, before.expiresAt + 1);
    }

    function test_SetAgentTighteningAfterQueueMakesItStale() public {
        Agent memory before = account.agent(agentKey);
        vm.prank(accountOwner);
        account.setAgent(agentKey, before.expiresAt, P_BUY);
        vm.prank(accountOwner);
        uint256 id = account.setAgent(agentKey, before.expiresAt, P_ALL);
        vm.prank(accountOwner);
        account.setAgent(agentKey, before.expiresAt - 1, P_BUY);
        _warp(_eta(id));
        vm.expectRevert(IAgentAccount.StaleQueued.selector);
        account.executeQueued(id);
        assertEq(account.agent(agentKey).permissions, P_BUY);
    }

    function test_AddAgentQueuesAndActivatesAfterEta() public {
        uint40 exp = uint40(_now() + 30 days);
        vm.prank(accountOwner);
        uint256 id = account.addAgent(newKey, exp, P_BUY);
        assertFalse(account.agent(newKey).active);
        assertEq(account.activeAgentCount(), 1);
        _warp(_eta(id));
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentActivated(newKey, exp, P_BUY);
        account.executeQueued(id);
        assertTrue(account.agent(newKey).active);
        assertEq(account.activeAgentCount(), 2);
    }

    function test_AddAgentChecksTerms() public {
        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentAccount.InvalidAgent.selector);
        account.addAgent(accountOwner, uint40(_now() + 1 days), P_BUY);
        vm.expectRevert(IAgentAccount.InvalidAgent.selector);
        account.addAgent(address(account), uint40(_now() + 1 days), P_BUY);
        vm.expectRevert(IAgentAccount.AgentExpiryOutOfRange.selector);
        account.addAgent(newKey, uint40(_now() + MAX_AGENT_TTL + 1), P_BUY);
        vm.expectRevert(IAgentAccount.InvalidPermissions.selector);
        account.addAgent(newKey, uint40(_now() + 1 days), 0);
        vm.expectRevert(IAgentAccount.AgentAlreadyActive.selector);
        account.addAgent(agentKey, uint40(_now() + 1 days), P_BUY);
        vm.stopPrank();
    }

    function test_AddAgentExpiryCheckedAtExecution() public {
        vm.prank(accountOwner);
        uint256 id = account.addAgent(newKey, uint40(_now() + 2 hours), P_BUY);
        _warp(_now() + 2 hours);
        vm.expectRevert(IAgentAccount.AgentExpiryOutOfRange.selector);
        account.executeQueued(id);
    }

    function test_PauseAgentsCancelsQueuedItems() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 idPolicy = _setPolicy(p);
        vm.prank(accountOwner);
        uint256 idAgent = account.addAgent(newKey, uint40(_now() + 30 days), P_BUY);

        vm.expectEmit(address(account));
        emit IAgentAccount.AgentsPaused(true);
        vm.prank(accountOwner);
        account.pauseAgents(true);
        assertTrue(account.ownerPaused());
        assertEq(account.epoch(), 1);

        _warp(_eta(idAgent));
        vm.expectEmit(address(account));
        emit IAgentAccount.QueuedCancelled(idPolicy);
        account.executeQueued(idPolicy);
        vm.expectEmit(address(account));
        emit IAgentAccount.QueuedCancelled(idAgent);
        account.executeQueued(idAgent);
        _eq(account.policy(), _defaultPolicy());
        assertFalse(account.agent(newKey).active);
        (uint8 kind,,,) = account.queued(idPolicy);
        assertEq(kind, 0);

        // Unpausing does not revive them; new items queue in the new epoch.
        vm.prank(accountOwner);
        account.pauseAgents(false);
        assertEq(account.epoch(), 1);
        uint256 id3 = _setPolicy(p);
        _warp(_eta(id3));
        account.executeQueued(id3);
        assertEq(account.policy().maxTradeUsdc, 200e6);
    }

    function test_TighteningAfterQueueSurvivesExecution() public {
        Policy memory wide = _defaultPolicy();
        wide.maxTradeUsdc = 500e6;
        wide.periodSpendCap = 1_000e6;
        wide.maxPriceImpactBps = 1_000;
        uint256 id = _setPolicy(wide);

        Policy memory tight = _defaultPolicy();
        tight.periodSpendCap = 300e6;
        tight.allowlistOnly = true;
        assertEq(_setPolicy(tight), 0);

        _warp(_eta(id));
        account.executeQueued(id);
        Policy memory got = account.policy();
        assertEq(got.maxTradeUsdc, 500e6, "untouched widening applies");
        assertEq(got.periodSpendCap, 300e6, "later tightening survives");
        assertEq(got.maxPriceImpactBps, 1_000);
        assertTrue(got.allowlistOnly, "later allowlist survives");
    }

    function test_MixedSetPolicyAppliesTighterNowAndQueuesRest() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 50e6; // tighter
        p.periodSpendCap = 1_000e6; // wider
        Policy memory now_ = _defaultPolicy();
        now_.maxTradeUsdc = 50e6;
        vm.expectEmit(address(account));
        emit IAgentAccount.PolicyApplied(now_);
        uint256 id = _setPolicy(p);
        assertEq(id, 1);
        _eq(account.policy(), now_);
        (,,, bytes memory payload) = account.queued(id);
        (Policy memory target, Policy memory snap) = abi.decode(payload, (Policy, Policy));
        _eq(target, p);
        _eq(snap, now_);
        _warp(_eta(id));
        account.executeQueued(id);
        _eq(account.policy(), p);
    }

    function test_PolicyAboveCeilingRevertsAtQueue() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 1_000e6 + 1;
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.BetaCeiling.selector, uint8(0)));
        account.setPolicy(p);
        p = _defaultPolicy();
        p.maxDeadlineSeconds = 0;
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.InvalidPolicy.selector, uint8(9)));
        account.setPolicy(p);
    }

    function test_NinthAgentFailsAtExecution() public {
        uint256[] memory ids = new uint256[](8);
        vm.startPrank(accountOwner);
        for (uint256 i = 0; i < 8; i++) {
            ids[i] = account.addAgent(address(uint160(0xA000 + i)), uint40(_now() + 30 days), P_BUY);
        }
        vm.stopPrank();
        _warp(_eta(ids[0]));
        for (uint256 i = 0; i < 7; i++) {
            account.executeQueued(ids[i]);
        }
        assertEq(account.activeAgentCount(), 8);
        vm.expectRevert(IAgentAccount.TooManyAgents.selector);
        account.executeQueued(ids[7]);
        // A revocation frees a slot.
        vm.prank(accountOwner);
        account.revokeAgent(agentKey);
        account.executeQueued(ids[7]);
        assertEq(account.activeAgentCount(), 8);
    }

    function test_RevokedAgentCannotBeReAdded() public {
        Agent memory a = account.agent(agentKey);
        vm.expectEmit(address(account));
        emit IAgentAccount.AgentRevoked(agentKey, a.expiresAt, a.permissions);
        vm.prank(accountOwner);
        account.revokeAgent(agentKey);
        assertTrue(account.retired(agentKey));
        assertFalse(account.agent(agentKey).active);
        assertEq(account.activeAgentCount(), 0);

        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentAccount.AgentRetired.selector);
        account.addAgent(agentKey, uint40(_now() + 1 days), P_BUY);
        vm.expectRevert(IAgentAccount.AgentNotActive.selector);
        account.revokeAgent(agentKey);
        vm.expectRevert(IAgentAccount.AgentNotActive.selector);
        account.revokeAgent(stranger);
        vm.stopPrank();
    }

    function test_RevokedAgentCannotBeReAddedViaQueuedAdd() public {
        vm.startPrank(accountOwner);
        uint256 id1 = account.addAgent(newKey, uint40(_now() + 30 days), P_BUY);
        uint256 id2 = account.addAgent(newKey, uint40(_now() + 30 days), P_ALL);
        vm.stopPrank();
        _warp(_eta(id1));
        account.executeQueued(id1);
        vm.prank(accountOwner);
        account.revokeAgent(newKey);
        vm.expectRevert(IAgentAccount.AgentRetired.selector);
        account.executeQueued(id2);
        assertFalse(account.agent(newKey).active);
    }

    function test_QueuedSetAgentDiesWithRevoke() public {
        Agent memory a = account.agent(agentKey);
        vm.prank(accountOwner);
        uint256 id = account.setAgent(agentKey, a.expiresAt + 1 days, P_ALL);
        vm.prank(accountOwner);
        account.revokeAgent(agentKey);
        _warp(_eta(id));
        vm.expectRevert(IAgentAccount.StaleQueued.selector);
        account.executeQueued(id);
    }

    function test_RotationRevokesImmediatelyAndQueuesNewKey() public {
        uint40 exp = uint40(_now() + 30 days);
        vm.prank(accountOwner);
        uint256 id = account.rotateAgent(agentKey, newKey, exp, P_BUY);
        assertEq(id, 1);
        assertTrue(account.retired(agentKey));
        assertFalse(account.agent(agentKey).active);
        assertFalse(account.agent(newKey).active);
        assertEq(account.activeAgentCount(), 0);
        _warp(_eta(id));
        account.executeQueued(id);
        assertTrue(account.agent(newKey).active);
        assertEq(account.activeAgentCount(), 1);

        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.AgentNotActive.selector);
        account.rotateAgent(agentKey, makeAddr("x"), exp, P_BUY);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.AgentRetired.selector);
        account.rotateAgent(newKey, newKey, exp, P_BUY);
    }

    function test_CancelQueued() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id = _setPolicy(p);
        vm.expectEmit(address(account));
        emit IAgentAccount.QueuedCancelled(id);
        vm.prank(accountOwner);
        account.cancelQueued(id);
        _warp(_now() + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.UnknownQueued.selector, id));
        account.executeQueued(id);
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.UnknownQueued.selector, id));
        account.cancelQueued(id);
    }

    // ---------------------------------------------------------------- ownership

    function test_OnlyQueuedNewOwnerAcceptsAndAcceptingCancelsOldQueue() public {
        uint40 eta = uint40(_now() + 1 hours);
        vm.expectEmit(address(account));
        emit IAgentAccount.OwnershipQueued(1, newOwner, eta);
        vm.prank(accountOwner);
        uint256 idOwner = account.transferOwnership(newOwner);
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 idPolicy = _setPolicy(p);
        (uint8 kind,,,) = account.queued(idOwner);
        assertEq(kind, Q_OWNER);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.TooEarly.selector, eta));
        account.acceptOwnership(idOwner);

        _warp(eta);
        vm.prank(stranger);
        vm.expectRevert(IAgentAccount.NotPendingOwner.selector);
        account.acceptOwnership(idOwner);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.NotPendingOwner.selector);
        account.acceptOwnership(idOwner);
        vm.prank(newOwner);
        vm.expectRevert(IAgentAccount.NotPendingOwner.selector);
        account.acceptOwnership(idPolicy);
        vm.expectRevert(IAgentAccount.AcceptRequired.selector);
        account.executeQueued(idOwner);

        vm.expectEmit(address(account));
        emit IAgentAccount.OwnershipTransferred(accountOwner, newOwner);
        vm.prank(newOwner);
        account.acceptOwnership(idOwner);
        assertEq(account.owner(), newOwner);
        assertEq(account.epoch(), 1);

        vm.expectEmit(address(account));
        emit IAgentAccount.QueuedCancelled(idPolicy);
        account.executeQueued(idPolicy);
        _eq(account.policy(), _defaultPolicy());

        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.NotOwner.selector);
        account.pauseAgents(true);
        vm.prank(newOwner);
        account.pauseAgents(true);
    }

    function test_AcceptOwnershipExpires() public {
        vm.prank(accountOwner);
        uint256 id = account.transferOwnership(newOwner);
        _warp(_eta(id) + QUEUE_TTL + 1);
        vm.prank(newOwner);
        vm.expectRevert(IAgentAccount.QueuedExpired.selector);
        account.acceptOwnership(id);
    }

    function test_AcceptOwnershipAfterPauseIsCancelled() public {
        vm.prank(accountOwner);
        uint256 id = account.transferOwnership(newOwner);
        vm.prank(accountOwner);
        account.pauseAgents(true);
        _warp(_eta(id));
        vm.prank(newOwner);
        vm.expectRevert(IAgentAccount.StaleQueued.selector);
        account.acceptOwnership(id);
        assertEq(account.owner(), accountOwner);
    }

    function test_AcceptingAgentLosesAgentRole() public {
        vm.prank(accountOwner);
        uint256 id = account.transferOwnership(agentKey);
        _warp(_eta(id));
        vm.prank(agentKey);
        account.acceptOwnership(id);
        assertEq(account.owner(), agentKey);
        assertFalse(account.agent(agentKey).active);
        assertTrue(account.retired(agentKey));
        assertEq(account.activeAgentCount(), 0);
    }

    function test_TransferOwnershipBadTargets() public {
        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentAccount.InvalidOwner.selector);
        account.transferOwnership(address(0));
        vm.expectRevert(IAgentAccount.InvalidOwner.selector);
        account.transferOwnership(address(account));
        vm.expectRevert(IAgentAccount.InvalidOwner.selector);
        account.transferOwnership(accountOwner);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- delay

    function test_DelayRaiseIsImmediateLowerIsQueued() public {
        vm.expectEmit(address(account));
        emit IAgentAccount.IncreaseDelaySet(2 hours);
        vm.prank(accountOwner);
        assertEq(account.setIncreaseDelay(2 hours), 0);
        assertEq(account.increaseDelay(), 2 hours);

        vm.prank(accountOwner);
        uint256 id = account.setIncreaseDelay(30 minutes);
        assertEq(id, 1);
        assertEq(account.increaseDelay(), 2 hours);
        (uint8 kind, uint40 eta,,) = account.queued(id);
        assertEq(kind, Q_DELAY);
        assertEq(eta, _now() + 2 hours, "lowering waits the current delay");
        _warp(eta);
        account.executeQueued(id);
        assertEq(account.increaseDelay(), 30 minutes);

        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.DelayOutOfRange.selector);
        account.setIncreaseDelay(uint32(MAX_DELAY + 1));
    }

    function test_DelayRaiseAfterQueuedLowerSurvives() public {
        vm.prank(accountOwner);
        uint256 id = account.setIncreaseDelay(0);
        vm.prank(accountOwner);
        account.setIncreaseDelay(3 days);
        _warp(_eta(id));
        vm.expectRevert(IAgentAccount.StaleQueued.selector);
        account.executeQueued(id);
        assertEq(account.increaseDelay(), 3 days);
    }

    function test_ZeroDelayExecutesInTheSameBlock() public {
        InitParams memory ip = _defaults();
        ip.increaseDelay = 0;
        AgentAccount acc = _account(accountOwner, bytes32(uint256(9)), ip);
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        vm.prank(accountOwner);
        uint256 id = acc.setPolicy(p);
        (, uint40 eta,,) = acc.queued(id);
        assertEq(eta, _now());
        acc.executeQueued(id);
        assertEq(acc.policy().maxTradeUsdc, 200e6);
        vm.prank(accountOwner);
        id = acc.addAgent(newKey, uint40(_now() + 1 days), P_BUY);
        acc.executeQueued(id);
        assertTrue(acc.agent(newKey).active);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_WithdrawPaysOnlyTheOwner() public {
        ERC20Mock token = new ERC20Mock();
        token.mint(address(account), 1_000e18);
        vm.deal(address(account), 5e18);
        uint256 ownerBal = accountOwner.balance;

        vm.expectEmit(address(account));
        emit IAgentAccount.Withdrawn(address(0), 2e18);
        vm.prank(accountOwner);
        account.withdraw(address(0), 2e18);
        assertEq(accountOwner.balance, ownerBal + 2e18);
        assertEq(address(account).balance, 3e18);

        vm.expectEmit(address(account));
        emit IAgentAccount.Withdrawn(address(token), 400e18);
        vm.prank(accountOwner);
        account.withdraw(address(token), 400e18);
        assertEq(token.balanceOf(accountOwner), 400e18);
        assertEq(token.balanceOf(address(account)), 600e18);

        vm.prank(accountOwner);
        vm.expectRevert();
        account.withdraw(address(0), 4e18);
    }

    function test_WithdrawManyPaysFullBalancesToOwner() public {
        ERC20Mock t1 = new ERC20Mock();
        ERC20Mock t2 = new ERC20Mock();
        t1.mint(address(account), 7e18);
        t2.mint(address(account), 9e18);
        vm.deal(address(account), 3e18 + 1);
        uint256 ownerBal = accountOwner.balance;

        address[] memory tokens = new address[](4);
        tokens[0] = address(t1);
        tokens[1] = address(0);
        tokens[2] = address(t2);
        tokens[3] = address(t1); // a repeat finds a zero balance
        vm.expectEmit(address(account));
        emit IAgentAccount.Withdrawn(address(t1), 7e18);
        vm.expectEmit(address(account));
        emit IAgentAccount.Withdrawn(address(0), 3e18 + 1);
        vm.expectEmit(address(account));
        emit IAgentAccount.Withdrawn(address(t2), 9e18);
        vm.prank(accountOwner);
        account.withdrawMany(tokens);
        assertEq(t1.balanceOf(accountOwner), 7e18);
        assertEq(t2.balanceOf(accountOwner), 9e18);
        assertEq(accountOwner.balance, ownerBal + 3e18 + 1);
        assertEq(address(account).balance, 0);
        assertEq(t1.balanceOf(address(account)), 0);
    }

    function test_WithdrawWorksWhileAgentsPaused() public {
        vm.deal(address(account), 1e18);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        vm.prank(accountOwner);
        account.pauseAgents(true);
        vm.prank(accountOwner);
        account.withdraw(address(0), 1e18);
        assertEq(address(account).balance, 0);
    }

    function test_WithdrawIsNotReentrant() public {
        ReentrantOwner ro = new ReentrantOwner();
        InitParams memory ip = _defaults();
        ro.create(agentFactory, bytes32(0), ip);
        AgentAccount acc = ro.account();
        assertEq(acc.owner(), address(ro));
        vm.deal(address(acc), 2e18);
        vm.expectRevert(IAgentAccount.NativeTransferFailed.selector);
        ro.pull(1e18);
        assertEq(address(acc).balance, 2e18);
    }

    // ---------------------------------------------------------------- access control

    function test_NonOwnersRevertOnEveryOwnerFunction() public {
        address[] memory callers = new address[](3);
        callers[0] = stranger;
        callers[1] = agentKey;
        callers[2] = address(agentFactory);
        address[] memory tokens = new address[](1);
        uint40 exp = uint40(_now() + 1 days);
        Policy memory p = _defaultPolicy();
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.addAgent(newKey, exp, P_BUY);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.setAgent(agentKey, exp, P_BUY);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.revokeAgent(agentKey);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.rotateAgent(agentKey, newKey, exp, P_BUY);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.setPolicy(p);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.setTokenAllowed(stranger, false);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.setIncreaseDelay(2 hours);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.transferOwnership(callers[i]);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.cancelQueued(1);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.pauseAgents(true);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.withdraw(address(0), 0);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.withdrawMany(tokens);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- library fuzz

    function testFuzz_IsNarrowingMatchesPerFieldRule(Policy memory cur, Policy memory next) public view {
        bool expected = next.maxTradeUsdc <= cur.maxTradeUsdc && next.periodSpendCap <= cur.periodSpendCap
            && next.perTokenPeriodCap <= cur.perTokenPeriodCap && next.periodSellCap <= cur.periodSellCap
            && next.maxActionsPerPeriod <= cur.maxActionsPerPeriod && next.launchesPerPeriod <= cur.launchesPerPeriod
            && next.maxPriceImpactBps <= cur.maxPriceImpactBps && next.maxSnipeBps <= cur.maxSnipeBps
            && next.minTokenAgeBlocks >= cur.minTokenAgeBlocks && next.maxDeadlineSeconds <= cur.maxDeadlineSeconds
            && (next.allowlistOnly || !cur.allowlistOnly);
        assertEq(lib.isNarrowing(cur, next), expected);
        // `tighten` keeps exactly the narrowing fields of `next`, so its result is always narrowing.
        Policy memory t = lib.tighten(cur, next);
        assertTrue(lib.isNarrowing(cur, t));
        assertEq(keccak256(abi.encode(t)) == keccak256(abi.encode(next)), expected);
    }

    /// @dev Field-by-field differences on single fields, so the fuzzer hits the equal and one-off cases.
    function testFuzz_IsNarrowingSingleField(uint8 field, bool up) public view {
        field = uint8(bound(field, 0, 10));
        Policy memory cur = _defaultPolicy();
        cur.maxSnipeBps = 100;
        cur.minTokenAgeBlocks = 5;
        Policy memory next = abi.decode(abi.encode(cur), (Policy));
        assertTrue(lib.isNarrowing(cur, next));
        if (field == 0) next.maxTradeUsdc = up ? cur.maxTradeUsdc + 1 : cur.maxTradeUsdc - 1;
        if (field == 1) next.periodSpendCap = up ? cur.periodSpendCap + 1 : cur.periodSpendCap - 1;
        if (field == 2) next.perTokenPeriodCap = up ? cur.perTokenPeriodCap + 1 : cur.perTokenPeriodCap - 1;
        if (field == 3) next.periodSellCap = up ? cur.periodSellCap + 1 : cur.periodSellCap - 1;
        if (field == 4) next.maxActionsPerPeriod = up ? cur.maxActionsPerPeriod + 1 : cur.maxActionsPerPeriod - 1;
        if (field == 5) next.launchesPerPeriod = up ? cur.launchesPerPeriod + 1 : cur.launchesPerPeriod - 1;
        if (field == 6) next.maxPriceImpactBps = up ? cur.maxPriceImpactBps + 1 : cur.maxPriceImpactBps - 1;
        if (field == 7) next.maxSnipeBps = up ? cur.maxSnipeBps + 1 : cur.maxSnipeBps - 1;
        if (field == 8) next.minTokenAgeBlocks = up ? cur.minTokenAgeBlocks + 1 : cur.minTokenAgeBlocks - 1;
        if (field == 9) next.maxDeadlineSeconds = up ? cur.maxDeadlineSeconds + 1 : cur.maxDeadlineSeconds - 1;
        if (field == 10) {
            cur.allowlistOnly = up;
            next.allowlistOnly = !up;
        }
        // Up is tighter only for the token-age floor; for the allowlist, true -> false (up) is the widening.
        bool narrowing = field == 8 ? up : !up;
        assertEq(lib.isNarrowing(cur, next), narrowing);
    }

    function testFuzz_MergeKeepsChangedFields(Policy memory cur, Policy memory snap, Policy memory target) public view {
        Policy memory m = lib.merge(cur, snap, target);
        assertEq(m.maxTradeUsdc, cur.maxTradeUsdc == snap.maxTradeUsdc ? target.maxTradeUsdc : cur.maxTradeUsdc);
        assertEq(
            m.periodSpendCap, cur.periodSpendCap == snap.periodSpendCap ? target.periodSpendCap : cur.periodSpendCap
        );
        assertEq(
            m.perTokenPeriodCap,
            cur.perTokenPeriodCap == snap.perTokenPeriodCap ? target.perTokenPeriodCap : cur.perTokenPeriodCap
        );
        assertEq(m.periodSellCap, cur.periodSellCap == snap.periodSellCap ? target.periodSellCap : cur.periodSellCap);
        assertEq(
            m.maxActionsPerPeriod,
            cur.maxActionsPerPeriod == snap.maxActionsPerPeriod ? target.maxActionsPerPeriod : cur.maxActionsPerPeriod
        );
        assertEq(
            m.launchesPerPeriod,
            cur.launchesPerPeriod == snap.launchesPerPeriod ? target.launchesPerPeriod : cur.launchesPerPeriod
        );
        assertEq(
            m.maxPriceImpactBps,
            cur.maxPriceImpactBps == snap.maxPriceImpactBps ? target.maxPriceImpactBps : cur.maxPriceImpactBps
        );
        assertEq(m.maxSnipeBps, cur.maxSnipeBps == snap.maxSnipeBps ? target.maxSnipeBps : cur.maxSnipeBps);
        assertEq(
            m.minTokenAgeBlocks,
            cur.minTokenAgeBlocks == snap.minTokenAgeBlocks ? target.minTokenAgeBlocks : cur.minTokenAgeBlocks
        );
        assertEq(
            m.maxDeadlineSeconds,
            cur.maxDeadlineSeconds == snap.maxDeadlineSeconds ? target.maxDeadlineSeconds : cur.maxDeadlineSeconds
        );
        assertEq(m.allowlistOnly, cur.allowlistOnly == snap.allowlistOnly ? target.allowlistOnly : cur.allowlistOnly);
    }

    /// @dev Review focus 2 end to end: any tightening after a queued widening survives its execution.
    function testFuzz_QueuedWideningNeverUndoesLaterTightening(uint64 wideTrade, uint64 tightTrade, uint16 tightImpact)
        public
    {
        wideTrade = uint64(bound(wideTrade, 100e6 + 1, 1_000e6));
        tightTrade = uint64(bound(tightTrade, 0, 100e6 - 1));
        tightImpact = uint16(bound(tightImpact, 0, 299));
        Policy memory wide = _defaultPolicy();
        wide.maxTradeUsdc = wideTrade;
        wide.maxPriceImpactBps = 2_000;
        uint256 id = _setPolicy(wide);
        Policy memory tight = _defaultPolicy();
        tight.maxTradeUsdc = tightTrade;
        tight.maxPriceImpactBps = tightImpact;
        _setPolicy(tight);
        _warp(_eta(id));
        account.executeQueued(id);
        assertEq(account.policy().maxTradeUsdc, tightTrade);
        assertEq(account.policy().maxPriceImpactBps, tightImpact);
    }
}
