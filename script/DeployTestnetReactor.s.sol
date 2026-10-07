// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {V3DutchOrderReactor} from "../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IPermit2} from "../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {TradeManifest} from "./TradeManifest.sol";

/// @notice Deploys the pinned UniswapX V3 Dutch reactor on Arc testnet or Arc mainnet, the network the RPC reports.
///         Contains no key: pass `--account` or `--ledger`.
/// @dev Named for the network it first deployed on; its broadcast files and record tooling keep the name.
/// @dev After deployment the reactor must have the manifest's runtime code hash (`reactorCodeHash`) and report the
///      manifest's fee owner and protocol fee controller (zero unless the manifest names one), or the run reverts
///      before anything is broadcast.
contract DeployTestnetReactor is TradeManifest {
    function run() external returns (V3DutchOrderReactor reactor) {
        _requireArc();
        string memory manifest = _manifest();
        address permit2 = _address(manifest, ".permit2");
        string memory launchRecord = _launchRecord();
        _requireLaunchRecord(manifest, launchRecord);
        address feeOwner = _reactorFeeOwner(manifest);
        _requireTimelockOwner(feeOwner, launchRecord, _rehearsal());
        address feeController = _reactorFeeController(manifest);
        bytes32 codeHash = _reactorCodeHash(manifest);
        _requireCode("permit2", permit2);

        vm.startBroadcast();
        reactor = _newReactor(permit2, feeOwner);
        vm.stopBroadcast();
        _requireDeployedReactor(reactor, feeOwner, feeController, codeHash);
        // Optional: the address the runbook expects (the deployer's next CREATE). A stray deployer transaction first
        // would move the reactor; with EXPECTED_REACTOR set the run reverts before anything is broadcast.
        address expected = vm.envOr("EXPECTED_REACTOR", address(0));
        if (expected != address(0) && address(reactor) != expected) {
            revert UnexpectedReactor(address(reactor), expected);
        }

        console2.log("permit2", permit2);
        console2.log("reactorFeeOwner", feeOwner);
        console2.log("reactorFeeController", feeController);
        console2.log("reactor", address(reactor));
    }

    /// @dev The one reactor deployment, with the creation code this script was built with.
    function _newReactor(address permit2, address feeOwner) internal returns (V3DutchOrderReactor) {
        return new V3DutchOrderReactor(IPermit2(permit2), feeOwner);
    }

    /// @dev The reactor as deployed must have the pinned runtime and the chosen owner and fee controller, so a build
    ///      that would deploy other reactor code (another compiler profile, say) fails here instead of at the filler
    ///      step. Forge simulates the whole script before broadcasting, so a failure here sends nothing.
    function _requireDeployedReactor(
        V3DutchOrderReactor reactor,
        address feeOwner,
        address feeController,
        bytes32 codeHash
    ) internal view {
        if (address(reactor).codehash != codeHash) revert ReactorMismatch("codehash");
        if (reactor.owner() != feeOwner) revert ReactorMismatch("owner");
        if (address(reactor.feeController()) != feeController) revert ReactorMismatch("feeController");
    }
}
