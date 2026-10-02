// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTestnetReactor} from "../../script/DeployTestnetReactor.s.sol";
import {DeployOrderFiller} from "../../script/DeployOrderFiller.s.sol";
import {TradeManifest} from "../../script/TradeManifest.sol";

/// @notice The deployment scripts must refuse the shipped manifest (sentinel owner) and any other chain.
contract DeployScriptsTest is Test {
    function setUp() public {
        vm.chainId(5042002);
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
    }

    function test_reactorScriptRefusesSentinelOwner() public {
        DeployTestnetReactor script = new DeployTestnetReactor();
        vm.expectRevert(); // vm.parseAddress rejects the sentinel string

        script.run();
    }

    /// @dev Positive control: the same script succeeds once the rehearsal override supplies an address, so the
    /// revert above is caused by the sentinel and not by an unrelated failure.
    function test_reactorScriptRunsWithRehearsalOverride() public {
        vm.etch(0x000000000022D473030F116dDEE9F6B43aC78BA3, hex"00");
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "true");
        vm.setEnv("REACTOR_FEE_OWNER_OVERRIDE", "0x00000000000000000000000000000000000000BB");
        DeployTestnetReactor script = new DeployTestnetReactor();
        address reactor = address(script.run());
        assertGt(reactor.code.length, 0);
    }

    function test_fillerScriptRefusesSentinelOwner() public {
        vm.setEnv("TRADE_REACTOR", "0x00000000000000000000000000000000000000AA");
        DeployOrderFiller script = new DeployOrderFiller();
        vm.expectRevert();
        script.run();
    }

    function test_scriptsRefuseOtherChains() public {
        vm.chainId(5042);
        DeployTestnetReactor reactorScript = new DeployTestnetReactor();
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.WrongChain.selector, 5042));
        reactorScript.run();
        DeployOrderFiller fillerScript = new DeployOrderFiller();
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.WrongChain.selector, 5042));
        fillerScript.run();
    }

    function test_manifestShipsSentinel() public view {
        string memory manifest = vm.readFile("deployments/manifest-5042002.json");
        assertEq(vm.parseJsonString(manifest, ".reactorFeeOwner"), "REQUIRED_AT_D2_OWNER_GO");
    }
}
