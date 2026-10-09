// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";

/// @dev Gas of an agent's curve buy and sell against a direct EOA trade of the same size, logged for the report.
contract AgentGasTest is AgentFixture {
    AgentAccount internal account;
    LaunchToken internal token;
    BondingCurve internal curve;

    function setUp() public override {
        super.setUp();
        account = _account();
        vm.deal(address(account), 1_000e18);
        (token, curve) = _create(bytes32(uint256(1)));
        // Warm the token's per-account storage the same way for both paths: one earlier trade each.
        vm.prank(agentKey);
        account.buy(address(token), 1e6, 1, vm.getBlockTimestamp() + 60);
        vm.prank(alice);
        curve.buy{value: 1e18}(1, address(0), type(uint256).max);
    }

    function test_GasOfAgentBuyAndSell() public {
        uint256 dl = vm.getBlockTimestamp() + 60;

        vm.prank(alice);
        uint256 g = gasleft();
        curve.buy{value: 50e18}(1, address(0), dl);
        uint256 direct = g - gasleft();

        vm.prank(agentKey);
        g = gasleft();
        uint256 out = account.buy(address(token), 50e6, 1, dl);
        uint256 agentBuy = g - gasleft();

        vm.prank(agentKey);
        g = gasleft();
        account.sell(address(token), out / 2, 1, dl);
        uint256 agentSell = g - gasleft();

        emit log_named_uint("direct curve buy gas", direct);
        emit log_named_uint("agent buy gas", agentBuy);
        emit log_named_uint("agent buy overhead", agentBuy - direct);
        emit log_named_uint("agent sell gas", agentSell);
    }
}
