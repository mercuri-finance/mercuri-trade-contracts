// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TradeManifest} from "./TradeManifest.sol";
import {AgentAccount} from "../src/agents/AgentAccount.sol";
import {AgentAccountFactory} from "../src/agents/AgentAccountFactory.sol";
import {AgentPolicyRegistry} from "../src/agents/AgentPolicyRegistry.sol";
import {Policy} from "../src/agents/AgentTypes.sol";

/// @notice Deploys the Mercurifi agent account implementation and its factory (which deploys the policy registry) from
///         `deployments/agent-accounts-manifest-<chainId>.json`. Contains no key: pass `--account` or `--ledger`.
///         Every network deployment needs its own owner go (spec D9); no task runs this with `--broadcast`.
/// @dev The manifest holds inputs only. Its Launch addresses must equal Launch's deployment record for the chain, its
///      admin must be the record's timelock and its guardian the record's guardian (the Guardian Safe on mainnet, which
///      must have code). Its Universal Router must be the router of the Trade manifest for the chain, with the same
///      pinned runtime hash, and its ceilings must be exactly the reviewed beta ceilings of spec section 4.5. The
///      implementation is a CREATE at the deployer's next nonce and the factory the CREATE right after it; the
///      implementation's constructor takes the factory's address and the registry's (the factory's first CREATE)
///      before either exists, so all three addresses are predicted before the broadcast and the run reverts unless
///      everything lands there and is wired as the manifest says. Forge simulates the whole script first, so a failed
///      check sends nothing. A stray deployer transaction in between moves the factory; the factory constructor then
///      reverts `ImplementationMismatch`.
contract DeployAgentAccounts is TradeManifest {
    /// @dev Each network's agent manifest is `deployments/agent-accounts-manifest-<chainId>.json`.
    string internal constant AGENT_MANIFEST_PREFIX = "deployments/agent-accounts-manifest-";

    /// @dev The factory's constructor arguments and the implementation's dependencies, in manifest terms.
    struct Inputs {
        address launchFactory;
        address feeManager;
        address graduationManager;
        address launchHook;
        address poolManager;
        address universalRouter;
        address permit2;
        address usdc;
        address admin;
        address guardian;
        Policy ceilings;
    }

    error AgentManifestMismatch(string field);

    /// @dev Virtual only so a test can run `run()` against a manifest fixture; the script never overrides it.
    function _agentManifest() internal view virtual returns (string memory) {
        return vm.readFile(string.concat(AGENT_MANIFEST_PREFIX, vm.toString(block.chainid), ".json"));
    }

    /// @dev The beta ceilings of spec section 4.5 (decision D3), amounts in usdc6. Lifting them is a new factory and a
    ///      reviewed change here, never a manifest edit alone.
    function _betaCeilings() internal pure returns (Policy memory) {
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

    /// @dev The manifest's ceilings, each required to equal the beta ceiling of the same name.
    function _ceilings(string memory manifest) internal pure returns (Policy memory c) {
        Policy memory beta = _betaCeilings();
        c.maxTradeUsdc = uint64(_ceiling(manifest, "maxTradeUsdc", beta.maxTradeUsdc));
        c.periodSpendCap = uint64(_ceiling(manifest, "periodSpendCap", beta.periodSpendCap));
        c.perTokenPeriodCap = uint64(_ceiling(manifest, "perTokenPeriodCap", beta.perTokenPeriodCap));
        c.periodSellCap = uint64(_ceiling(manifest, "periodSellCap", beta.periodSellCap));
        c.maxActionsPerPeriod = uint32(_ceiling(manifest, "maxActionsPerPeriod", beta.maxActionsPerPeriod));
        c.launchesPerPeriod = uint16(_ceiling(manifest, "launchesPerPeriod", beta.launchesPerPeriod));
        c.maxPriceImpactBps = uint16(_ceiling(manifest, "maxPriceImpactBps", beta.maxPriceImpactBps));
        c.maxSnipeBps = uint16(_ceiling(manifest, "maxSnipeBps", beta.maxSnipeBps));
        c.minTokenAgeBlocks = uint32(_ceiling(manifest, "minTokenAgeBlocks", beta.minTokenAgeBlocks));
        c.maxDeadlineSeconds = uint32(_ceiling(manifest, "maxDeadlineSeconds", beta.maxDeadlineSeconds));
        if (vm.parseJsonBool(manifest, ".ceilings.allowlistOnly")) {
            revert AgentManifestMismatch("ceilings.allowlistOnly");
        }
    }

    function _ceiling(string memory manifest, string memory key, uint256 want) internal pure returns (uint256 got) {
        got = vm.parseJsonUint(manifest, string.concat(".ceilings.", key));
        if (got != want) revert AgentManifestMismatch(string.concat("ceilings.", key));
    }

    /// @dev The manifest holds exactly the input keys, and its ceilings exactly the eleven policy fields: an extra key
    ///      (a deployed address, a misspelt field) is refused rather than ignored.
    function _requireKeys(string memory manifest) internal view {
        string[13] memory keys = [
            "admin",
            "ceilings",
            "chainId",
            "feeManager",
            "graduationManager",
            "guardian",
            "launchFactory",
            "launchHook",
            "permit2",
            "poolManager",
            "routerCodeHash",
            "universalRouter",
            "usdc"
        ];
        string[] memory found = vm.parseJsonKeys(manifest, "$");
        if (found.length != keys.length) revert AgentManifestMismatch("keys");
        for (uint256 i; i < keys.length; ++i) {
            if (!vm.keyExistsJson(manifest, string.concat(".", keys[i]))) revert AgentManifestMismatch("keys");
        }
        if (vm.parseJsonKeys(manifest, ".ceilings").length != 11) revert AgentManifestMismatch("ceilings keys");
    }

    function _requireRecord(
        string memory manifest,
        string memory key,
        string memory launchRecord,
        string memory recordKey
    ) internal pure returns (address value) {
        value = vm.parseJsonAddress(manifest, key);
        if (value != vm.parseJsonAddress(launchRecord, recordKey)) revert AgentManifestMismatch(key);
    }

    /// @dev Reads and checks the manifest against Launch's record and the Trade manifest for the current chain. Reads
    ///      no chain state, so it is the same check offline and on a fork.
    function _inputs(string memory manifest, string memory launchRecord, string memory tradeManifest)
        internal
        view
        returns (Inputs memory a)
    {
        if (vm.parseJsonUint(manifest, ".chainId") != block.chainid) revert AgentManifestMismatch("chainId");
        if (vm.parseJsonUint(launchRecord, ".chainId") != block.chainid) revert LaunchRecordMismatch("record chainId");
        if (vm.parseJsonUint(tradeManifest, ".chainId") != block.chainid) {
            revert AgentManifestMismatch("trade manifest chainId");
        }
        _requireKeys(manifest);
        a.launchFactory = _requireRecord(manifest, ".launchFactory", launchRecord, ".factory");
        a.feeManager = _requireRecord(manifest, ".feeManager", launchRecord, ".feeManager");
        a.graduationManager = _requireRecord(manifest, ".graduationManager", launchRecord, ".graduationManager");
        a.launchHook = _requireRecord(manifest, ".launchHook", launchRecord, ".launchHook");
        a.poolManager = _requireRecord(manifest, ".poolManager", launchRecord, ".poolManager");
        a.permit2 = _requireRecord(manifest, ".permit2", launchRecord, ".permit2");
        a.usdc = _requireRecord(manifest, ".usdc", launchRecord, ".usdc");
        a.admin = _requireRecord(manifest, ".admin", launchRecord, ".timelock");
        a.guardian = _requireRecord(manifest, ".guardian", launchRecord, ".guardian");
        a.universalRouter = vm.parseJsonAddress(manifest, ".universalRouter");
        if (a.universalRouter != vm.parseJsonAddress(tradeManifest, ".router")) {
            revert AgentManifestMismatch(".universalRouter");
        }
        if (vm.parseJsonBytes32(manifest, ".routerCodeHash") != vm.parseJsonBytes32(tradeManifest, ".routerCodeHash")) {
            revert AgentManifestMismatch(".routerCodeHash");
        }
        if (a.guardian == address(0)) revert AgentManifestMismatch(".guardian");
        a.ceilings = _ceilings(manifest);
    }

    /// @dev Every dependency must have code at the current block, the router must have the pinned runtime and the
    ///      mainnet guardian must be a contract (the Guardian Safe).
    function _requireCodes(Inputs memory a, string memory manifest) internal view {
        _requireCode("launchFactory", a.launchFactory);
        _requireCode("feeManager", a.feeManager);
        _requireCode("graduationManager", a.graduationManager);
        _requireCode("launchHook", a.launchHook);
        _requireCode("poolManager", a.poolManager);
        _requireCode("permit2", a.permit2);
        _requireCode("usdc", a.usdc);
        _requireCode("admin", a.admin);
        _requireRouter(a.universalRouter, manifest);
        if (block.chainid == MAINNET_CHAIN_ID) _requireCode("guardian", a.guardian);
    }

    /// @dev The implementation at the deployer's nonce `nonce`, the factory at `nonce + 1` and the registry the
    ///      factory's constructor deploys (its first CREATE, nonce 1).
    function _predict(address deployer, uint256 nonce)
        internal
        pure
        returns (address implementation, address factory, address registry)
    {
        implementation = vm.computeCreateAddress(deployer, nonce);
        factory = vm.computeCreateAddress(deployer, nonce + 1);
        registry = vm.computeCreateAddress(factory, 1);
    }

    /// @dev The two deployments, from the broadcaster, followed by the full wiring check.
    function _deploy(Inputs memory a) internal returns (AgentAccount implementation, AgentAccountFactory factory) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        (address predictedImpl, address predictedFactory, address predictedRegistry) =
            _predict(deployer, vm.getNonce(deployer));
        implementation = new AgentAccount(
            predictedFactory,
            predictedRegistry,
            a.launchFactory,
            a.feeManager,
            a.graduationManager,
            a.launchHook,
            a.poolManager,
            a.universalRouter,
            a.permit2,
            a.usdc
        );
        factory = new AgentAccountFactory(address(implementation), a.admin, a.guardian, a.ceilings);
        vm.stopBroadcast();
        if (address(implementation) != predictedImpl) revert DeploymentMismatch("implementation address");
        if (address(factory) != predictedFactory) revert DeploymentMismatch("factory address");
        _requireWiring(implementation, factory, a);
    }

    /// @dev The implementation, factory and registry must name each other and carry exactly the manifest's inputs.
    function _requireWiring(AgentAccount implementation, AgentAccountFactory factory, Inputs memory a) internal view {
        address registry = factory.registry();
        if (registry != vm.computeCreateAddress(address(factory), 1)) revert DeploymentMismatch("registry address");
        if (registry.code.length == 0) revert NoCode("registry", registry);
        if (AgentPolicyRegistry(registry).FACTORY() != address(factory)) revert DeploymentMismatch("registry FACTORY");
        if (factory.implementation() != address(implementation)) revert DeploymentMismatch("implementation");
        if (implementation.FACTORY() != address(factory)) revert DeploymentMismatch("FACTORY");
        if (address(implementation.REGISTRY()) != registry) revert DeploymentMismatch("REGISTRY");
        if (address(implementation.LAUNCH_FACTORY()) != a.launchFactory) revert DeploymentMismatch("LAUNCH_FACTORY");
        if (address(implementation.FEE_MANAGER()) != a.feeManager) revert DeploymentMismatch("FEE_MANAGER");
        if (address(implementation.GRADUATION_MANAGER()) != a.graduationManager) {
            revert DeploymentMismatch("GRADUATION_MANAGER");
        }
        if (implementation.LAUNCH_HOOK() != a.launchHook) revert DeploymentMismatch("LAUNCH_HOOK");
        if (address(implementation.POOL_MANAGER()) != a.poolManager) revert DeploymentMismatch("POOL_MANAGER");
        if (implementation.UNIVERSAL_ROUTER() != a.universalRouter) revert DeploymentMismatch("UNIVERSAL_ROUTER");
        if (implementation.PERMIT2() != a.permit2) revert DeploymentMismatch("PERMIT2");
        if (implementation.USDC() != a.usdc) revert DeploymentMismatch("USDC");
        if (factory.admin() != a.admin) revert DeploymentMismatch("admin");
        if (factory.guardian() != a.guardian) revert DeploymentMismatch("guardian");
        if (factory.guardianDisabled() != (a.guardian == address(0))) revert DeploymentMismatch("guardianDisabled");
        if (factory.pausedUntil() != 0) revert DeploymentMismatch("pausedUntil");
        if (keccak256(abi.encode(factory.ceilings())) != keccak256(abi.encode(a.ceilings))) {
            revert DeploymentMismatch("ceilings");
        }
    }

    function run() external returns (AgentAccount implementation, AgentAccountFactory factory) {
        _requireArc();
        string memory manifest = _agentManifest();
        Inputs memory a = _inputs(manifest, _launchRecord(), _manifest());
        _requireCodes(a, manifest);
        (implementation, factory) = _deploy(a);
        // Optional: the factory address the runbook expects. With EXPECTED_AGENT_FACTORY set, a factory anywhere else
        // reverts the run before anything is broadcast.
        address expected = vm.envOr("EXPECTED_AGENT_FACTORY", address(0));
        if (expected != address(0) && address(factory) != expected) {
            revert DeploymentMismatch("EXPECTED_AGENT_FACTORY");
        }

        console2.log("implementation", address(implementation));
        console2.log("factory", address(factory));
        console2.log("registry", factory.registry());
        console2.log("admin", a.admin);
        console2.log("guardian", a.guardian);
    }
}
