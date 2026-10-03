// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployOrderFiller} from "../../script/DeployOrderFiller.s.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {MercuriOrderValidator} from "../../src/MercuriOrderValidator.sol";
import {V3DutchOrderReactor} from "../../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {FillerHarness} from "./DeployScripts.t.sol";

/// @notice Spec D22's deployment cycle on a read-only Arc fork (no transaction reaches the network): the standard
///         CREATE2 deployer holds its known runtime, and the script's deployment of the filler lands it and its
///         validator exactly at the addresses predicted before the broadcast, each naming the other and the recorded
///         PoolManager. The reactor is deployed locally (testnet has none; spec D27 deploys our own on both networks).
contract DeployOrdersForkTest is Test {
    uint256 private chain;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_LOCAL_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        chain = vm.envOr("TRADE_FORK_CHAIN_ID", uint256(5042002));
        require(chain == 5042002 || chain == 5042, "unsupported fork chain");
        vm.createSelectFork(rpc, vm.envOr("TRADE_FORK_BLOCK", chain == 5042 ? uint256(23084816) : uint256(64325644)));
        assertEq(block.chainid, chain);
    }

    function test_create2PredictionOnArcFork() public {
        string memory manifest =
            vm.readFile(chain == 5042 ? "deployments/manifest-5042.json" : "deployments/manifest-5042002.json");
        string memory record =
            vm.readFile(string.concat("lib/mercuri-launch-contracts/deployments/", vm.toString(chain), ".json"));
        FillerHarness h = new FillerHarness();
        assertEq(CREATE2_FACTORY.codehash, 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989);
        h.requireCreate2Factory();
        address permit2 = vm.parseJsonAddress(manifest, ".permit2");
        address poolManager = vm.parseJsonAddress(manifest, ".poolManager");
        assertEq(poolManager, vm.parseJsonAddress(record, ".poolManager"));
        assertGt(poolManager.code.length, 0, "PoolManager on the fork");
        V3DutchOrderReactor reactor =
            new V3DutchOrderReactor(IPermit2(permit2), vm.parseJsonAddress(record, ".timelock"));
        DeployOrderFiller.FillerArgs memory a = DeployOrderFiller.FillerArgs(
            address(reactor),
            vm.parseJsonAddress(manifest, ".router"),
            permit2,
            vm.parseJsonAddress(manifest, ".usdc"),
            vm.parseJsonAddress(manifest, ".launchHook"),
            vm.parseJsonAddress(manifest, ".appRecipient"),
            chain == 5042 ? 30_000 : vm.parseJsonUint(manifest, ".executionFee"), // mainnet's fee is an owner choice
            makeAddr("keeper"), // the keeper address is an owner choice (sentinel in both manifests)
            poolManager
        );
        (address predictedFiller, address predictedValidator) = h.predict(a);
        assertEq(predictedFiller.code.length, 0, "filler address free on the fork");
        assertEq(predictedValidator.code.length, 0, "validator address free on the fork");
        (MercuriOrderFiller filler, address validator) = h.deployPair(a);
        assertEq(address(filler), predictedFiller);
        assertEq(validator, predictedValidator);
        assertEq(address(filler.validator()), validator);
        assertEq(MercuriOrderValidator(validator).filler(), address(filler));
        assertEq(address(MercuriOrderValidator(validator).poolManager()), poolManager);
        assertEq(filler.feeRecipient(), a.feeRecipient);
        assertEq(address(filler.reactor()), address(reactor));
        emit log_named_address("predicted filler", predictedFiller);
        emit log_named_address("predicted validator", predictedValidator);
    }
}
