// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TradeManifest} from "./TradeManifest.sol";
import {MercuriOrderFiller, IOrderSwapRouter} from "../src/MercuriOrderFiller.sol";
import {IReactor} from "../lib/uniswapx/src/interfaces/IReactor.sol";
import {V3DutchOrderReactor} from "../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Deploys the immutable MercuriOrderFiller against the reactor named in TRADE_REACTOR.
/// Contains no key: pass --account or --ledger. The reactor fee owner must still parse as an address
/// because the reactor deployment is part of the same release, and the execution fee recipient (the keeper's
/// transaction address) must be chosen in the manifest. Also needs TRADE_REACTOR_CODEHASH.
contract DeployOrderFiller is TradeManifest {
    error ReactorMismatch(string what);

    /// @dev TRADE_REACTOR is operator input, so prove it is the reactor from the reactor step: same permit2, same fee
    /// owner, and runtime code hash equal to TRADE_REACTOR_CODEHASH (the runtime keccak that
    /// `verify-trade-filler.py` prints for the reactor, copied by the operator).
    function _requireReactor(address reactor, address permit2, address feeOwner, bytes32 codeHash) internal view {
        if (reactor.code.length == 0) revert NoCode("reactor", reactor);
        if (reactor.codehash != codeHash) revert ReactorMismatch("codehash");
        if (address(V3DutchOrderReactor(payable(reactor)).permit2()) != permit2) revert ReactorMismatch("permit2");
        if (V3DutchOrderReactor(payable(reactor)).owner() != feeOwner) revert ReactorMismatch("owner");
    }

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
        uint256 executionFee = _executionFee(manifest);
        address feeRecipient = _feeRecipient(manifest);
        _requireReactor(reactor, permit2, feeOwner, vm.envBytes32("TRADE_REACTOR_CODEHASH"));
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
