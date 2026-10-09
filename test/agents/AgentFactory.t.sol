// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/agents/AgentAccountFactory.sol";
import {IAgentAccount} from "../../src/agents/interfaces/IAgentAccount.sol";
import {AgentPolicyLib} from "../../src/agents/AgentPolicyLib.sol";
import {IAgentAccountFactory} from "../../src/agents/interfaces/IAgentAccountFactory.sol";
import {
    Policy,
    Agent,
    InitParams,
    P_ALL,
    P_BUY,
    GUARDIAN_PAUSE,
    GUARDIAN_COOLDOWN,
    MAX_AGENT_TTL,
    MAX_ADMIN_PAUSE,
    F_MIN_TOKEN_AGE_BLOCKS
} from "../../src/agents/AgentTypes.sol";

contract AgentFactoryTest is AgentFixture {
    // ---------------------------------------------------------------- creation

    function test_PredictedAddressEqualsCreated() public {
        bytes32 salt = keccak256("one");
        address predicted = agentFactory.predictAccount(accountOwner, salt);
        vm.expectEmit(address(agentFactory));
        emit IAgentAccountFactory.AccountCreated(accountOwner, predicted, referrer, salt);
        AgentAccount account = _account(accountOwner, salt, _defaults());
        assertEq(address(account), predicted);
        assertEq(account.owner(), accountOwner);
        assertGt(address(account).code.length, 0);
    }

    function test_SameSaltTwoOwnersGiveTwoAddresses() public {
        AgentAccount a = _account(accountOwner, bytes32(0), _defaults());
        AgentAccount b = _account(stranger, bytes32(0), _defaults());
        assertTrue(address(a) != address(b));
        assertEq(a.owner(), accountOwner);
        assertEq(b.owner(), stranger);
    }

    function test_ReusedSaltReverts() public {
        AgentAccount account = _account();
        InitParams memory p = _defaults();
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccountFactory.AccountExists.selector, address(account)));
        agentFactory.createAccount{gas: 1_000_000}(bytes32(0), p);
    }

    function test_InitializeFromNonFactoryReverts() public {
        AgentAccount account = _account();
        InitParams memory p = _defaults();
        vm.prank(stranger);
        vm.expectRevert(IAgentAccount.NotFactory.selector);
        account.initialize(stranger, p);
        // Even the factory cannot initialise an account twice.
        vm.prank(address(agentFactory));
        vm.expectRevert(IAgentAccount.AlreadyInitialized.selector);
        account.initialize(stranger, p);
    }

    function test_InitializeOnImplementationReverts() public {
        InitParams memory p = _defaults();
        vm.prank(stranger);
        vm.expectRevert(IAgentAccount.NotFactory.selector);
        agentImpl.initialize(stranger, p);
        vm.prank(address(agentFactory));
        vm.expectRevert(IAgentAccount.AlreadyInitialized.selector);
        agentImpl.initialize(stranger, p);
        assertEq(agentImpl.owner(), address(0));
    }

    function test_IsAccountIsSet() public {
        AgentAccount account = _account();
        assertTrue(agentFactory.isAccount(address(account)));
        assertFalse(agentFactory.isAccount(address(agentImpl)));
        assertFalse(agentFactory.isAccount(stranger));
    }

    function test_ImmutablesAndVersion() public view {
        assertEq(agentFactory.implementation(), address(agentImpl));
        assertEq(agentFactory.admin(), agentAdmin);
        assertEq(agentFactory.guardian(), agentGuardian);
        assertEq(agentFactory.VERSION(), "1.0.0-beta.1");
        assertEq(agentImpl.FACTORY(), address(agentFactory));
        assertEq(address(agentImpl.LAUNCH_FACTORY()), address(factory));
        assertEq(address(agentImpl.FEE_MANAGER()), address(feeManager));
        assertEq(address(agentImpl.GRADUATION_MANAGER()), address(gm));
        assertEq(agentImpl.LAUNCH_HOOK(), address(hook));
        assertEq(address(agentImpl.POOL_MANAGER()), address(poolManager));
        assertEq(agentImpl.UNIVERSAL_ROUTER(), address(router));
        assertEq(agentImpl.PERMIT2(), address(permit2));
        assertEq(agentImpl.USDC(), USDC);
        Policy memory c = agentFactory.ceilings();
        Policy memory expected = _ceilings();
        assertEq(abi.encode(c), abi.encode(expected));
    }

    function test_ClonesReadImplementationImmutables() public {
        AgentAccount account = _account();
        assertEq(account.FACTORY(), address(agentFactory));
        assertEq(address(account.FEE_MANAGER()), address(feeManager));
        assertEq(account.UNIVERSAL_ROUTER(), address(router));
    }

    function test_FactoryRejectsImplementationBoundElsewhere() public {
        AgentAccount impl = new AgentAccount(
            stranger,
            address(factory),
            address(feeManager),
            address(gm),
            address(hook),
            address(poolManager),
            address(router),
            address(permit2),
            USDC
        );
        vm.expectRevert(IAgentAccountFactory.ImplementationMismatch.selector);
        new AgentAccountFactory(address(impl), agentAdmin, agentGuardian, _ceilings());
    }

    function test_ZeroAddressesRevert() public {
        vm.expectRevert(IAgentAccount.ZeroAddress.selector);
        new AgentAccount(
            address(0),
            address(factory),
            address(feeManager),
            address(gm),
            address(hook),
            address(poolManager),
            address(router),
            address(permit2),
            USDC
        );
        vm.expectRevert(IAgentAccount.ZeroAddress.selector);
        new AgentAccount(
            stranger,
            address(factory),
            address(feeManager),
            address(gm),
            address(hook),
            address(poolManager),
            address(router),
            address(permit2),
            address(0)
        );
        vm.expectRevert(IAgentAccountFactory.ZeroAddress.selector);
        new AgentAccountFactory(address(0), agentAdmin, agentGuardian, _ceilings());
        vm.expectRevert(IAgentAccountFactory.ZeroAddress.selector);
        new AgentAccountFactory(address(agentImpl), address(0), agentGuardian, _ceilings());
    }

    // ---------------------------------------------------------------- initialisation

    function test_InitialStateIsStored() public {
        InitParams memory p = _defaults();
        AgentAccount account = _account();
        assertEq(account.referrer(), referrer);
        assertEq(abi.encode(account.policy()), abi.encode(p.policy));
        assertEq(account.periodSeconds(), 1 days);
        assertEq(account.increaseDelay(), 1 hours);
        Agent memory a = account.agent(agentKey);
        assertTrue(a.active);
        assertEq(a.expiresAt, p.firstAgentExpiresAt);
        assertEq(a.permissions, P_ALL);
        assertEq(account.activeAgentCount(), 1);
    }

    function test_InitializeEmitsPolicyAndAgent() public {
        InitParams memory p = _defaults();
        address predicted = agentFactory.predictAccount(accountOwner, bytes32(0));
        vm.expectEmit(predicted);
        emit IAgentAccount.PolicyApplied(p.policy);
        vm.expectEmit(predicted);
        emit IAgentAccount.AgentActivated(agentKey, p.firstAgentExpiresAt, P_ALL);
        _account();
    }

    function test_NoFirstAgent() public {
        InitParams memory p = _defaults();
        p.firstAgent = address(0);
        AgentAccount account = _account(accountOwner, bytes32(0), p);
        assertEq(account.activeAgentCount(), 0);
        assertFalse(account.agent(agentKey).active);
    }

    function test_ReferrerIsBound() public {
        AgentAccount account = _account();
        assertEq(feeManager.referrerOf(address(account)), referrer);
    }

    function test_SelfReferrerReverts() public {
        InitParams memory p = _defaults();
        p.referrer = agentFactory.predictAccount(accountOwner, bytes32(0));
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.SelfReferrer.selector);
        agentFactory.createAccount(bytes32(0), p);
    }

    function test_ZeroReferrerLeavesUnbound() public {
        InitParams memory p = _defaults();
        p.referrer = address(0);
        AgentAccount account = _account(accountOwner, bytes32(0), p);
        assertEq(feeManager.referrerOf(address(account)), address(0));
        assertEq(account.referrer(), address(0));
    }

    function test_ReferrerMayBeOwner() public {
        // Deliberate: the owner may refer its own account and earn the referrer share of the account's fees.
        InitParams memory p = _defaults();
        p.referrer = accountOwner;
        AgentAccount account = _account(accountOwner, bytes32(0), p);
        assertEq(feeManager.referrerOf(address(account)), accountOwner);
        assertEq(account.referrer(), accountOwner);
    }

    function test_PolicyAtCeilingsIsAccepted() public {
        InitParams memory p = _defaults();
        p.policy = _ceilings();
        p.policy.allowlistOnly = true;
        AgentAccount account = _account(accountOwner, bytes32(0), p);
        assertEq(abi.encode(account.policy()), abi.encode(p.policy));
    }

    function test_EachCeilingExceededReverts() public {
        // Field 8 (minTokenAgeBlocks) is a floor and the beta floor is zero; it is covered below.
        for (uint8 field; field < 10; ++field) {
            if (field == F_MIN_TOKEN_AGE_BLOCKS) continue;
            InitParams memory p = _defaults();
            p.policy = _ceilings();
            _loosen(p.policy, field);
            vm.prank(accountOwner);
            vm.expectRevert(abi.encodeWithSelector(IAgentAccount.BetaCeiling.selector, field));
            agentFactory.createAccount(bytes32(uint256(field)), p);
        }
    }

    function test_MinTokenAgeBelowFloorReverts() public {
        Policy memory c = _ceilings();
        c.minTokenAgeBlocks = 10;
        (, AgentAccountFactory f) = _deployAgents(agentGuardian, c);
        InitParams memory p = _defaults();
        p.policy.minTokenAgeBlocks = 9;
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.BetaCeiling.selector, F_MIN_TOKEN_AGE_BLOCKS));
        f.createAccount(bytes32(0), p);
        p.policy.minTokenAgeBlocks = 10;
        vm.prank(accountOwner);
        f.createAccount(bytes32(0), p);
    }

    function test_PolicyShapeIsValidated() public {
        // Ceilings are themselves in range, so through an account only a zero deadline gets past them.
        InitParams memory p = _defaults();
        p.policy.maxDeadlineSeconds = 0;
        vm.prank(accountOwner);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.InvalidPolicy.selector, uint8(9)));
        agentFactory.createAccount(bytes32(0), p);

        // The library bounds, checked directly.
        Policy memory q = _defaultPolicy();
        q.maxPriceImpactBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.InvalidPolicy.selector, uint8(6)));
        this.validatePolicy(q);
        q = _defaultPolicy();
        q.maxSnipeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.InvalidPolicy.selector, uint8(7)));
        this.validatePolicy(q);
        q = _defaultPolicy();
        q.maxDeadlineSeconds = 601;
        vm.expectRevert(abi.encodeWithSelector(IAgentAccount.InvalidPolicy.selector, uint8(9)));
        this.validatePolicy(q);
        q = _defaultPolicy();
        q.maxPriceImpactBps = 10_000;
        q.maxSnipeBps = 10_000;
        q.maxDeadlineSeconds = 600;
        this.validatePolicy(q);
    }

    /// @dev External wrapper so `expectRevert` can observe the library's revert.
    function validatePolicy(Policy memory p) external pure {
        AgentPolicyLib.validate(p);
    }

    function test_PeriodSecondsOutOfRangeReverts() public {
        uint32[2] memory bad = [uint32(1 hours - 1), uint32(7 days + 1)];
        for (uint256 i; i < 2; ++i) {
            InitParams memory p = _defaults();
            p.periodSeconds = bad[i];
            vm.prank(accountOwner);
            vm.expectRevert(IAgentAccount.PeriodOutOfRange.selector);
            agentFactory.createAccount(bytes32(i), p);
        }
        uint32[2] memory good = [uint32(1 hours), uint32(7 days)];
        for (uint256 i; i < 2; ++i) {
            InitParams memory p = _defaults();
            p.periodSeconds = good[i];
            assertEq(_account(accountOwner, bytes32(i), p).periodSeconds(), good[i]);
        }
    }

    function test_IncreaseDelayAboveMaxReverts() public {
        InitParams memory p = _defaults();
        p.increaseDelay = 7 days + 1;
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.DelayOutOfRange.selector);
        agentFactory.createAccount(bytes32(0), p);
        p.increaseDelay = 7 days;
        assertEq(_account(accountOwner, bytes32(0), p).increaseDelay(), 7 days);
        p.increaseDelay = 0;
        assertEq(_account(accountOwner, bytes32(uint256(1)), p).increaseDelay(), 0);
    }

    function test_FirstAgentExpiryOutOfRangeReverts() public {
        InitParams memory p = _defaults();
        p.firstAgentExpiresAt = uint40(block.timestamp + MAX_AGENT_TTL + 1);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.AgentExpiryOutOfRange.selector);
        agentFactory.createAccount(bytes32(0), p);

        p.firstAgentExpiresAt = uint40(block.timestamp);
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.AgentExpiryOutOfRange.selector);
        agentFactory.createAccount(bytes32(0), p);

        p.firstAgentExpiresAt = uint40(block.timestamp + MAX_AGENT_TTL);
        assertEq(_account(accountOwner, bytes32(0), p).agent(agentKey).expiresAt, p.firstAgentExpiresAt);
    }

    function test_FirstAgentPermissionsValidated() public {
        InitParams memory p = _defaults();
        p.firstAgentPermissions = 0;
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.InvalidPermissions.selector);
        agentFactory.createAccount(bytes32(0), p);

        p.firstAgentPermissions = P_ALL + 1;
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.InvalidPermissions.selector);
        agentFactory.createAccount(bytes32(0), p);

        p.firstAgentPermissions = P_BUY;
        assertEq(_account(accountOwner, bytes32(0), p).agent(agentKey).permissions, P_BUY);
    }

    function test_FirstAgentCannotBeOwnerOrAccount() public {
        InitParams memory p = _defaults();
        p.firstAgent = accountOwner;
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.InvalidAgent.selector);
        agentFactory.createAccount(bytes32(0), p);

        p.firstAgent = agentFactory.predictAccount(accountOwner, bytes32(0));
        vm.prank(accountOwner);
        vm.expectRevert(IAgentAccount.InvalidAgent.selector);
        agentFactory.createAccount(bytes32(0), p);
    }

    // ---------------------------------------------------------------- ERC-1271 and receive

    function testFuzz_IsValidSignatureNeverReturnsMagic(bytes32 hash, bytes calldata signature) public {
        AgentAccount account = _account();
        assertEq(account.isValidSignature(hash, signature), bytes4(0xffffffff));
        assertEq(agentImpl.isValidSignature(hash, signature), bytes4(0xffffffff));
    }

    function test_ReceiveAcceptsValue() public {
        AgentAccount account = _account();
        vm.deal(stranger, 5e18);
        vm.prank(stranger);
        (bool ok,) = payable(address(account)).call{value: 5e18}("");
        assertTrue(ok);
        assertEq(address(account).balance, 5e18);
    }

    // ---------------------------------------------------------------- guardian pause

    function test_GuardianPauseLasts72Hours() public {
        uint40 start = uint40(block.timestamp);
        vm.expectEmit(address(agentFactory));
        emit IAgentAccountFactory.AgentsPausedUntil(start + uint40(GUARDIAN_PAUSE), agentGuardian);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        assertTrue(agentFactory.isPaused());
        assertEq(agentFactory.pausedUntil(), start + GUARDIAN_PAUSE);
        vm.warp(start + GUARDIAN_PAUSE - 1);
        assertTrue(agentFactory.isPaused());
        vm.warp(start + GUARDIAN_PAUSE);
        assertFalse(agentFactory.isPaused());
    }

    function test_SecondGuardianPauseNeedsCooldown() public {
        uint40 start = uint40(block.timestamp);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        uint40 readyAt = start + uint40(GUARDIAN_PAUSE + GUARDIAN_COOLDOWN);

        // During the pause itself and during the cooldown after it.
        vm.warp(start + 1 hours);
        vm.prank(agentGuardian);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccountFactory.PauseCooldown.selector, readyAt));
        agentFactory.guardianPause();
        vm.warp(readyAt - 1);
        vm.prank(agentGuardian);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccountFactory.PauseCooldown.selector, readyAt));
        agentFactory.guardianPause();

        vm.warp(readyAt);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        assertEq(agentFactory.pausedUntil(), readyAt + GUARDIAN_PAUSE);
        assertTrue(agentFactory.isPaused());
    }

    function test_AdminCanLift() public {
        uint40 start = uint40(block.timestamp);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();

        vm.expectEmit(address(agentFactory));
        emit IAgentAccountFactory.AgentsPausedUntil(0, agentAdmin);
        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(0);
        assertFalse(agentFactory.isPaused());
        assertEq(agentFactory.pausedUntil(), 0);

        // Lifting early does not reset the guardian's cooldown, which runs from the end its pause stored.
        vm.prank(agentGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentAccountFactory.PauseCooldown.selector, start + uint40(GUARDIAN_PAUSE + GUARDIAN_COOLDOWN)
            )
        );
        agentFactory.guardianPause();
    }

    function test_AdminCanShorten() public {
        uint40 start = uint40(block.timestamp);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(start + 1 hours);
        assertEq(agentFactory.pausedUntil(), start + 1 hours);
        vm.warp(start + 1 hours);
        assertFalse(agentFactory.isPaused());
    }

    function test_AdminCanExtendActivePauseUpTo30Days() public {
        uint40 start = uint40(block.timestamp);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        uint40 longest = start + uint40(MAX_ADMIN_PAUSE);
        vm.prank(agentAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccountFactory.PauseTooLong.selector, longest));
        agentFactory.adminSetPausedUntil(longest + 1);

        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(longest);
        assertEq(agentFactory.pausedUntil(), longest);
        vm.warp(longest - 1);
        assertTrue(agentFactory.isPaused());
        vm.warp(longest);
        assertFalse(agentFactory.isPaused());
    }

    function test_AdminCannotStartPause() public {
        vm.prank(agentAdmin);
        vm.expectRevert(IAgentAccountFactory.NoActivePause.selector);
        agentFactory.adminSetPausedUntil(uint40(block.timestamp + 1 days));

        // Nor once a guardian pause has ended.
        uint40 start = uint40(block.timestamp);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        vm.warp(start + GUARDIAN_PAUSE);
        vm.prank(agentAdmin);
        vm.expectRevert(IAgentAccountFactory.NoActivePause.selector);
        agentFactory.adminSetPausedUntil(start + uint40(GUARDIAN_PAUSE) + 1 days);
        // Setting a value at or below the stored end is still allowed (a no-op lift).
        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(0);
        assertEq(agentFactory.pausedUntil(), 0);
    }

    function test_GuardianCannotShortenAdminExtension() public {
        uint40 start = uint40(block.timestamp);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        uint40 longer = start + 30 days;
        vm.prank(agentAdmin);
        agentFactory.adminSetPausedUntil(longer);

        uint40 readyAt = start + uint40(GUARDIAN_PAUSE + GUARDIAN_COOLDOWN);
        vm.warp(readyAt);
        vm.expectEmit(address(agentFactory));
        emit IAgentAccountFactory.AgentsPausedUntil(longer, agentGuardian);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        assertEq(agentFactory.pausedUntil(), longer);

        // The cooldown now runs from the stored (30-day) end.
        vm.warp(longer + GUARDIAN_COOLDOWN - 1);
        vm.prank(agentGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentAccountFactory.PauseCooldown.selector, longer + uint40(GUARDIAN_COOLDOWN))
        );
        agentFactory.guardianPause();
        vm.warp(longer + GUARDIAN_COOLDOWN);
        vm.prank(agentGuardian);
        agentFactory.guardianPause();
        assertEq(agentFactory.pausedUntil(), longer + GUARDIAN_COOLDOWN + GUARDIAN_PAUSE);
    }

    function test_SetGuardianZeroReverts() public {
        vm.prank(agentAdmin);
        vm.expectRevert(IAgentAccountFactory.ZeroAddress.selector);
        agentFactory.setGuardian(address(0));
        assertEq(agentFactory.guardian(), agentGuardian);
    }

    function test_BadCeilingsRevertDeploy() public {
        Policy[4] memory bad;
        uint8[4] memory fields = [uint8(6), 7, 9, 9];
        for (uint256 i; i < 4; ++i) {
            bad[i] = _ceilings();
        }
        bad[0].maxPriceImpactBps = 10_001;
        bad[1].maxSnipeBps = 10_001;
        bad[2].maxDeadlineSeconds = 0;
        bad[3].maxDeadlineSeconds = 601;
        for (uint256 i; i < 4; ++i) {
            address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
            AgentAccount impl = new AgentAccount(
                predicted,
                address(factory),
                address(feeManager),
                address(gm),
                address(hook),
                address(poolManager),
                address(router),
                address(permit2),
                USDC
            );
            vm.expectRevert(abi.encodeWithSelector(IAgentAccountFactory.InvalidCeiling.selector, fields[i]));
            new AgentAccountFactory(address(impl), agentAdmin, agentGuardian, bad[i]);
        }
    }

    function test_PauseRolesAreEnforced() public {
        vm.prank(stranger);
        vm.expectRevert(IAgentAccountFactory.NotGuardian.selector);
        agentFactory.guardianPause();
        vm.prank(agentAdmin);
        vm.expectRevert(IAgentAccountFactory.NotGuardian.selector);
        agentFactory.guardianPause();
        vm.prank(agentGuardian);
        vm.expectRevert(IAgentAccountFactory.NotAdmin.selector);
        agentFactory.adminSetPausedUntil(0);
        vm.prank(agentGuardian);
        vm.expectRevert(IAgentAccountFactory.NotAdmin.selector);
        agentFactory.setGuardian(stranger);
    }

    function test_AdminReplacesGuardian() public {
        address next = makeAddr("next guardian");
        vm.expectEmit(address(agentFactory));
        emit IAgentAccountFactory.GuardianSet(next);
        vm.prank(agentAdmin);
        agentFactory.setGuardian(next);
        assertEq(agentFactory.guardian(), next);
        vm.prank(agentGuardian);
        vm.expectRevert(IAgentAccountFactory.NotGuardian.selector);
        agentFactory.guardianPause();
        vm.prank(next);
        agentFactory.guardianPause();
        assertTrue(agentFactory.isPaused());
    }

    function test_GuardianZeroDisablesPauseForever() public {
        (, AgentAccountFactory f) = _deployAgents(address(0), _ceilings());
        assertEq(f.guardian(), address(0));
        for (uint256 i; i < 2; ++i) {
            vm.prank(address(0));
            vm.expectRevert(IAgentAccountFactory.GuardianDisabled.selector);
            f.guardianPause();
            vm.prank(agentAdmin);
            vm.expectRevert(IAgentAccountFactory.GuardianDisabled.selector);
            f.setGuardian(agentGuardian);
            vm.prank(agentAdmin);
            vm.expectRevert(IAgentAccountFactory.GuardianDisabled.selector);
            f.adminSetPausedUntil(uint40(block.timestamp + 1 days));
            vm.warp(vm.getBlockTimestamp() + 365 days);
        }
        assertFalse(f.isPaused());
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Sets policy field `field` (Policy struct order) one step above its ceiling.
    function _loosen(Policy memory p, uint8 field) private pure {
        if (field == 0) p.maxTradeUsdc += 1;
        else if (field == 1) p.periodSpendCap += 1;
        else if (field == 2) p.perTokenPeriodCap += 1;
        else if (field == 3) p.periodSellCap += 1;
        else if (field == 4) p.maxActionsPerPeriod += 1;
        else if (field == 5) p.launchesPerPeriod += 1;
        else if (field == 6) p.maxPriceImpactBps += 1;
        else if (field == 7) p.maxSnipeBps += 1;
        else if (field == 9) p.maxDeadlineSeconds += 1;
        else revert("field");
    }
}
