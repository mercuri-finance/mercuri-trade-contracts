// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {V3DutchOrderReactor} from "../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IPermit2} from "../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {TradeManifest} from "./TradeManifest.sol";

/// @notice Deploys the pinned UniswapX V3 Dutch reactor on Arc testnet. Contains no key: pass --account or --ledger.
contract DeployTestnetReactor is TradeManifest {
    function run() external returns (V3DutchOrderReactor reactor) {
        _requireTestnet();
        string memory manifest = _manifest();
        address permit2 = _address(manifest, ".permit2");
        address feeOwner = _reactorFeeOwner(manifest);
        _requireCode("permit2", permit2);

        vm.startBroadcast();
        reactor = new V3DutchOrderReactor(IPermit2(permit2), feeOwner);
        vm.stopBroadcast();

        console2.log("permit2", permit2);
        console2.log("reactorFeeOwner", feeOwner);
        console2.log("reactor", address(reactor));
    }
}
