// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TradeManifest} from "./TradeManifest.sol";
import {MercuriOrderFiller, IOrderSwapRouter} from "../src/MercuriOrderFiller.sol";
import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Deploys the immutable MercuriOrderFiller against the reactor named in TRADE_REACTOR.
/// Contains no key: pass --account or --ledger. The reactor fee owner must still parse as an address
/// because the reactor deployment is part of the same release.
contract DeployOrderFiller is TradeManifest {
    function run() external returns (MercuriOrderFiller filler) {
        _requireTestnet();
        string memory manifest = _manifest();
        // Refuse to run while the owner choice is still the sentinel, even though the filler does not use it.
        address feeOwner = _reactorFeeOwner(manifest);
        address reactor = vm.envAddress("TRADE_REACTOR");
        address router = _address(manifest, ".router");
        address permit2 = _address(manifest, ".permit2");
        address usdc = _address(manifest, ".usdc");
        address launchHook = _address(manifest, ".launchHook");
        address appRecipient = _address(manifest, ".appRecipient");
        _requireCode("reactor", reactor);
        _requireCode("router", router);
        _requireCode("permit2", permit2);
        _requireCode("usdc", usdc);
        _requireCode("launchHook", launchHook);

        vm.startBroadcast();
        filler = new MercuriOrderFiller(
            IReactor(reactor), IOrderSwapRouter(router), IAllowanceTransfer(permit2), usdc, launchHook, appRecipient
        );
        vm.stopBroadcast();

        console2.log("reactorFeeOwner", feeOwner);
        console2.log("reactor", reactor);
        console2.log("router", router);
        console2.log("permit2", permit2);
        console2.log("usdc", usdc);
        console2.log("launchHook", launchHook);
        console2.log("appRecipient", appRecipient);
        console2.log("filler", address(filler));
    }
}
