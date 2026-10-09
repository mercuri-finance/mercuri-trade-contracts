// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniversalRouterHarness} from "../integration/UniversalRouterSwap.t.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/agents/AgentAccountFactory.sol";
import {AgentPolicyRegistry} from "../../src/agents/AgentPolicyRegistry.sol";
import {Policy, InitParams, P_ALL} from "../../src/agents/AgentTypes.sol";

/// @dev The real Launch system and Universal Router (from `UniversalRouterHarness`), plus an agent account
///      implementation and factory wired to them. `factory` is the LaunchFactory; the agent factory is `agentFactory`.
abstract contract AgentFixture is UniversalRouterHarness {
    AgentAccountFactory internal agentFactory;
    AgentAccount internal agentImpl;
    /// @dev The agent factory's registry, where owners manage their accounts.
    AgentPolicyRegistry internal registry;

    /// @dev Stands in for the network's Launch timelock.
    address internal agentAdmin = makeAddr("agent admin");
    /// @dev Stands in for the Guardian Safe.
    address internal agentGuardian = makeAddr("agent guardian");
    address internal accountOwner = makeAddr("account owner");
    address internal agentKey = makeAddr("agent key");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual override {
        super.setUp();
        (agentImpl, agentFactory) = _deployAgents(agentGuardian, _ceilings());
        registry = AgentPolicyRegistry(agentFactory.registry());
        vm.deal(accountOwner, 100_000e18);
    }

    /// @dev Deploys an implementation bound to the factory deployed right after it (and to the registry that
    ///      factory deploys as its first CREATE), as the deploy script does.
    function _deployAgents(address guardian_, Policy memory ceilings_)
        internal
        returns (AgentAccount impl, AgentAccountFactory f)
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        impl = _newImpl(predicted);
        f = new AgentAccountFactory(address(impl), agentAdmin, guardian_, ceilings_);
        require(address(f) == predicted, "agent factory address");
        require(f.registry() == vm.computeCreateAddress(predicted, 1), "registry address");
    }

    /// @dev An implementation bound to `factory_` and to the registry `factory_` will deploy.
    function _newImpl(address factory_) internal returns (AgentAccount) {
        return new AgentAccount(
            factory_,
            vm.computeCreateAddress(factory_, 1),
            address(factory),
            address(feeManager),
            address(gm),
            address(hook),
            address(poolManager),
            address(router),
            address(permit2),
            USDC
        );
    }

    /// @dev The beta ceilings of spec section 4.5 (usdc6 for amounts).
    function _ceilings() internal pure returns (Policy memory) {
        return Policy({
            maxTradeUsdc: 1_000e6,
            periodSpendCap: 10_000e6,
            perTokenPeriodCap: 2_000e6,
            periodSellCap: 10_000e6,
            maxActionsPerPeriod: 5_000,
            launchesPerPeriod: 20,
            maxPriceImpactBps: 2_000,
            maxSnipeBps: 9_900,
            minTokenAgeBlocks: 0,
            maxDeadlineSeconds: 600,
            allowlistOnly: false
        });
    }

    /// @dev The proposed default policy of spec section 4.5 (usdc6 for amounts).
    function _defaultPolicy() internal pure returns (Policy memory) {
        return Policy({
            maxTradeUsdc: 100e6,
            periodSpendCap: 500e6,
            perTokenPeriodCap: 100e6,
            periodSellCap: 500e6,
            maxActionsPerPeriod: 500,
            launchesPerPeriod: 3,
            maxPriceImpactBps: 300,
            maxSnipeBps: 0,
            minTokenAgeBlocks: 0,
            maxDeadlineSeconds: 120,
            allowlistOnly: false
        });
    }

    /// @dev Default creation parameters: Launch referrer, one-day period, one-hour delay and `agentKey` with every
    ///      permission for 30 days.
    function _defaults() internal view returns (InitParams memory p) {
        p.referrer = referrer;
        p.policy = _defaultPolicy();
        p.periodSeconds = 1 days;
        p.increaseDelay = 1 hours;
        p.firstAgent = agentKey;
        p.firstAgentExpiresAt = uint40(block.timestamp + 30 days);
        p.firstAgentPermissions = P_ALL;
    }

    /// @dev Creates `accountOwner`'s account with the defaults and salt zero.
    function _account() internal returns (AgentAccount) {
        return _account(accountOwner, bytes32(0), _defaults());
    }

    function _account(address owner_, bytes32 salt, InitParams memory p) internal returns (AgentAccount) {
        vm.prank(owner_);
        return AgentAccount(payable(agentFactory.createAccount(salt, p)));
    }
}
