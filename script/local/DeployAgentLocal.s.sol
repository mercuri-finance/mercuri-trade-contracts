// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script} from "forge-std/Script.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {LaunchConfig} from "@mercuri/launch/libraries/LaunchTypes.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {FeeManager} from "@mercuri/launch/FeeManager.sol";
import {GraduationManager} from "@mercuri/launch/GraduationManager.sol";
import {LiquidityLocker} from "@mercuri/launch/LiquidityLocker.sol";
import {LaunchHook} from "@mercuri/launch/LaunchHook.sol";
import {HookMiner} from "../../test/utils/launch/HookMiner.sol";
import {DefaultConfig} from "../../test/utils/launch/DefaultConfig.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/agents/AgentAccountFactory.sol";
import {Policy} from "../../src/agents/AgentTypes.sol";
import {AnvilUsdcStub} from "./AnvilUsdcStub.sol";

/// @notice LOCAL ONLY. Deploys v4 core, Permit2, the Universal Router, V4Quoter, the Launch system and the Agent
///         Accounts factory (which deploys its policy registry) to a loopback Anvil for the SDK integration tier, then
///         writes the address book to test-export/agent-local-31337.json. Reverts on any chain other than 31337.
/// @dev Not derived from `DeployPermit2`: that helper declares its own `run()`. A throwaway instance etches Permit2 in
///      the simulation instead (cheatcodes work from any contract in a script).
contract DeployAgentLocal is Script {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Forge routes `new X{salt: …}` under broadcast through this deterministic deployer, which Anvil predeploys.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct RouterParameters {
        address permit2;
        address weth9;
        address v2Factory;
        address v3Factory;
        bytes32 pairInitCodeHash;
        bytes32 poolInitCodeHash;
        address v4PoolManager;
        address v3NFTPositionManager;
        address v4PositionManager;
        address spokePool;
    }

    struct Deployed {
        address poolManager;
        address posm;
        address router;
        address quoter;
        address factory;
        address feeManager;
        address gm;
        address hook;
        address agentFactory;
        address agentImpl;
        address agentRegistry;
    }

    function run() external {
        require(block.chainid == 31337, "DeployAgentLocal: loopback Anvil (31337) only");
        uint256 key = vm.envUint("ANVIL_DEPLOYER_KEY");
        address deployer = vm.addr(key);

        _setCode(USDC, type(AnvilUsdcStub).runtimeCode);
        new DeployPermit2().deployPermit2(); // etches in the simulation only; mirrored to the node below
        _setCode(PERMIT2, PERMIT2.code);

        Deployed memory d;
        vm.startBroadcast(key);
        d.poolManager = address(new PoolManager(deployer));
        d.posm = deployCode(
            "PositionManager.sol:PositionManager",
            abi.encode(d.poolManager, PERMIT2, uint256(100_000), address(0), address(0))
        );
        RouterParameters memory rp;
        rp.permit2 = PERMIT2;
        rp.v4PoolManager = d.poolManager;
        rp.v4PositionManager = d.posm;
        d.router = deployCode("out/trade-router/UniversalRouter.sol/UniversalRouter.json", abi.encode(rp));
        d.quoter = address(new V4Quoter(IPoolManager(d.poolManager)));
        _deployLaunch(d, deployer);
        _deployAgents(d, deployer);
        vm.stopBroadcast();
        _writeBook(d);
    }

    function _deployLaunch(Deployed memory d, address deployer) internal {
        LaunchConfig memory cfg = DefaultConfig.get();
        address feeManagerImpl = address(new FeeManager());
        address gmImpl = address(new GraduationManager());
        address factoryImpl = address(new LaunchFactory());
        // The hook goes through the CREATE2 deployer (one deployer transaction, so one nonce); then the locker and
        // the three proxies, in this order (as in test/utils/LaunchFixture.sol).
        uint64 nonce = vm.getNonce(deployer);
        address lockerAddr = vm.computeCreateAddress(deployer, nonce + 1);
        address feeManagerAddr = vm.computeCreateAddress(deployer, nonce + 2);
        address gmAddr = vm.computeCreateAddress(deployer, nonce + 3);
        address factoryAddr = vm.computeCreateAddress(deployer, nonce + 4);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            abi.encodePacked(type(LaunchHook).creationCode, abi.encode(d.poolManager, feeManagerAddr, gmAddr, USDC))
        );
        d.hook = address(new LaunchHook{salt: salt}(d.poolManager, feeManagerAddr, gmAddr, USDC));
        require(d.hook == hookAddr, "hook address");
        require(address(new LiquidityLocker(d.posm, gmAddr)) == lockerAddr, "locker address");
        d.feeManager = address(
            new ERC1967Proxy(
                feeManagerImpl, abi.encodeCall(FeeManager.initialize, (factoryAddr, hookAddr, gmAddr, deployer))
            )
        );
        d.gm = address(
            new ERC1967Proxy(
                gmImpl,
                abi.encodeCall(
                    GraduationManager.initialize,
                    (factoryAddr, d.poolManager, d.posm, PERMIT2, hookAddr, lockerAddr, feeManagerAddr, USDC, deployer)
                )
            )
        );
        d.factory = address(
            new ERC1967Proxy(
                factoryImpl,
                abi.encodeCall(LaunchFactory.initialize, (deployer, deployer, deployer, feeManagerAddr, gmAddr, cfg))
            )
        );
        require(d.feeManager == feeManagerAddr && d.gm == gmAddr && d.factory == factoryAddr, "proxy addresses");
    }

    /// @dev The implementation is bound to the factory deployed right after it and to the registry that factory
    ///      deploys as its first CREATE (contract nonces start at 1), exactly as test/agents/AgentFixture.sol does.
    function _deployAgents(Deployed memory d, address deployer) internal {
        address predictedFactory = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        address predictedRegistry = vm.computeCreateAddress(predictedFactory, 1);
        d.agentImpl = address(
            new AgentAccount(
                predictedFactory,
                predictedRegistry,
                d.factory,
                d.feeManager,
                d.gm,
                d.hook,
                d.poolManager,
                d.router,
                PERMIT2,
                USDC
            )
        );
        AgentAccountFactory f = new AgentAccountFactory(d.agentImpl, deployer, deployer, _ceilings());
        d.agentFactory = address(f);
        d.agentRegistry = f.registry();
        require(d.agentFactory == predictedFactory, "agent factory address");
        require(d.agentRegistry == predictedRegistry, "agent registry address");
    }

    /// @dev Spec §4.5 beta ceilings (usdc6 for amounts). minTokenAgeBlocks is a floor on-chain, so 0 (beta value).
    function _ceilings() internal pure returns (Policy memory p) {
        p.maxTradeUsdc = 1_000e6;
        p.periodSpendCap = 10_000e6;
        p.perTokenPeriodCap = 2_000e6;
        p.periodSellCap = 10_000e6;
        p.maxActionsPerPeriod = 5_000;
        p.launchesPerPeriod = 20;
        p.maxPriceImpactBps = 2_000;
        p.maxSnipeBps = 9_900;
        p.minTokenAgeBlocks = 0;
        p.maxDeadlineSeconds = 600;
        p.allowlistOnly = false;
    }

    function _writeBook(Deployed memory d) internal {
        string memory o = "book";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "launchFactory", d.factory);
        vm.serializeAddress(o, "feeManager", d.feeManager);
        vm.serializeAddress(o, "graduationManager", d.gm);
        vm.serializeAddress(o, "launchHook", d.hook);
        vm.serializeAddress(o, "poolManager", d.poolManager);
        vm.serializeAddress(o, "permit2", PERMIT2);
        vm.serializeAddress(o, "universalRouter", d.router);
        vm.serializeAddress(o, "v4Quoter", d.quoter);
        vm.serializeAddress(o, "usdc", USDC);
        vm.serializeAddress(o, "agentFactory", d.agentFactory);
        vm.serializeAddress(o, "agentImplementation", d.agentImpl);
        vm.serializeAddress(o, "agentRegistry", d.agentRegistry);
        vm.serializeBytes32(o, "agentFactoryCodeHash", d.agentFactory.codehash);
        vm.serializeBytes32(o, "agentImplementationCodeHash", d.agentImpl.codehash);
        vm.serializeBytes32(o, "agentRegistryCodeHash", d.agentRegistry.codehash);
        string memory json = vm.serializeUint(o, "deployBlock", block.number);
        vm.writeJson(json, "./test-export/agent-local-31337.json");
    }

    /// @dev Sets code both in the script's simulation (etch) and on the Anvil node (anvil_setCode).
    function _setCode(address target, bytes memory code) internal {
        vm.etch(target, code);
        vm.rpc("anvil_setCode", string.concat("[\"", vm.toString(target), "\",\"", vm.toString(code), "\"]"));
    }
}
