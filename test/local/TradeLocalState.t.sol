// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {UniswapXFillerTest} from "../integration/UniswapXFiller.t.sol";
import {AdversarialTradeToken} from "../utils/AdversarialTradeToken.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// Offline state export for the Go/Anvil end-to-end order test. Never broadcast.
contract TradeLocalStateTest is UniswapXFillerTest {
    function setUp() public override {
        if (!vm.envOr("TRADE_EXPORT_STATE",false)) vm.skip(true);
    }
    function test_exportState() external {
        // dumpState exports accounts touched in this invocation. Deploy here
        // so constructor storage and untouched reactor/router code are included.
        super.setUp();
        vm.warp(1800000000);
        // Anvil does not implement Arc's native USDC precompile or cheatcodes.
        // Ordinary ERC-20 USDC is sufficient for this R4 settlement integration;
        // native/precompile equivalence is covered by the separate fork suite.
        vm.etch(USDC,address(new MockERC20("USDC","USDC",6)).code);
        MockERC20(USDC).mint(address(this),100000e6);
        MockERC20(USDC).mint(trader,100000e6);
        (Market memory m,AdversarialTradeToken token)=_adversarialMarket(false);
        SignedOrder memory signed=_order(address(token),USDC,100e6,1,99);
        string memory key="anvil";
        vm.serializeAddress(key,"reactor",address(reactor));
        vm.serializeAddress(key,"permit2",address(permit2));
        vm.serializeAddress(key,"filler",address(filler));
        vm.serializeAddress(key,"trader",trader);
        vm.serializeAddress(key,"inputToken",address(token));
        vm.serializeAddress(key,"usdc",USDC);
        vm.serializeAddress(key,"currency0",Currency.unwrap(m.key.currency0));
        vm.serializeAddress(key,"currency1",Currency.unwrap(m.key.currency1));
        vm.serializeBytes(key,"order",signed.order);
        string memory output=vm.serializeBytes(key,"signature",signed.sig);
        vm.createDir("test-export/trade-orders",true);
        vm.writeJson(output,"test-export/trade-orders/anvil-order.json");
        vm.dumpState("test-export/trade-orders/anvil-state.json");
    }
}
