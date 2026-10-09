// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {GraduationManager} from "@mercuri/launch/GraduationManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeployAgentAccounts} from "../../script/DeployAgentAccounts.s.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/agents/AgentAccountFactory.sol";
import {AgentPolicyRegistry} from "../../src/agents/AgentPolicyRegistry.sol";
import {InitParams, P_ALL} from "../../src/agents/AgentTypes.sol";
import {NativeUsdcShim} from "../utils/NativeUsdcShim.sol";

/// @dev Spec section 10 pinned fork: an agent account deployed by the real deploy script against Arc testnet's
///      deployed Launch contracts swaps on a graduated pool through the deployed Universal Router and LaunchHook.
///      Read-only RPC fork; the deployment and swaps exist only in Foundry memory. Skipped unless
///      ARC_LOCAL_FORK_RPC is set (use the public `https://rpc.testnet.arc.io` or a loopback Anvil fork of it, never a
///      paid provider). Testnet only: mainnet had no graduated pool at its pinned fork block (see
///      `LockerWithdrawalFork.t.sol`). Arc's native USDC ERC-20 precompile is modelled by the same shim as the other
///      fork suites.
contract AgentPoolForkTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    /// @dev The testnet block `LockerWithdrawalFork.t.sol` pins, with three real graduated launches.
    uint256 internal constant TESTNET_BLOCK = 65_301_435;
    /// @dev A graduated testnet launch at that block (locker position 52).
    address internal constant GRADUATED = 0x97B4f9cc5d78bBf47569425D298dcb5Ff392eE84;
    /// @dev 0.05 USDC (usdc6). The pool holds about 1.5 USDC of liquidity at the pinned block: 5 USDC moved its price
    ///      18.6x and failed the 2,000 bps impact limit, so the swap is sized to stay within it.
    uint256 internal constant POOL_BUY_USDC = 5e4;

    AgentAccount internal account;
    AgentAccountFactory internal agentFactory;
    AgentPolicyRegistry internal registry;
    address internal owner = makeAddr("account owner");
    address internal agentKey = makeAddr("agent key");
    string internal record;
    string internal manifest;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_LOCAL_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 chain = vm.envOr("TRADE_FORK_CHAIN_ID", uint256(5042002));
        require(chain == 5042002 || chain == 5042, "unsupported fork chain");
        if (chain != 5042002) vm.skip(true);
        vm.createSelectFork(rpc, vm.envOr("TRADE_FORK_BLOCK", TESTNET_BLOCK));
        assertEq(block.chainid, chain);
        record = vm.readFile("lib/mercuri-launch-contracts/deployments/5042002.json");
        manifest = vm.readFile("deployments/agent-accounts-manifest-5042002.json");

        // The production deploy script, simulated in memory against the deployed Launch contracts.
        AgentAccount impl;
        (impl, agentFactory) = new DeployAgentAccounts().run();
        registry = AgentPolicyRegistry(agentFactory.registry());
        assertEq(impl.UNIVERSAL_ROUTER(), vm.parseJsonAddress(manifest, ".universalRouter"));
        assertEq(impl.LAUNCH_HOOK(), vm.parseJsonAddress(record, ".launchHook"));

        vm.etch(USDC, address(new NativeUsdcShim()).code);
        vm.allowCheatcodes(USDC);

        InitParams memory p;
        p.policy = agentFactory.ceilings();
        p.policy.maxTradeUsdc = 100e6;
        p.policy.periodSpendCap = 500e6;
        p.policy.perTokenPeriodCap = 100e6;
        p.policy.periodSellCap = 500e6;
        p.policy.maxDeadlineSeconds = 120;
        p.periodSeconds = 1 days;
        p.increaseDelay = 1 hours;
        p.firstAgent = agentKey;
        p.firstAgentExpiresAt = uint40(block.timestamp + 30 days);
        p.firstAgentPermissions = P_ALL;
        vm.prank(owner);
        account = AgentAccount(payable(agentFactory.createAccount(bytes32(0), p)));
        vm.deal(address(account), 50e18);
    }

    /// A pool buy and a pool sell by the agent go through the deployed router and hook, are measured in usdc6 from
    /// the native delta, are charged to the caps and leave no allowance behind.
    function test_agentPoolSwapThroughDeployedRouterAndHook() public {
        LaunchFactory launchFactory = LaunchFactory(vm.parseJsonAddress(record, ".factory"));
        BondingCurve curve = BondingCurve(payable(launchFactory.curveOf(GRADUATED)));
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated), "token graduated at the pinned block");
        PoolKey memory key = GraduationManager(vm.parseJsonAddress(record, ".graduationManager")).poolKey(GRADUATED);
        assertEq(address(key.hooks), vm.parseJsonAddress(record, ".launchHook"), "deployed LaunchHook pool");
        address router = vm.parseJsonAddress(manifest, ".universalRouter");
        assertEq(router.codehash, vm.parseJsonBytes32(manifest, ".routerCodeHash"), "pinned router runtime");

        uint256 usdcBefore = address(account).balance;
        vm.prank(agentKey);
        uint256 g = gasleft();
        uint256 tokensOut = account.swapExactIn(GRADUATED, true, POOL_BUY_USDC, 1, block.timestamp + 60);
        emit log_named_uint("agent pool buy gas (deployed router and hook)", g - gasleft());
        assertGt(tokensOut, 0, "pool buy delivered tokens");
        assertEq(IERC20(GRADUATED).balanceOf(address(account)), tokensOut);
        uint256 spentWei = usdcBefore - address(account).balance;
        assertLe(spentWei, POOL_BUY_USDC * 1e12, "spent at most the input");
        (, uint64 spent,, uint32 actions,) = registry.usage(address(account));
        assertEq(spent, (spentWei + 1e12 - 1) / 1e12, "spend charged in usdc6, rounded up");
        assertEq(actions, 1);
        (uint128 cost, uint128 held,) = account.basis(GRADUATED);
        assertEq(held, tokensOut);
        assertEq(cost, spent);

        uint256 mid = address(account).balance;
        vm.prank(agentKey);
        g = gasleft();
        uint256 usdcOut = account.swapExactIn(GRADUATED, false, tokensOut / 2, 1, block.timestamp + 60);
        emit log_named_uint("agent pool sell gas (deployed router and hook)", g - gasleft());
        assertGt(usdcOut, 0, "pool sell paid USDC");
        assertEq(usdcOut, (address(account).balance - mid) / 1e12, "proceeds in usdc6, rounded down");
        (,, uint64 sold, uint32 actions2,) = registry.usage(address(account));
        assertGt(sold, 0, "sell charged at cost");
        assertEq(actions2, 2);
        assertEq(IERC20(USDC).allowance(address(account), vm.parseJsonAddress(manifest, ".permit2")), 0);
        assertEq(IERC20(GRADUATED).allowance(address(account), vm.parseJsonAddress(manifest, ".permit2")), 0);
    }
}
