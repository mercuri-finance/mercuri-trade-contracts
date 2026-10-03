// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {V3DutchOrderReactor} from "../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {TradeManifest} from "./TradeManifest.sol";
import {MercuriOrderFiller} from "../src/MercuriOrderFiller.sol";
import {IOrderSwapRouter} from "../src/interfaces/IOrderSwapRouter.sol";

/// @notice Deploys the immutable MercuriOrderFiller against the reactor named in TRADE_REACTOR. Contains no key: pass
///         `--account` or `--ledger`.
/// @dev The reactor fee owner must be Launch's timelock from Launch's deployment record, because the reactor deployment
///      is part of the same release, and the execution fee recipient (the keeper's transaction address) must be chosen
///      in the manifest. That address is also the only one allowed to call `fill` (spec D20), so it must be the keeper
///      that will submit fills. TRADE_REACTOR_CODEHASH is required as well.
contract DeployOrderFiller is TradeManifest {
    /// @dev TRADE_REACTOR is operator input, so it is proven to be the reactor from the reactor step: same permit2,
    ///      same fee owner, the expected protocol fee controller (zero unless the manifest names one) and runtime code
    ///      hash equal to TRADE_REACTOR_CODEHASH (the runtime keccak that `verify-trade-filler.py` prints for the
    ///      reactor, copied by the operator).
    function _requireReactor(
        address reactor,
        address permit2,
        address feeOwner,
        address feeController,
        bytes32 codeHash
    ) internal view {
        if (reactor.code.length == 0) revert NoCode("reactor", reactor);
        if (reactor.codehash != codeHash) revert ReactorMismatch("codehash");
        V3DutchOrderReactor deployed = V3DutchOrderReactor(payable(reactor));
        if (address(deployed.permit2()) != permit2) revert ReactorMismatch("permit2");
        if (deployed.owner() != feeOwner) revert ReactorMismatch("owner");
        if (address(deployed.feeController()) != feeController) revert ReactorMismatch("feeController");
    }

    function run() external returns (MercuriOrderFiller filler) {
        _requireTestnet();
        string memory manifest = _manifest();
        // Owner choices first: refuse a sentinel before reading anything else. The fee owner is checked on the reactor.
        address feeOwner = _reactorFeeOwner(manifest);
        _requireTimelockOwner(feeOwner, _launchRecord(), _rehearsal());
        address feeRecipient = _feeRecipient(manifest);
        address reactor = vm.envAddress("TRADE_REACTOR");
        address router = _address(manifest, ".router");
        address permit2 = _address(manifest, ".permit2");
        address usdc = _address(manifest, ".usdc");
        address launchHook = _address(manifest, ".launchHook");
        address appRecipient = _address(manifest, ".appRecipient");
        uint256 executionFee = _executionFee(manifest);
        address feeController = _reactorFeeController(manifest);
        _requireReactor(reactor, permit2, feeOwner, feeController, vm.envBytes32("TRADE_REACTOR_CODEHASH"));
        _requireCode("router", router);
        _requireCode("permit2", permit2);
        _requireCode("usdc", usdc);
        _requireCode("launchHook", launchHook);

        vm.startBroadcast();
        filler = new MercuriOrderFiller(
            IReactor(reactor),
            IOrderSwapRouter(router),
            IAllowanceTransfer(permit2),
            usdc,
            launchHook,
            appRecipient,
            executionFee,
            feeRecipient
        );
        vm.stopBroadcast();

        console2.log("reactorFeeOwner", feeOwner);
        console2.log("reactorFeeController", feeController);
        console2.log("reactor", reactor);
        console2.log("router", router);
        console2.log("permit2", permit2);
        console2.log("usdc", usdc);
        console2.log("launchHook", launchHook);
        console2.log("appRecipient", appRecipient);
        console2.log("executionFee", executionFee);
        console2.log("feeRecipient", feeRecipient);
        console2.log("filler", address(filler));
    }
}
