// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/agents/interfaces/IAgentPolicyRegistry.sol";
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

    function merge(Policy memory cur, Policy memory target, uint64[11] memory lastWrite, uint64 seq)
        external
        pure
        returns (Policy memory)
    {
        return AgentPolicyLib.merge(cur, target, lastWrite, seq);
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
        id = registry.setPolicy(address(account), p);
    }

    function _eta(uint256 id) internal view returns (uint40 eta) {
        (, eta,,,) = registry.queued(address(account), id);
    }

    // ---------------------------------------------------------------- views and ids

    function test_InitialViews() public view {
        assertEq(account.referrer(), referrer);
        assertEq(registry.periodSeconds(address(account)), 1 days);
        assertEq(registry.increaseDelay(address(account)), 1 hours);
        assertEq(registry.activeAgentCount(address(account)), 1);
        assertFalse(registry.retired(address(account), agentKey));
        assertFalse(registry.ownerPaused(address(account)));
        assertEq(registry.epoch(address(account)), 0);
        (uint8 kind, uint40 eta, uint64 ep,, bytes memory payload) = registry.queued(address(account), 1);
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
        assertEq(registry.addAgent(address(account), newKey, uint40(_now() + 30 days), P_BUY), 2);
        (uint8 kind, uint40 eta, uint64 ep,, bytes memory payload) = registry.queued(address(account), 1);
        assertEq(kind, Q_POLICY);
        assertEq(eta, _now() + 1 hours);
        assertEq(ep, 0);
        _eq(abi.decode(payload, (Policy)), p);
        (kind,,,,) = registry.queued(address(account), 2);
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
            vm.expectEmit(address(registry));
            emit IAgentPolicyRegistry.PolicyApplied(address(acc), p);
            vm.prank(accountOwner);
            assertEq(registry.setPolicy(address(acc), p), 0);
            _eq(registry.policy(address(acc)), p);
        }
    }

    function test_AgentNarrowingIsImmediate() public {
        Agent memory before = registry.agent(address(account), agentKey);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentActivated(address(account), agentKey, before.expiresAt - 1 days, P_BUY);
        vm.prank(accountOwner);
        assertEq(registry.setAgent(address(account), agentKey, before.expiresAt - 1 days, P_BUY), 0);
        Agent memory a = registry.agent(address(account), agentKey);
        assertTrue(a.active);
        assertEq(a.expiresAt, before.expiresAt - 1 days);
        assertEq(a.permissions, P_BUY);
    }

    function test_SetAgentOnInactiveReverts() public {
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.AgentNotActive.selector);
        registry.setAgent(address(account), newKey, uint40(_now() + 1 days), P_BUY);
    }

    function test_RemoveTokenIsImmediateAddIsQueued() public {
        address token = makeAddr("token");
        vm.prank(accountOwner);
        uint256 id = registry.setTokenAllowed(address(account), token, true);
        assertEq(id, 1);
        assertFalse(registry.tokenAllowed(address(account), token));
        (uint8 kind,,,,) = registry.queued(address(account), id);
        assertEq(kind, Q_ALLOW_TOKEN);
        _warp(_eta(id));
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.TokenAllowed(address(account), token, true);
        registry.executeQueued(address(account), id);
        assertTrue(registry.tokenAllowed(address(account), token));
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.TokenAllowed(address(account), token, false);
        vm.prank(accountOwner);
        assertEq(registry.setTokenAllowed(address(account), token, false), 0);
        assertFalse(registry.tokenAllowed(address(account), token));
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.ZeroAddress.selector);
        registry.setTokenAllowed(address(account), address(0), true);
    }

    // ---------------------------------------------------------------- widening is delayed

    function test_PolicyWideningQueuesAndExecutesAfterEta() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint40 eta = uint40(_now() + 1 hours);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.PolicyQueued(address(account), 1, eta, p);
        uint256 id = _setPolicy(p);
        _eq(registry.policy(address(account)), _defaultPolicy());

        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, eta));
        registry.executeQueued(address(account), id);
        _warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, eta));
        registry.executeQueued(address(account), id);

        _warp(eta);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.PolicyApplied(address(account), p);
        vm.prank(stranger);
        registry.executeQueued(address(account), id);
        _eq(registry.policy(address(account)), p);
        // Executed items are gone.
        (uint8 kind,,,,) = registry.queued(address(account), id);
        assertEq(kind, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.UnknownQueued.selector, id));
        registry.executeQueued(address(account), id);
    }

    function test_QueuedItemExpiresSevenDaysAfterEta() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id1 = _setPolicy(p);
        p.maxTradeUsdc = 300e6;
        uint256 id2 = _setPolicy(p);
        uint40 eta = _eta(id1);
        _warp(eta + QUEUE_TTL + 1);
        vm.expectRevert(IAgentPolicyRegistry.QueuedExpired.selector);
        registry.executeQueued(address(account), id1);
        // The last executable second is ETA + 7 days.
        _warp(eta + QUEUE_TTL);
        registry.executeQueued(address(account), id2);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 300e6);
    }

    function test_AgentWideningQueues() public {
        Agent memory before = registry.agent(address(account), agentKey);
        vm.prank(accountOwner);
        registry.setAgent(address(account), agentKey, before.expiresAt, P_BUY);
        // Adding a permission back is a widening.
        uint40 eta = uint40(_now() + 1 hours);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentQueued(address(account), 1, agentKey, before.expiresAt + 1, P_BUY | P_SELL, eta);
        vm.prank(accountOwner);
        uint256 id = registry.setAgent(address(account), agentKey, before.expiresAt + 1, P_BUY | P_SELL);
        assertEq(id, 1);
        assertEq(registry.agent(address(account), agentKey).permissions, P_BUY);
        (uint8 kind,,,,) = registry.queued(address(account), id);
        assertEq(kind, Q_SET_AGENT);
        _warp(eta);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentActivated(address(account), agentKey, before.expiresAt + 1, P_BUY | P_SELL);
        registry.executeQueued(address(account), id);
        assertEq(registry.agent(address(account), agentKey).permissions, P_BUY | P_SELL);
        assertEq(registry.agent(address(account), agentKey).expiresAt, before.expiresAt + 1);
    }

    function test_SetAgentTighteningAfterQueueMakesItStale() public {
        Agent memory before = registry.agent(address(account), agentKey);
        vm.prank(accountOwner);
        registry.setAgent(address(account), agentKey, before.expiresAt, P_BUY);
        vm.prank(accountOwner);
        uint256 id = registry.setAgent(address(account), agentKey, before.expiresAt, P_ALL);
        vm.prank(accountOwner);
        registry.setAgent(address(account), agentKey, before.expiresAt - 1, P_BUY);
        _warp(_eta(id));
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id);
        assertEq(registry.agent(address(account), agentKey).permissions, P_BUY);
    }

    function test_AddAgentQueuesAndActivatesAfterEta() public {
        uint40 exp = uint40(_now() + 30 days);
        vm.prank(accountOwner);
        uint256 id = registry.addAgent(address(account), newKey, exp, P_BUY);
        assertFalse(registry.agent(address(account), newKey).active);
        assertEq(registry.activeAgentCount(address(account)), 1);
        _warp(_eta(id));
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentActivated(address(account), newKey, exp, P_BUY);
        registry.executeQueued(address(account), id);
        assertTrue(registry.agent(address(account), newKey).active);
        assertEq(registry.activeAgentCount(address(account)), 2);
    }

    function test_AddAgentChecksTerms() public {
        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.InvalidAgent.selector);
        registry.addAgent(address(account), accountOwner, uint40(_now() + 1 days), P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.InvalidAgent.selector);
        registry.addAgent(address(account), address(account), uint40(_now() + 1 days), P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.AgentExpiryOutOfRange.selector);
        registry.addAgent(address(account), newKey, uint40(_now() + MAX_AGENT_TTL + 1), P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.InvalidPermissions.selector);
        registry.addAgent(address(account), newKey, uint40(_now() + 1 days), 0);
        vm.expectRevert(IAgentPolicyRegistry.AgentAlreadyActive.selector);
        registry.addAgent(address(account), agentKey, uint40(_now() + 1 days), P_BUY);
        vm.stopPrank();
    }

    function test_AddAgentExpiryCheckedAtExecution() public {
        vm.prank(accountOwner);
        uint256 id = registry.addAgent(address(account), newKey, uint40(_now() + 2 hours), P_BUY);
        _warp(_now() + 2 hours);
        vm.expectRevert(IAgentPolicyRegistry.AgentExpiryOutOfRange.selector);
        registry.executeQueued(address(account), id);
    }

    function test_PauseAgentsCancelsQueuedItems() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 idPolicy = _setPolicy(p);
        vm.prank(accountOwner);
        uint256 idAgent = registry.addAgent(address(account), newKey, uint40(_now() + 30 days), P_BUY);

        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentsPaused(address(account), true);
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), true);
        assertTrue(registry.ownerPaused(address(account)));
        assertEq(registry.epoch(address(account)), 1);

        _warp(_eta(idAgent));
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.QueuedCancelled(address(account), idPolicy);
        registry.executeQueued(address(account), idPolicy);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.QueuedCancelled(address(account), idAgent);
        registry.executeQueued(address(account), idAgent);
        _eq(registry.policy(address(account)), _defaultPolicy());
        assertFalse(registry.agent(address(account), newKey).active);
        (uint8 kind,,,,) = registry.queued(address(account), idPolicy);
        assertEq(kind, 0);

        // Unpausing does not revive them; new items queue in the new epoch.
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), false);
        assertEq(registry.epoch(address(account)), 1);
        uint256 id3 = _setPolicy(p);
        _warp(_eta(id3));
        registry.executeQueued(address(account), id3);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 200e6);
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
        registry.executeQueued(address(account), id);
        Policy memory got = registry.policy(address(account));
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
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.PolicyApplied(address(account), now_);
        uint256 id = _setPolicy(p);
        assertEq(id, 1);
        _eq(registry.policy(address(account)), now_);
        (,,,, bytes memory payload) = registry.queued(address(account), id);
        _eq(abi.decode(payload, (Policy)), p);
        _warp(_eta(id));
        registry.executeQueued(address(account), id);
        _eq(registry.policy(address(account)), p);
    }

    function test_PolicyAboveCeilingRevertsAtQueue() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 1_000e6 + 1;
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.BetaCeiling.selector, uint8(0)));
        registry.setPolicy(address(account), p);
        p = _defaultPolicy();
        p.maxDeadlineSeconds = 0;
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.InvalidPolicy.selector, uint8(9)));
        registry.setPolicy(address(account), p);
    }

    function test_NinthAgentFailsAtExecution() public {
        uint256[] memory ids = new uint256[](8);
        vm.startPrank(accountOwner);
        for (uint256 i = 0; i < 8; i++) {
            ids[i] = registry.addAgent(address(account), address(uint160(0xA000 + i)), uint40(_now() + 30 days), P_BUY);
        }
        vm.stopPrank();
        _warp(_eta(ids[0]));
        for (uint256 i = 0; i < 7; i++) {
            registry.executeQueued(address(account), ids[i]);
        }
        assertEq(registry.activeAgentCount(address(account)), 8);
        vm.expectRevert(IAgentPolicyRegistry.TooManyAgents.selector);
        registry.executeQueued(address(account), ids[7]);
        // A revocation frees a slot.
        vm.prank(accountOwner);
        registry.revokeAgent(address(account), agentKey);
        registry.executeQueued(address(account), ids[7]);
        assertEq(registry.activeAgentCount(address(account)), 8);
    }

    function test_RevokedAgentCannotBeReAdded() public {
        Agent memory a = registry.agent(address(account), agentKey);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentRevoked(address(account), agentKey, a.expiresAt, a.permissions);
        vm.prank(accountOwner);
        registry.revokeAgent(address(account), agentKey);
        assertTrue(registry.retired(address(account), agentKey));
        assertFalse(registry.agent(address(account), agentKey).active);
        assertEq(registry.activeAgentCount(address(account)), 0);

        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.addAgent(address(account), agentKey, uint40(_now() + 1 days), P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.revokeAgent(address(account), agentKey);
        // Any address can be retired pre-emptively, active or not.
        registry.revokeAgent(address(account), stranger);
        assertTrue(registry.retired(address(account), stranger));
        assertEq(registry.activeAgentCount(address(account)), 0);
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.addAgent(address(account), stranger, uint40(_now() + 1 days), P_BUY);
        vm.stopPrank();
    }

    function test_RevokedAgentCannotBeReAddedViaQueuedAdd() public {
        vm.startPrank(accountOwner);
        uint256 id1 = registry.addAgent(address(account), newKey, uint40(_now() + 30 days), P_BUY);
        uint256 id2 = registry.addAgent(address(account), newKey, uint40(_now() + 30 days), P_ALL);
        vm.stopPrank();
        _warp(_eta(id1));
        registry.executeQueued(address(account), id1);
        vm.prank(accountOwner);
        registry.revokeAgent(address(account), newKey);
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.executeQueued(address(account), id2);
        assertFalse(registry.agent(address(account), newKey).active);
    }

    function test_QueuedSetAgentDiesWithRevoke() public {
        Agent memory a = registry.agent(address(account), agentKey);
        vm.prank(accountOwner);
        uint256 id = registry.setAgent(address(account), agentKey, a.expiresAt + 1 days, P_ALL);
        vm.prank(accountOwner);
        registry.revokeAgent(address(account), agentKey);
        _warp(_eta(id));
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id);
    }

    function test_RotationRevokesImmediatelyAndQueuesNewKey() public {
        uint40 exp = uint40(_now() + 30 days);
        vm.prank(accountOwner);
        uint256 id = registry.rotateAgent(address(account), agentKey, newKey, exp, P_BUY);
        assertEq(id, 1);
        assertTrue(registry.retired(address(account), agentKey));
        assertFalse(registry.agent(address(account), agentKey).active);
        assertFalse(registry.agent(address(account), newKey).active);
        assertEq(registry.activeAgentCount(address(account)), 0);
        _warp(_eta(id));
        registry.executeQueued(address(account), id);
        assertTrue(registry.agent(address(account), newKey).active);
        assertEq(registry.activeAgentCount(address(account)), 1);

        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.rotateAgent(address(account), agentKey, makeAddr("x"), exp, P_BUY);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.rotateAgent(address(account), newKey, newKey, exp, P_BUY);
    }

    function test_CancelQueued() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id = _setPolicy(p);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.QueuedCancelled(address(account), id);
        vm.prank(accountOwner);
        registry.cancelQueued(address(account), id);
        _warp(_now() + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.UnknownQueued.selector, id));
        registry.executeQueued(address(account), id);
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.UnknownQueued.selector, id));
        registry.cancelQueued(address(account), id);
    }

    // ---------------------------------------------------------------- ownership

    function test_OnlyQueuedNewOwnerAcceptsAndAcceptingCancelsOldQueue() public {
        uint40 eta = uint40(_now() + 1 hours);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.OwnershipQueued(address(account), 1, newOwner, eta);
        vm.prank(accountOwner);
        uint256 idOwner = registry.transferOwnership(address(account), newOwner);
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 idPolicy = _setPolicy(p);
        (uint8 kind,,,,) = registry.queued(address(account), idOwner);
        assertEq(kind, Q_OWNER);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, eta));
        registry.acceptOwnership(address(account), idOwner);

        _warp(eta);
        vm.prank(stranger);
        vm.expectRevert(IAgentPolicyRegistry.NotPendingOwner.selector);
        registry.acceptOwnership(address(account), idOwner);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotPendingOwner.selector);
        registry.acceptOwnership(address(account), idOwner);
        vm.prank(newOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotPendingOwner.selector);
        registry.acceptOwnership(address(account), idPolicy);
        vm.expectRevert(IAgentPolicyRegistry.AcceptRequired.selector);
        registry.executeQueued(address(account), idOwner);

        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AccountOwnerChanged(address(account), accountOwner, newOwner);
        vm.prank(newOwner);
        registry.acceptOwnership(address(account), idOwner);
        assertEq(account.owner(), newOwner);
        assertEq(registry.epoch(address(account)), 1);

        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.QueuedCancelled(address(account), idPolicy);
        registry.executeQueued(address(account), idPolicy);
        _eq(registry.policy(address(account)), _defaultPolicy());

        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.pauseAgents(address(account), true);
        vm.prank(newOwner);
        registry.pauseAgents(address(account), true);
    }

    function test_AcceptOwnershipExpires() public {
        vm.prank(accountOwner);
        uint256 id = registry.transferOwnership(address(account), newOwner);
        _warp(_eta(id) + QUEUE_TTL + 1);
        vm.prank(newOwner);
        vm.expectRevert(IAgentPolicyRegistry.QueuedExpired.selector);
        registry.acceptOwnership(address(account), id);
    }

    function test_AcceptOwnershipAfterPauseIsCancelled() public {
        vm.prank(accountOwner);
        uint256 id = registry.transferOwnership(address(account), newOwner);
        vm.prank(accountOwner);
        registry.pauseAgents(address(account), true);
        _warp(_eta(id));
        vm.prank(newOwner);
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.acceptOwnership(address(account), id);
        assertEq(account.owner(), accountOwner);
    }

    function test_AcceptingAgentLosesAgentRole() public {
        vm.prank(accountOwner);
        uint256 id = registry.transferOwnership(address(account), agentKey);
        _warp(_eta(id));
        vm.prank(agentKey);
        registry.acceptOwnership(address(account), id);
        assertEq(account.owner(), agentKey);
        assertFalse(registry.agent(address(account), agentKey).active);
        assertTrue(registry.retired(address(account), agentKey));
        assertEq(registry.activeAgentCount(address(account)), 0);
    }

    function test_TransferOwnershipBadTargets() public {
        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.InvalidOwner.selector);
        registry.transferOwnership(address(account), address(0));
        vm.expectRevert(IAgentPolicyRegistry.InvalidOwner.selector);
        registry.transferOwnership(address(account), address(account));
        vm.expectRevert(IAgentPolicyRegistry.InvalidOwner.selector);
        registry.transferOwnership(address(account), accountOwner);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- delay

    function test_DelayRaiseIsImmediateLowerIsQueued() public {
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.IncreaseDelaySet(address(account), 2 hours);
        vm.prank(accountOwner);
        assertEq(registry.setIncreaseDelay(address(account), 2 hours), 0);
        assertEq(registry.increaseDelay(address(account)), 2 hours);

        vm.prank(accountOwner);
        uint256 id = registry.setIncreaseDelay(address(account), 30 minutes);
        assertEq(id, 1);
        assertEq(registry.increaseDelay(address(account)), 2 hours);
        (uint8 kind, uint40 eta,,,) = registry.queued(address(account), id);
        assertEq(kind, Q_DELAY);
        assertEq(eta, _now() + 2 hours, "lowering waits the current delay");
        _warp(eta);
        registry.executeQueued(address(account), id);
        assertEq(registry.increaseDelay(address(account)), 30 minutes);

        vm.prank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.DelayOutOfRange.selector);
        registry.setIncreaseDelay(address(account), uint32(MAX_DELAY + 1));
    }

    function test_DelayRaiseAfterQueuedLowerSurvives() public {
        vm.prank(accountOwner);
        uint256 id = registry.setIncreaseDelay(address(account), 0);
        vm.prank(accountOwner);
        registry.setIncreaseDelay(address(account), 3 days);
        _warp(_eta(id));
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id);
        assertEq(registry.increaseDelay(address(account)), 3 days);
    }

    function test_ZeroDelayExecutesInTheSameBlock() public {
        InitParams memory ip = _defaults();
        ip.increaseDelay = 0;
        AgentAccount acc = _account(accountOwner, bytes32(uint256(9)), ip);
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        vm.prank(accountOwner);
        uint256 id = registry.setPolicy(address(acc), p);
        (, uint40 eta,,,) = registry.queued(address(acc), id);
        assertEq(eta, _now());
        registry.executeQueued(address(acc), id);
        assertEq(registry.policy(address(acc)).maxTradeUsdc, 200e6);
        vm.prank(accountOwner);
        id = registry.addAgent(address(acc), newKey, uint40(_now() + 1 days), P_BUY);
        registry.executeQueued(address(acc), id);
        assertTrue(registry.agent(address(acc), newKey).active);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_WithdrawPaysOnlyTheOwner() public {
        ERC20Mock token = new ERC20Mock();
        token.mint(address(account), 1_000e18);
        vm.deal(address(account), 5e18);
        uint256 ownerBal = accountOwner.balance;

        vm.expectEmit(address(account));
        emit IAgentAccount.AccountWithdrawn(address(0), 2e18);
        vm.prank(accountOwner);
        account.withdraw(address(0), 2e18);
        assertEq(accountOwner.balance, ownerBal + 2e18);
        assertEq(address(account).balance, 3e18);

        vm.expectEmit(address(account));
        emit IAgentAccount.AccountWithdrawn(address(token), 400e18);
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
        emit IAgentAccount.AccountWithdrawn(address(t1), 7e18);
        vm.expectEmit(address(account));
        emit IAgentAccount.AccountWithdrawn(address(0), 3e18 + 1);
        vm.expectEmit(address(account));
        emit IAgentAccount.AccountWithdrawn(address(t2), 9e18);
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
        registry.pauseAgents(address(account), true);
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
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.addAgent(address(account), newKey, exp, P_BUY);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.setAgent(address(account), agentKey, exp, P_BUY);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.revokeAgent(address(account), agentKey);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.rotateAgent(address(account), agentKey, newKey, exp, P_BUY);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.setPolicy(address(account), p);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.setTokenAllowed(address(account), stranger, false);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.setIncreaseDelay(address(account), 2 hours);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.transferOwnership(address(account), callers[i]);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.cancelQueued(address(account), 1);
            vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
            registry.pauseAgents(address(account), true);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.withdraw(address(0), 0);
            vm.expectRevert(IAgentAccount.NotOwner.selector);
            account.withdrawMany(tokens);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- version-based staleness (fix round 1)

    /// @dev A->B->A: item 1 widens 100 -> 200; the owner tightens to 50, then queues and executes 50 -> 100.
    ///      Item 1 must not apply 200, although the value is back at its queue-time value.
    function test_PolicyABAWideningDoesNotReturn() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id1 = _setPolicy(p);
        p.maxTradeUsdc = 50e6;
        assertEq(_setPolicy(p), 0);
        p.maxTradeUsdc = 100e6;
        uint256 id2 = _setPolicy(p);
        _warp(_eta(id2));
        registry.executeQueued(address(account), id2);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6);
        registry.executeQueued(address(account), id1);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 100e6, "old widening must not return");
    }

    function test_SetAgentABAWideningIsStale() public {
        uint40 e = registry.agent(address(account), agentKey).expiresAt;
        vm.startPrank(accountOwner);
        uint256 id1 = registry.setAgent(address(account), agentKey, e + 10 days, P_ALL);
        assertEq(registry.setAgent(address(account), agentKey, e - 1 days, P_ALL), 0);
        uint256 id2 = registry.setAgent(address(account), agentKey, e, P_ALL);
        vm.stopPrank();
        _warp(_eta(id2));
        registry.executeQueued(address(account), id2);
        assertEq(registry.agent(address(account), agentKey).expiresAt, e);
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id1);
        assertEq(registry.agent(address(account), agentKey).expiresAt, e);
    }

    function test_DelayABALoweringIsStale() public {
        vm.startPrank(accountOwner);
        uint256 id1 = registry.setIncreaseDelay(address(account), 0);
        registry.setIncreaseDelay(address(account), 2 hours);
        uint256 id2 = registry.setIncreaseDelay(address(account), 1 hours);
        vm.stopPrank();
        _warp(_eta(id2));
        registry.executeQueued(address(account), id2);
        assertEq(registry.increaseDelay(address(account)), 1 hours);
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id1);
        assertEq(registry.increaseDelay(address(account)), 1 hours);
    }

    function test_DoubleQueuedTokenAddGoesStaleAfterRemoval() public {
        address token = makeAddr("token");
        vm.startPrank(accountOwner);
        uint256 id1 = registry.setTokenAllowed(address(account), token, true);
        uint256 id2 = registry.setTokenAllowed(address(account), token, true);
        vm.stopPrank();
        _warp(_eta(id2));
        registry.executeQueued(address(account), id2);
        assertTrue(registry.tokenAllowed(address(account), token));
        vm.prank(accountOwner);
        registry.setTokenAllowed(address(account), token, false);
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id1);
        assertFalse(registry.tokenAllowed(address(account), token));
    }

    function test_RemovalWhileAddPendingMakesAddStale() public {
        address token = makeAddr("token");
        vm.prank(accountOwner);
        uint256 id = registry.setTokenAllowed(address(account), token, true);
        vm.prank(accountOwner);
        assertEq(registry.setTokenAllowed(address(account), token, false), 0);
        _warp(_eta(id));
        vm.expectRevert(IAgentPolicyRegistry.StaleQueued.selector);
        registry.executeQueued(address(account), id);
        assertFalse(registry.tokenAllowed(address(account), token));
    }

    function test_DelayRaiseAlsoDelaysQueuedItems() public {
        uint256 t0 = _now();
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id = _setPolicy(p);
        p.maxTradeUsdc = 300e6;
        uint256 idLate = _setPolicy(p);
        assertEq(_eta(id), t0 + 1 hours);
        vm.prank(accountOwner);
        registry.setIncreaseDelay(address(account), 5 hours);
        assertEq(_eta(id), t0 + 5 hours, "effective ETA follows the raised delay");
        _warp(t0 + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TooEarly.selector, uint40(t0 + 5 hours)));
        registry.executeQueued(address(account), id);
        _warp(t0 + 5 hours);
        registry.executeQueued(address(account), id);
        assertEq(registry.policy(address(account)).maxTradeUsdc, 200e6);
        // Expiry is measured from the effective ETA, and the expired item stays in storage.
        _warp(t0 + 5 hours + QUEUE_TTL + 1);
        vm.expectRevert(IAgentPolicyRegistry.QueuedExpired.selector);
        registry.executeQueued(address(account), idLate);
        (uint8 kind,,,,) = registry.queued(address(account), idLate);
        assertEq(kind, Q_POLICY);
    }

    function test_RetiringInactiveAddressKillsPendingAdd() public {
        vm.prank(accountOwner);
        uint256 id = registry.addAgent(address(account), newKey, uint40(_now() + 30 days), P_BUY);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentRevoked(address(account), newKey, 0, 0);
        vm.prank(accountOwner);
        registry.revokeAgent(address(account), newKey);
        assertTrue(registry.retired(address(account), newKey));
        assertEq(registry.activeAgentCount(address(account)), 1);
        _warp(_eta(id));
        vm.expectRevert(IAgentPolicyRegistry.AgentRetired.selector);
        registry.executeQueued(address(account), id);
    }

    function test_WriteSeqMovesOnEveryAppliedChange() public {
        uint64 s0 = registry.writeSeq(address(account));
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 50e6;
        _setPolicy(p);
        assertEq(registry.writeSeq(address(account)), s0 + 1);
        vm.startPrank(accountOwner);
        registry.setTokenAllowed(address(account), stranger, false);
        registry.setIncreaseDelay(address(account), 2 hours);
        registry.revokeAgent(address(account), agentKey);
        vm.stopPrank();
        assertEq(registry.writeSeq(address(account)), s0 + 4);
    }

    // ---------------------------------------------------------------- registry isolation (split of Task 3)

    function test_NonAccountCannotAuthorizeOrRecord() public {
        address[4] memory callers = [stranger, accountOwner, agentKey, address(agentImpl)];
        uint256 dl = _now() + 60;
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IAgentPolicyRegistry.NotAccount.selector);
            registry.authorize(agentKey, P_BUY, dl);
            vm.prank(callers[i]);
            vm.expectRevert(IAgentPolicyRegistry.NotAccount.selector);
            registry.record(stranger, 1, 1, true);
        }
        // Even the factory, which registers accounts, is not one.
        vm.prank(address(agentFactory));
        vm.expectRevert(IAgentPolicyRegistry.NotAccount.selector);
        registry.record(stranger, 1, 0, false);
    }

    function test_AccountCanOnlyAuthorizeAndRecordForItself() public {
        address agentB = makeAddr("agent b");
        InitParams memory p = _defaults();
        p.firstAgent = agentB;
        AgentAccount b = _account(stranger, bytes32(0), p);
        address tok = makeAddr("token");

        // `record` has no account parameter: account A's call charges A only.
        vm.prank(address(account));
        registry.record(tok, 10e6, 5e6, true);
        (, uint64 spentA, uint64 soldA,, uint16 launchesA) = registry.usage(address(account));
        assertEq(spentA, 10e6);
        assertEq(soldA, 5e6);
        assertEq(launchesA, 1);
        assertEq(registry.tokenSpent(address(account), tok), 10e6);
        (, uint64 spentB, uint64 soldB, uint32 actionsB, uint16 launchesB) = registry.usage(address(b));
        assertEq(spentB, 0);
        assertEq(soldB, 0);
        assertEq(actionsB, 0);
        assertEq(launchesB, 0);
        assertEq(registry.tokenSpent(address(b), tok), 0);

        // Account A cannot borrow account B's agent, nor B account A's.
        uint256 dl = _now() + 60;
        vm.prank(address(account));
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        registry.authorize(agentB, P_BUY, dl);
        vm.prank(address(b));
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        registry.authorize(agentKey, P_BUY, dl);
        // Through the accounts themselves: B's agent cannot trade A.
        vm.prank(agentB);
        vm.expectRevert(IAgentPolicyRegistry.NotAgent.selector);
        account.buy(tok, 1e6, 1, dl);
    }

    function test_RecordEnforcesEachCapWithTypedErrors() public {
        address tok = makeAddr("token");
        vm.startPrank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 500e6));
        registry.record(tok, 500e6 + 1, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.TokenCapExceeded.selector, 100e6));
        registry.record(tok, 100e6 + 1, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, 500e6));
        registry.record(tok, 0, 500e6 + 1, false);
        // Arbitrary inputs cannot overflow the comparison.
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSpendExceeded.selector, 500e6));
        registry.record(tok, type(uint256).max, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyRegistry.PeriodSellExceeded.selector, 500e6));
        registry.record(tok, 0, type(uint256).max, false);
        registry.record(tok, 0, 0, true);
        registry.record(tok, 0, 0, true);
        registry.record(tok, 0, 0, true);
        vm.expectRevert(IAgentPolicyRegistry.LaunchLimit.selector);
        registry.record(tok, 0, 0, true);
        vm.stopPrank();
    }

    function test_OwnerOfOneAccountCannotManageAnother() public {
        AgentAccount b = _account(stranger, bytes32(0), _defaults());
        address bAddr = address(b);
        uint40 exp = uint40(_now() + 1 days);
        Policy memory p = _defaultPolicy();
        address[] memory tokens = new address[](1);
        // Queue an item on B (by B's owner) so `cancelQueued` and `executeQueued` have a real id.
        vm.prank(stranger);
        uint256 idB = registry.addAgent(bAddr, newKey, exp, P_BUY);

        vm.startPrank(accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.addAgent(bAddr, newKey, exp, P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.setAgent(bAddr, agentKey, exp, P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.revokeAgent(bAddr, agentKey);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.rotateAgent(bAddr, agentKey, newKey, exp, P_BUY);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.setPolicy(bAddr, p);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.setTokenAllowed(bAddr, stranger, false);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.setIncreaseDelay(bAddr, 2 hours);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.transferOwnership(bAddr, accountOwner);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.cancelQueued(bAddr, idB);
        vm.expectRevert(IAgentPolicyRegistry.NotOwner.selector);
        registry.pauseAgents(bAddr, true);
        vm.expectRevert(IAgentAccount.NotOwner.selector);
        b.withdraw(address(0), 0);
        vm.expectRevert(IAgentAccount.NotOwner.selector);
        b.withdrawMany(tokens);
        // A's own queued items live in A's queue only: queueing on A does not touch B's id space.
        uint256 idA = registry.addAgent(address(account), newKey, exp, P_BUY);
        vm.stopPrank();
        assertEq(idA, 1);
        assertEq(idB, 1);
        (uint8 kind,,,, bytes memory payload) = registry.queued(bAddr, idB);
        assertEq(kind, Q_ADD_AGENT);
        (address queuedKey,,) = abi.decode(payload, (address, uint40, uint16));
        assertEq(queuedKey, newKey);
        assertEq(registry.owner(bAddr), stranger);
        assertFalse(registry.ownerPaused(bAddr));
        assertTrue(registry.agent(bAddr, agentKey).active);
    }

    // ---------------------------------------------------------------- indexer views and events

    function test_QueuedSeqAndLastWriteGetters() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 50e6;
        _setPolicy(p);
        uint64 sPolicy = registry.writeSeq(address(account));
        assertEq(registry.policyWrite(address(account), 0), sPolicy, "maxTradeUsdc written");
        p.periodSpendCap = 600e6;
        uint256 id = _setPolicy(p);
        (,,, uint64 seq,) = registry.queued(address(account), id);
        assertEq(seq, sPolicy, "item seq is writeSeq at queue time");

        vm.startPrank(accountOwner);
        registry.setIncreaseDelay(address(account), 2 hours);
        assertEq(registry.delayWrite(address(account)), registry.writeSeq(address(account)));
        registry.setTokenAllowed(address(account), stranger, false);
        assertEq(registry.tokenWrite(address(account), stranger), registry.writeSeq(address(account)));
        registry.revokeAgent(address(account), agentKey);
        assertEq(registry.agentWrite(address(account), agentKey), registry.writeSeq(address(account)));
        vm.stopPrank();
        assertLe(registry.policyWrite(address(account), 1), seq, "periodSpendCap not written since");
    }

    function test_AgentQueuedCarriesIdAndQueueTimeEta() public {
        uint40 exp = uint40(_now() + 30 days);
        vm.expectEmit(address(registry));
        emit IAgentPolicyRegistry.AgentQueued(address(account), 1, newKey, exp, P_BUY, uint40(_now() + 1 hours));
        vm.prank(accountOwner);
        registry.addAgent(address(account), newKey, exp, P_BUY);
    }

    function test_FullyStalePolicyExecutionAppliesNothing() public {
        Policy memory p = _defaultPolicy();
        p.maxTradeUsdc = 200e6;
        uint256 id = _setPolicy(p);
        // Rewrite every field after queueing.
        Policy memory t = _defaultPolicy();
        t.maxTradeUsdc = 90e6;
        t.periodSpendCap = 400e6;
        t.perTokenPeriodCap = 90e6;
        t.periodSellCap = 400e6;
        t.maxActionsPerPeriod = 400;
        t.launchesPerPeriod = 2;
        t.maxPriceImpactBps = 200;
        t.maxDeadlineSeconds = 60;
        t.minTokenAgeBlocks = 1;
        t.allowlistOnly = true;
        _setPolicy(t);
        // maxSnipeBps is 0 and cannot go lower: widen it and execute that item so it is written too.
        Policy memory w = t;
        w.maxSnipeBps = 100;
        uint256 idSnipe = _setPolicy(w);
        _warp(_eta(idSnipe));
        registry.executeQueued(address(account), idSnipe);
        (,,, uint64 seq,) = registry.queued(address(account), id);
        for (uint256 i; i < 11; ++i) {
            assertGt(registry.policyWrite(address(account), i), seq, "every field written since");
        }
        uint64 before = registry.writeSeq(address(account));
        vm.recordLogs();
        registry.executeQueued(address(account), id);
        assertEq(vm.getRecordedLogs().length, 1, "only QueuedExecuted");
        assertEq(registry.writeSeq(address(account)), before, "nothing written");
        _eq(registry.policy(address(account)), w);
    }

    function test_RevokeAndRotateRejectZeroOwnerAndSelf() public {
        address[3] memory bad = [address(0), accountOwner, address(account)];
        uint40 exp = uint40(_now() + 30 days);
        vm.startPrank(accountOwner);
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(IAgentPolicyRegistry.InvalidAgent.selector);
            registry.revokeAgent(address(account), bad[i]);
            vm.expectRevert(IAgentPolicyRegistry.InvalidAgent.selector);
            registry.rotateAgent(address(account), bad[i], newKey, exp, P_BUY);
        }
        vm.stopPrank();
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

    function testFuzz_MergeTakesTargetOnlyForUnwrittenFields(
        Policy memory cur,
        Policy memory target,
        uint64[11] memory lastWrite,
        uint64 seq
    ) public view {
        Policy memory m = lib.merge(cur, target, lastWrite, seq);
        uint256[11] memory c = abi.decode(abi.encode(cur), (uint256[11]));
        uint256[11] memory t = abi.decode(abi.encode(target), (uint256[11]));
        uint256[11] memory r = abi.decode(abi.encode(m), (uint256[11]));
        for (uint256 i; i < 11; ++i) {
            assertEq(r[i], lastWrite[i] <= seq ? t[i] : c[i]);
        }
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
        registry.executeQueued(address(account), id);
        assertEq(registry.policy(address(account)).maxTradeUsdc, tightTrade);
        assertEq(registry.policy(address(account)).maxPriceImpactBps, tightImpact);
    }
}
