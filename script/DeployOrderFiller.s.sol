// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {V3DutchOrderReactor} from "../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {TradeManifest} from "./TradeManifest.sol";
import {MercuriOrderFiller} from "../src/MercuriOrderFiller.sol";
import {MercuriOrderValidator} from "../src/MercuriOrderValidator.sol";
import {IOrderSwapRouter} from "../src/interfaces/IOrderSwapRouter.sol";

/// @notice Deploys the immutable MercuriOrderFiller, and with it its MercuriOrderValidator, against the reactor named
///         in TRADE_REACTOR. Contains no key: pass `--account` or `--ledger`.
/// @dev The reactor fee owner must be Launch's timelock from Launch's deployment record, because the reactor deployment
///      is part of the same release, and the execution fee recipient (the keeper's transaction address) must be chosen
///      in the manifest. That address is also the only one allowed to call `fill` (spec D20), so it must be the keeper
///      that will submit fills. TRADE_REACTOR_CODEHASH is required as well. The filler goes through the standard
///      CREATE2 deployer with `FILLER_SALT` and its constructor deploys the validator with CREATE2 from the filler, so
///      both addresses are predicted before the broadcast and the run reverts unless the deployment lands exactly
///      there, with the validator bound to this filler and the manifest's PoolManager.
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

    /// @dev The filler's constructor arguments, in order.
    struct FillerArgs {
        address reactor;
        address router;
        address permit2;
        address usdc;
        address launchHook;
        address appRecipient;
        uint256 executionFee;
        address feeRecipient;
        address poolManager;
    }

    /// @dev The filler's creation code with its constructor arguments, as the CREATE2 deployer receives it.
    function _fillerInitCode(FillerArgs memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(MercuriOrderFiller).creationCode,
            abi.encode(
                a.reactor,
                a.router,
                a.permit2,
                a.usdc,
                a.launchHook,
                a.appRecipient,
                a.executionFee,
                a.feeRecipient,
                a.poolManager
            )
        );
    }

    /// @dev The filler's address from the standard CREATE2 deployer, and the validator's from that filler.
    function _predict(FillerArgs memory a) internal pure returns (address filler, address validator) {
        filler = vm.computeCreate2Address(FILLER_SALT, keccak256(_fillerInitCode(a)), CREATE2_FACTORY);
        validator = _predictValidator(filler, a.poolManager);
    }

    /// @dev The validator a filler at `filler` deploys: CREATE2 from the filler with its `VALIDATOR_SALT`.
    function _predictValidator(address filler, address poolManager) internal pure returns (address) {
        bytes memory initCode =
            abi.encodePacked(type(MercuriOrderValidator).creationCode, abi.encode(filler, poolManager));
        return vm.computeCreate2Address(VALIDATOR_SALT, keccak256(initCode), filler);
    }

    /// @dev Both contracts must be at their predicted addresses and name each other: the filler's `validator` is the
    ///      predicted validator, whose `filler` is this filler and whose `poolManager` is the manifest's. Forge
    ///      simulates the whole script before broadcasting, so a failure here sends nothing.
    function _requireDeployedPair(
        MercuriOrderFiller filler,
        address predictedFiller,
        address predictedValidator,
        address poolManager
    ) internal view {
        if (address(filler) != predictedFiller) revert DeploymentMismatch("filler address");
        if (address(filler.validator()) != predictedValidator) revert DeploymentMismatch("validator address");
        if (predictedValidator.code.length == 0) revert NoCode("validator", predictedValidator);
        MercuriOrderValidator validator = MercuriOrderValidator(predictedValidator);
        if (validator.filler() != address(filler)) revert DeploymentMismatch("validator filler");
        if (address(validator.poolManager()) != poolManager) revert DeploymentMismatch("validator poolManager");
    }

    /// @dev Predicts both addresses, refuses an occupied filler address, deploys the filler (and with it the
    ///      validator) through the standard CREATE2 deployer, and requires the pair to be exactly as predicted.
    function _deployPair(FillerArgs memory a) internal returns (MercuriOrderFiller filler, address validator) {
        _requireCreate2Factory();
        address predictedFiller;
        (predictedFiller, validator) = _predict(a);
        if (predictedFiller.code.length != 0) revert AlreadyDeployed(predictedFiller);
        vm.startBroadcast();
        filler = new MercuriOrderFiller{salt: FILLER_SALT}(
            IReactor(a.reactor),
            IOrderSwapRouter(a.router),
            IAllowanceTransfer(a.permit2),
            a.usdc,
            a.launchHook,
            a.appRecipient,
            a.executionFee,
            a.feeRecipient,
            IPoolManager(a.poolManager)
        );
        vm.stopBroadcast();
        _requireDeployedPair(filler, predictedFiller, validator, a.poolManager);
    }

    function run() external returns (MercuriOrderFiller filler) {
        _requireTestnet();
        string memory manifest = _manifest();
        string memory launchRecord = _launchRecord();
        _requireLaunchRecord(manifest, launchRecord);
        // Owner choices next: refuse a sentinel before reading TRADE_REACTOR. The fee owner is checked on the reactor.
        address feeOwner = _reactorFeeOwner(manifest);
        _requireTimelockOwner(feeOwner, launchRecord, _rehearsal());
        FillerArgs memory a;
        a.feeRecipient = _feeRecipient(manifest);
        a.reactor = vm.envAddress("TRADE_REACTOR");
        a.router = _address(manifest, ".router");
        a.permit2 = _address(manifest, ".permit2");
        a.usdc = _address(manifest, ".usdc");
        a.launchHook = _address(manifest, ".launchHook");
        a.appRecipient = _address(manifest, ".appRecipient");
        a.poolManager = _address(manifest, ".poolManager");
        a.executionFee = _executionFee(manifest);
        address feeController = _reactorFeeController(manifest);
        _requireReactor(a.reactor, a.permit2, feeOwner, feeController, vm.envBytes32("TRADE_REACTOR_CODEHASH"));
        _requireRouter(a.router, manifest);
        _requireCode("permit2", a.permit2);
        _requireCode("usdc", a.usdc);
        _requireCode("launchHook", a.launchHook);
        _requireCode("poolManager", a.poolManager);
        address validator;
        (filler, validator) = _deployPair(a);

        console2.log("reactorFeeOwner", feeOwner);
        console2.log("reactorFeeController", feeController);
        console2.log("reactor", a.reactor);
        console2.log("router", a.router);
        console2.log("permit2", a.permit2);
        console2.log("usdc", a.usdc);
        console2.log("launchHook", a.launchHook);
        console2.log("appRecipient", a.appRecipient);
        console2.log("executionFee", a.executionFee);
        console2.log("feeRecipient", a.feeRecipient);
        console2.log("poolManager", a.poolManager);
        console2.log("filler", address(filler));
        console2.log("validator", validator);
    }
}
