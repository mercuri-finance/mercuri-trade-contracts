// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniversalRouterSwapTest, ICanonicalRouter} from "./UniversalRouterSwap.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {NativeUsdcShim} from "../utils/NativeUsdcShim.sol";

/// @dev Read-only RPC fork; launches, liquidity and swaps exist only in Foundry memory. Arc's native ERC-20 precompile
///      is modelled by the same rollback-safe shim as the isolated suite. Router, PoolManager, quoter and Permit2
///      retain fork code.
contract UniversalRouterForkTest is UniversalRouterSwapTest {
    function setUp() public override {
        string memory rpc = vm.envOr("ARC_LOCAL_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 chain = vm.envOr("TRADE_FORK_CHAIN_ID", uint256(5042002));
        require(chain == 5042002 || chain == 5042, "unsupported fork chain");
        vm.createSelectFork(rpc, vm.envOr("TRADE_FORK_BLOCK", chain == 5042 ? uint256(23084816) : uint256(64325644)));
        assertEq(block.chainid, chain);
        super.setUp();
    }

    function _configureRouter() internal override {
        router = ICanonicalRouter(0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1);
        quoter = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
        assertGt(address(router).code.length, 0);
    }

    function _deployV4() internal override {
        vm.etch(USDC, address(new NativeUsdcShim()).code);
        vm.allowCheatcodes(USDC);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        posm = IPositionManager(
            deployCode(
                "PositionManager.sol:PositionManager",
                abi.encode(poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
            )
        );
    }
}
