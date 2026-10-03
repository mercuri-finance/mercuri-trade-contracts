// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTestnetReactor} from "../../script/DeployTestnetReactor.s.sol";
import {DeployOrderFiller} from "../../script/DeployOrderFiller.s.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {MercuriOrderValidator} from "../../src/MercuriOrderValidator.sol";
import {IOrderSwapRouter} from "../../src/interfaces/IOrderSwapRouter.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TradeManifest} from "../../script/TradeManifest.sol";
import {V3DutchOrderReactor} from "../../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {MockFeeController} from "../utils/MockFeeController.sol";

/// @dev Exposes the internal decision logic so tests pass inputs directly and never touch process-wide env vars.
contract FillerHarness is DeployOrderFiller {
    function resolve(string memory manifest, bool rehearsal, address override_, bytes memory client)
        external
        view
        returns (address)
    {
        return _resolveFeeOwner(manifest, rehearsal, override_, client);
    }

    function resolveRecipient(string memory manifest, bool rehearsal, address override_, bytes memory client)
        external
        view
        returns (address)
    {
        return _resolveFeeRecipient(manifest, rehearsal, override_, client);
    }

    function fee(string memory manifest) external pure returns (uint256) {
        return _executionFee(manifest);
    }

    function maxFee() external pure returns (uint256) {
        return MAX_EXECUTION_FEE;
    }

    function requireReactor(
        address reactor,
        address permit2,
        address feeOwner,
        address feeController,
        bytes32 codeHash
    ) external view {
        _requireReactor(reactor, permit2, feeOwner, feeController, codeHash);
    }

    function feeController(string memory manifest) external view returns (address) {
        return _reactorFeeController(manifest);
    }

    function requireTimelockOwner(address owner, string memory launchRecord, bool rehearsal) external view {
        _requireTimelockOwner(owner, launchRecord, rehearsal);
    }

    function requireLaunchRecord(string memory manifest, string memory launchRecord) external view {
        _requireLaunchRecord(manifest, launchRecord);
    }

    function requireRouter(address router, string memory manifest) external view {
        _requireRouter(router, manifest);
    }

    function validatorSalt() external pure returns (bytes32) {
        return VALIDATOR_SALT;
    }

    function predict(FillerArgs memory a) external pure returns (address filler, address validator) {
        return _predict(a);
    }

    function deployPair(FillerArgs memory a) external returns (MercuriOrderFiller filler, address validator) {
        return _deployPair(a);
    }

    function requireDeployedPair(MercuriOrderFiller filler, address predicted, address validator, address poolManager)
        external
        view
    {
        _requireDeployedPair(filler, predicted, validator, poolManager);
    }

    function requireCreate2Factory() external view {
        _requireCreate2Factory();
    }
}

/// @dev Exposes the reactor script's post-deployment check.
contract ReactorHarness is DeployTestnetReactor {
    function requireDeployed(V3DutchOrderReactor reactor, address feeOwner, address feeController) external view {
        _requireDeployedReactor(reactor, feeOwner, feeController);
    }
}

/// @notice The deployment scripts must refuse the shipped manifest (sentinel owner) and any other chain, and the
///         rehearsal override must be unreachable outside a loopback anvil.
contract DeployScriptsTest is Test {
    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant SENTINEL = '{"reactorFeeOwner":"REQUIRED_AT_D2_OWNER_GO"}';
    string internal constant CHOSEN = '{"reactorFeeOwner":"0x00000000000000000000000000000000000000cc"}';

    function setUp() public {
        vm.chainId(5042002);
    }

    /// The reactor fee owner is decided (Launch's testnet timelock, read from Launch's record); the keeper address is
    /// still the owner's choice at D3.
    function test_manifestShipsSentinel() public view {
        string memory manifest = vm.readFile("deployments/manifest-5042002.json");
        string memory launchRecord = vm.readFile("lib/mercuri-launch-contracts/deployments/5042002.json");
        assertEq(vm.parseJsonAddress(manifest, ".reactorFeeOwner"), vm.parseJsonAddress(launchRecord, ".timelock"));
        assertEq(vm.parseJsonAddress(manifest, ".reactorFeeOwner"), 0x41129B5215cA24b29a4cABcaE26d3569744DEe2E);
        assertEq(vm.parseJsonString(manifest, ".feeRecipient"), "REQUIRED_AT_D3_OWNER_GO");
        assertEq(vm.parseJsonUint(manifest, ".executionFee"), 50_000);
    }

    function test_feeRecipientSentinelRefused() public {
        FillerHarness h = new FillerHarness();
        string memory manifest = vm.readFile("deployments/manifest-5042002.json");
        vm.expectRevert(TradeManifest.FeeRecipientNotChosen.selector);
        h.resolveRecipient(manifest, false, address(0), "");
        vm.expectRevert(TradeManifest.FeeRecipientNotChosen.selector);
        h.resolveRecipient('{"feeRecipient":"0x0000000000000000000000000000000000000000"}', false, address(0), "");
        assertEq(
            h.resolveRecipient('{"feeRecipient":"0x00000000000000000000000000000000000000dd"}', false, address(0), ""),
            address(0xdd)
        );
        // The rehearsal override is held to the same anvil-only guard as the reactor fee owner.
        vm.expectRevert(TradeManifest.RehearsalNeedsAnvil.selector);
        h.resolveRecipient(manifest, true, ANVIL_1, bytes('"Arc/v1.0"'));
        assertEq(h.resolveRecipient(manifest, true, ANVIL_1, bytes('"anvil/v1.4.3"')), ANVIL_1);
    }

    function test_executionFeeAboveMaxRefused() public {
        FillerHarness h = new FillerHarness();
        assertEq(h.fee('{"executionFee":100000}'), 100_000);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ExecutionFeeTooHigh.selector, 100_001));
        h.fee('{"executionFee":100001}');
    }

    // The scripts read TRADE_LOCAL_REHEARSAL; no test in this contract sets it, so an unset variable means false.
    // A lingering real-shell value is overridden below only for the tests that need a fixed value.
    /// With the decided owner the reactor script deploys a reactor owned by Launch's timelock with no fee controller.
    function test_reactorScriptDeploysWithTimelockOwner() public {
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        vm.etch(PERMIT2, hex"00"); // the script requires code at permit2
        DeployTestnetReactor script = new DeployTestnetReactor();
        V3DutchOrderReactor reactor = script.run();
        assertEq(reactor.owner(), 0x41129B5215cA24b29a4cABcaE26d3569744DEe2E);
        assertEq(address(reactor.feeController()), address(0));
        assertEq(address(reactor.permit2()), PERMIT2);
    }

    /// The filler script still refuses the shipped manifest: the keeper address is a sentinel.
    function test_fillerScriptRefusesShippedManifest() public {
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        DeployOrderFiller script = new DeployOrderFiller();
        vm.expectRevert(TradeManifest.FeeRecipientNotChosen.selector);
        script.run();
    }

    /// TRD-01: any reactor fee owner other than the record's timelock is refused; a rehearsal owner is not checked.
    function test_reactorFeeOwnerMustBeLaunchTimelock() public {
        FillerHarness h = new FillerHarness();
        string memory launchRecord = vm.readFile("lib/mercuri-launch-contracts/deployments/5042002.json");
        address timelock = 0x41129B5215cA24b29a4cABcaE26d3569744DEe2E;
        h.requireTimelockOwner(timelock, launchRecord, false);
        // Launch's testnet treasury (also its guardian and deployer) is not the timelock.
        address treasury = vm.parseJsonAddress(launchRecord, ".treasury");
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorFeeOwnerNotTimelock.selector, treasury, timelock));
        h.requireTimelockOwner(treasury, launchRecord, false);
        // The mainnet timelock is not the testnet one.
        address mainnetTimelock =
            vm.parseJsonAddress(vm.readFile("lib/mercuri-launch-contracts/deployments/5042.json"), ".timelock");
        vm.expectRevert(
            abi.encodeWithSelector(TradeManifest.ReactorFeeOwnerNotTimelock.selector, mainnetTimelock, timelock)
        );
        h.requireTimelockOwner(mainnetTimelock, launchRecord, false);
        h.requireTimelockOwner(ANVIL_1, launchRecord, true);
    }

    /// Constructor arguments that are never called by the constructor; any nonzero addresses work.
    function _args(address poolManager) internal pure returns (DeployOrderFiller.FillerArgs memory a) {
        a = DeployOrderFiller.FillerArgs(
            address(1), address(2), address(3), address(4), address(5), address(6), 50_000, address(7), poolManager
        );
    }

    /// The script's copy of the validator salt must be the filler's, or its prediction would miss.
    function test_scriptValidatorSaltMatchesFiller() public {
        MercuriOrderFiller filler = new MercuriOrderFiller(
            IReactor(address(1)),
            IOrderSwapRouter(address(2)),
            IAllowanceTransfer(address(3)),
            address(4),
            address(5),
            address(6),
            0,
            address(7),
            IPoolManager(address(8))
        );
        assertEq(new FillerHarness().validatorSalt(), filler.VALIDATOR_SALT());
    }

    /// The standard CREATE2 deployer must hold its known runtime; any other code is refused.
    function test_create2FactoryCodeRequired() public {
        FillerHarness h = new FillerHarness();
        assertEq(CREATE2_FACTORY.codehash, 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989);
        h.requireCreate2Factory();
        vm.etch(CREATE2_FACTORY, hex"00");
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.Create2FactoryMismatch.selector, keccak256(hex"00")));
        h.requireCreate2Factory();
    }

    /// The script's deployment lands the filler at its CREATE2 prediction from the standard deployer and the validator
    /// at its prediction from the filler, each naming the other; a second run refuses the occupied address.
    function test_deployPairLandsAtPrediction() public {
        FillerHarness h = new FillerHarness();
        DeployOrderFiller.FillerArgs memory a = _args(address(8));
        (address predictedFiller, address predictedValidator) = h.predict(a);
        (MercuriOrderFiller filler, address validator) = h.deployPair(a);
        assertEq(address(filler), predictedFiller, "filler at its prediction");
        assertEq(validator, predictedValidator, "validator at its prediction");
        assertEq(address(filler.validator()), predictedValidator);
        assertEq(MercuriOrderValidator(validator).filler(), address(filler));
        assertEq(address(MercuriOrderValidator(validator).poolManager()), address(8));
        // Any change to an argument moves both addresses.
        (address otherFiller, address otherValidator) = h.predict(_args(address(9)));
        assertTrue(otherFiller != predictedFiller && otherValidator != predictedValidator);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.AlreadyDeployed.selector, predictedFiller));
        h.deployPair(a);
    }

    /// The post-deployment check refuses a filler off its prediction, a validator other than the filler's own and a
    /// validator bound to another pool manager.
    function test_deployedPairMismatchRefused() public {
        FillerHarness h = new FillerHarness();
        MercuriOrderFiller filler = new MercuriOrderFiller(
            IReactor(address(1)),
            IOrderSwapRouter(address(2)),
            IAllowanceTransfer(address(3)),
            address(4),
            address(5),
            address(6),
            0,
            address(7),
            IPoolManager(address(8))
        );
        address validator = address(filler.validator());
        h.requireDeployedPair(filler, address(filler), validator, address(8));
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "filler address"));
        h.requireDeployedPair(filler, address(0xf1), validator, address(8));
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "validator address"));
        h.requireDeployedPair(filler, address(filler), address(0xf2), address(8));
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "validator poolManager"));
        h.requireDeployedPair(filler, address(filler), validator, address(9));
    }

    /// The script's copy of the bound must never drift from the filler's, or a manifest could pass here and fail
    /// the constructor (or the reverse) at deployment time.
    function test_scriptMaxExecutionFeeMatchesFiller() public {
        // IReactor, IOrderSwapRouter and IAllowanceTransfer are never called by the constructor; any non-zero address works.
        MercuriOrderFiller filler = new MercuriOrderFiller(
            IReactor(address(1)),
            IOrderSwapRouter(address(2)),
            IAllowanceTransfer(address(3)),
            address(4),
            address(5),
            address(6),
            0,
            address(7),
            IPoolManager(address(8))
        );
        assertEq(new FillerHarness().maxFee(), filler.MAX_EXECUTION_FEE());
    }

    function test_sentinelResolverRefuses() public {
        FillerHarness h = new FillerHarness();
        vm.expectRevert(TradeManifest.ReactorFeeOwnerNotChosen.selector);
        h.resolve(SENTINEL, false, address(0), "");
    }

    function test_malformedOwnerResolverRefuses() public {
        FillerHarness h = new FillerHarness();
        vm.expectRevert(TradeManifest.ReactorFeeOwnerNotChosen.selector);
        h.resolve('{"reactorFeeOwner":"0xnothex0000000000000000000000000000000000"}', false, address(0), "");
        vm.expectRevert(TradeManifest.ReactorFeeOwnerNotChosen.selector);
        h.resolve('{"reactorFeeOwner":"0x0000000000000000000000000000000000000000"}', false, address(0), "");
    }

    function test_addressResolverAccepts() public {
        FillerHarness h = new FillerHarness();
        assertEq(h.resolve(CHOSEN, false, address(0), ""), address(0xcc));
    }

    function test_overrideNeedsAnvilClient() public {
        FillerHarness h = new FillerHarness();
        vm.expectRevert(TradeManifest.RehearsalNeedsAnvil.selector);
        h.resolve(SENTINEL, true, ANVIL_1, bytes('"Arc/v1.0"'));
    }

    function test_overrideNeedsAnvilDevAccount() public {
        FillerHarness h = new FillerHarness();
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.RehearsalOwnerNotAnvilAccount.selector, address(0xcc)));
        h.resolve(SENTINEL, true, address(0xcc), bytes('"anvil/v1.4.3"'));
    }

    function test_overrideAcceptedOnAnvilWithDevAccount() public {
        FillerHarness h = new FillerHarness();
        assertEq(h.resolve(SENTINEL, true, ANVIL_1, bytes('"anvil/v1.4.3"')), ANVIL_1);
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

    function test_fillerRefusesWrongReactor() public {
        FillerHarness h = new FillerHarness();
        V3DutchOrderReactor reactor = new V3DutchOrderReactor(IPermit2(PERMIT2), ANVIL_1);
        bytes32 hash = address(reactor).codehash;
        h.requireReactor(address(reactor), PERMIT2, ANVIL_1, address(0), hash); // accepted

        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "codehash"));
        h.requireReactor(address(reactor), PERMIT2, ANVIL_1, address(0), bytes32(uint256(1)));

        // Any other contract, such as the harness itself, is not the reactor.
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "codehash"));
        h.requireReactor(address(h), PERMIT2, ANVIL_1, address(0), hash);

        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "permit2"));
        h.requireReactor(address(reactor), address(0xdead), ANVIL_1, address(0), hash);

        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "owner"));
        h.requireReactor(address(reactor), PERMIT2, address(0xbeef), address(0), hash);

        vm.expectRevert(abi.encodeWithSelector(TradeManifest.NoCode.selector, "reactor", address(0xabc)));
        h.requireReactor(address(0xabc), PERMIT2, ANVIL_1, address(0), hash);

        // F2: a reactor whose owner has set a protocol fee controller is refused unless the manifest names it.
        address controller = address(new MockFeeController(address(0xfee), 5, false));
        vm.prank(ANVIL_1);
        reactor.setProtocolFeeController(controller);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "feeController"));
        h.requireReactor(address(reactor), PERMIT2, ANVIL_1, address(0), hash);
        h.requireReactor(address(reactor), PERMIT2, ANVIL_1, controller, hash); // accepted when expected
    }

    /// The manifest's `reactorFeeController` defaults to zero, must be an address when present, and ships as zero.
    function test_reactorFeeControllerManifestValue() public {
        FillerHarness h = new FillerHarness();
        assertEq(h.feeController("{}"), address(0));
        assertEq(h.feeController(vm.readFile("deployments/manifest-5042002.json")), address(0));
        assertEq(
            h.feeController('{"reactorFeeController":"0x00000000000000000000000000000000000000ee"}'), address(0xee)
        );
        vm.expectRevert(TradeManifest.ReactorFeeControllerNotAddress.selector);
        h.feeController('{"reactorFeeController":"none"}');
    }

    /// The reactor script checks the reactor it just deployed: owner and fee controller as chosen.
    function test_reactorScriptChecksDeployedReactor() public {
        ReactorHarness h = new ReactorHarness();
        V3DutchOrderReactor reactor = new V3DutchOrderReactor(IPermit2(PERMIT2), ANVIL_1);
        h.requireDeployed(reactor, ANVIL_1, address(0));
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "owner"));
        h.requireDeployed(reactor, address(0xbeef), address(0));
        address controller = address(new MockFeeController(address(0xfee), 5, false));
        vm.prank(ANVIL_1);
        reactor.setProtocolFeeController(controller);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "feeController"));
        h.requireDeployed(reactor, ANVIL_1, address(0));
        h.requireDeployed(reactor, ANVIL_1, controller);
    }

    string internal constant TESTNET_RECORD = "lib/mercuri-launch-contracts/deployments/5042002.json";
    string internal constant MAINNET_RECORD = "lib/mercuri-launch-contracts/deployments/5042.json";

    /// F5: both manifests agree with Launch's record for their chain: permit2, USDC, the Launch hook, the treasury as
    /// app fee recipient and the timelock as reactor fee owner.
    function test_manifestsMatchLaunchRecords() public {
        FillerHarness h = new FillerHarness();
        string memory record = vm.readFile(TESTNET_RECORD);
        string memory manifest = vm.readFile("deployments/manifest-5042002.json");
        h.requireLaunchRecord(manifest, record);
        h.requireTimelockOwner(vm.parseJsonAddress(manifest, ".reactorFeeOwner"), record, false);
        vm.chainId(5042);
        record = vm.readFile(MAINNET_RECORD);
        manifest = vm.readFile("deployments/manifest-5042.json");
        h.requireLaunchRecord(manifest, record);
        h.requireTimelockOwner(vm.parseJsonAddress(manifest, ".reactorFeeOwner"), record, false);
    }

    /// Each Launch-side manifest input that differs from Launch's record is refused by name, as is a manifest or
    /// record for another chain.
    function test_launchRecordMismatchRefused() public {
        FillerHarness h = new FillerHarness();
        string memory record = vm.readFile(TESTNET_RECORD);
        string memory manifest = vm.readFile("deployments/manifest-5042002.json");
        string[5] memory keys = ["permit2", "usdc", "launchHook", "poolManager", "appRecipient"];
        for (uint256 i; i < 5; ++i) {
            string memory value = vm.parseJsonString(manifest, string.concat(".", keys[i]));
            string memory tampered = vm.replace(manifest, value, "0x00000000000000000000000000000000000000Ab");
            vm.expectRevert(abi.encodeWithSelector(TradeManifest.LaunchRecordMismatch.selector, keys[i]));
            h.requireLaunchRecord(tampered, record);
        }
        // The testnet manifest against the mainnet record, and either one on the wrong chain.
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.LaunchRecordMismatch.selector, "record chainId"));
        h.requireLaunchRecord(manifest, vm.readFile(MAINNET_RECORD));
        vm.chainId(5042);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.LaunchRecordMismatch.selector, "manifest chainId"));
        h.requireLaunchRecord(manifest, vm.readFile(MAINNET_RECORD));
    }

    /// The mainnet manifest exists for review only: its owner choices are sentinels, its reactor fee owner is
    /// Launch's mainnet timelock, and the scripts still refuse chain 5042 (`test_scriptsRefuseOtherChains`). Spec D27:
    /// mainnet uses our own reactor, deployed by the reactor step and owned by that timelock; the manifest names no
    /// existing reactor, so the Uniswap-owned mainnet reactor can never be taken for ours.
    function test_mainnetManifestIsReviewOnly() public view {
        string memory manifest = vm.readFile("deployments/manifest-5042.json");
        assertEq(vm.parseJsonUint(manifest, ".chainId"), 5042);
        assertEq(vm.parseJsonString(manifest, ".executionFee"), "REQUIRED_AT_MAINNET_OWNER_GO");
        assertEq(vm.parseJsonString(manifest, ".feeRecipient"), "REQUIRED_AT_MAINNET_OWNER_GO");
        assertEq(
            vm.parseJsonAddress(manifest, ".reactorFeeOwner"),
            vm.parseJsonAddress(vm.readFile(MAINNET_RECORD), ".timelock")
        );
        assertEq(vm.parseJsonAddress(manifest, ".reactorFeeController"), address(0));
        assertFalse(vm.keyExistsJson(manifest, ".reactor"), "the mainnet reactor is deployed by us, not named");
        assertEq(
            vm.parseJsonAddress(manifest, ".poolManager"),
            vm.parseJsonAddress(vm.readFile(MAINNET_RECORD), ".poolManager")
        );
    }

    /// The router is pinned by code hash: the right runtime passes, any other runtime or an empty account is refused.
    function test_routerCodeHashRequired() public {
        FillerHarness h = new FillerHarness();
        address router = address(new ReactorHarness());
        string memory manifest = string.concat('{"routerCodeHash":"', vm.toString(router.codehash), '"}');
        h.requireRouter(router, manifest);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.RouterMismatch.selector, "codehash"));
        h.requireRouter(address(h), manifest);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.NoCode.selector, "router", address(0xabc)));
        h.requireRouter(address(0xabc), manifest);
        // The shipped testnet hash is the reproduced Arc testnet router, not any local build.
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.RouterMismatch.selector, "codehash"));
        h.requireRouter(router, vm.readFile("deployments/manifest-5042002.json"));
    }
}
