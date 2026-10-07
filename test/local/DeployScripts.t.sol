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
    function requireArcOrAnvilNode(bytes memory client) external pure {
        _requireArcOrAnvilNode(client);
    }

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

    function fillerInitCode(FillerArgs memory a) external pure returns (bytes memory) {
        return _fillerInitCode(a);
    }

    function reactorCodeHash(string memory manifest) external pure returns (bytes32) {
        return _reactorCodeHash(manifest);
    }
}

/// @dev The filler script itself, run end to end against a manifest fixture instead of the shipped manifest, so a
///      test can put a sentinel or another keeper in it. Everything else in `run()` is the production code path.
contract FillerRunHarness is DeployOrderFiller {
    string internal fixture;

    constructor(string memory manifest) {
        fixture = manifest;
    }

    function _manifest() internal view override returns (string memory) {
        return fixture;
    }
}

/// @dev Exposes the reactor script's post-deployment check.
contract ReactorHarness is DeployTestnetReactor {
    function requireDeployed(V3DutchOrderReactor reactor, address feeOwner, address feeController, bytes32 codeHash)
        external
        view
    {
        _requireDeployedReactor(reactor, feeOwner, feeController, codeHash);
    }

    function newReactor(address permit2, address feeOwner) external returns (V3DutchOrderReactor) {
        return _newReactor(permit2, feeOwner);
    }
}

/// @notice The deployment scripts must refuse a manifest whose owner choices are sentinels and any other chain, and
///         the rehearsal override must be unreachable outside a loopback anvil.
contract DeployScriptsTest is Test {
    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant SENTINEL = '{"reactorFeeOwner":"REQUIRED_AT_D2_OWNER_GO"}';
    string internal constant CHOSEN = '{"reactorFeeOwner":"0x00000000000000000000000000000000000000cc"}';
    /// @dev The testnet keeper's transaction address, the owner's D3 choice recorded in the testnet manifest.
    address internal constant TESTNET_KEEPER = 0xFFEd2F02Ec860fFF1523375Fb253f0Bb0B7b2Efd;
    /// @dev The mainnet keeper's transaction address, the owner's choice of 7 Oct 2026 in the mainnet manifest (the
    ///      address of the mainnet keeper's KMS key).
    address internal constant MAINNET_KEEPER = 0x224d6A194CD27e1a9e84ebe2A35Ad6eC81361eF0;
    string internal constant RECIPIENT_SENTINEL = "REQUIRED_AT_D3_OWNER_GO";

    function setUp() public {
        vm.chainId(5042002);
    }

    /// @dev The shipped testnet manifest with its keeper replaced by the D3 sentinel: a manifest whose keeper choice
    ///      is still pending, which the shipped one no longer is.
    function _pendingKeeperManifest() internal view returns (string memory) {
        string memory shipped = vm.readFile("deployments/manifest-5042002.json");
        string memory pending = vm.replace(shipped, vm.toString(TESTNET_KEEPER), RECIPIENT_SENTINEL);
        assertEq(vm.parseJsonString(pending, ".feeRecipient"), RECIPIENT_SENTINEL, "fixture carries the sentinel");
        return pending;
    }

    /// The testnet owner choices are made: the reactor fee owner is Launch's testnet timelock (read from Launch's
    /// record) and the keeper is the testnet keeper, written checksummed. The mainnet choices are in
    /// `test_mainnetManifestShipsOwnerChoices`.
    function test_manifestShipsOwnerChoices() public view {
        string memory manifest = vm.readFile("deployments/manifest-5042002.json");
        string memory launchRecord = vm.readFile("lib/mercuri-launch-contracts/deployments/5042002.json");
        assertEq(vm.parseJsonAddress(manifest, ".reactorFeeOwner"), vm.parseJsonAddress(launchRecord, ".timelock"));
        assertEq(vm.parseJsonAddress(manifest, ".reactorFeeOwner"), 0x41129B5215cA24b29a4cABcaE26d3569744DEe2E);
        assertEq(vm.parseJsonAddress(manifest, ".feeRecipient"), TESTNET_KEEPER);
        // `vm.toString(address)` is the EIP-55 checksummed form, so the manifest's text must be exactly that.
        assertEq(vm.parseJsonString(manifest, ".feeRecipient"), vm.toString(TESTNET_KEEPER), "keeper not checksummed");
        assertTrue(TESTNET_KEEPER != address(0));
        assertEq(vm.parseJsonUint(manifest, ".executionFee"), 50_000);
    }

    /// A sentinel or zero keeper is refused; the shipped testnet keeper and any other address resolve to themselves.
    function test_feeRecipientSentinelRefused() public {
        FillerHarness h = new FillerHarness();
        string memory manifest = _pendingKeeperManifest();
        vm.expectRevert(TradeManifest.FeeRecipientNotChosen.selector);
        h.resolveRecipient(manifest, false, address(0), "");
        assertEq(
            h.resolveRecipient(vm.readFile("deployments/manifest-5042.json"), false, address(0), ""), MAINNET_KEEPER
        );
        assertEq(
            h.resolveRecipient(vm.readFile("deployments/manifest-5042002.json"), false, address(0), ""), TESTNET_KEEPER
        );
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

    /// The filler script refuses a manifest whose keeper is still a sentinel, before it reads TRADE_REACTOR.
    function test_fillerScriptRefusesSentinelManifest() public {
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        FillerRunHarness script = new FillerRunHarness(_pendingKeeperManifest());
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
        // A second run finds its own identical pair and adopts it (C-05) rather than failing.
        (MercuriOrderFiller again, address againValidator) = h.deployPair(a);
        assertEq(address(again), predictedFiller);
        assertEq(againValidator, predictedValidator);
    }

    /// The pair a copier lands by replaying the init code through the public CREATE2 deployer.
    function _copierDeploys(FillerHarness h, DeployOrderFiller.FillerArgs memory a) internal {
        vm.prank(makeAddr("copier"));
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(bytes32(0), h.fillerInitCode(a)));
        assertTrue(ok, "copier's CREATE2");
    }

    /// C-05 (re-audit of 5 Oct 2026): someone replays the filler's init code through the standard deployer before the
    /// operator. The pair is byte-identical, so the script adopts it, sends nothing, and the result is the pair it
    /// would have deployed.
    function test_deployPairAdoptsIdenticalPredeployedPair() public {
        FillerHarness h = new FillerHarness();
        DeployOrderFiller.FillerArgs memory a = _args(address(8));
        (address predictedFiller, address predictedValidator) = h.predict(a);
        _copierDeploys(h, a);
        assertGt(predictedFiller.code.length, 0, "copier landed the filler");
        assertGt(predictedValidator.code.length, 0, "and its validator");
        bytes32 fillerHash = predictedFiller.codehash;
        bytes32 validatorHash = predictedValidator.codehash;
        uint64 factoryNonce = vm.getNonce(CREATE2_FACTORY);
        vm.recordLogs();
        (MercuriOrderFiller filler, address validator) = h.deployPair(a);
        assertEq(address(filler), predictedFiller);
        assertEq(validator, predictedValidator);
        assertEq(predictedFiller.codehash, fillerHash, "untouched");
        assertEq(predictedValidator.codehash, validatorHash, "untouched");
        assertEq(vm.getNonce(CREATE2_FACTORY), factoryNonce, "nothing went through the deployer");
        assertEq(address(filler.validator()), validator);
        assertEq(MercuriOrderValidator(validator).filler(), address(filler));
        // The same args through a fresh deployment give the same code: the adopted pair is what we would deploy.
        uint256 snapshot = vm.snapshotState();
        vm.etch(predictedFiller, "");
        vm.etch(predictedValidator, "");
        vm.resetNonce(predictedFiller);
        vm.resetNonce(predictedValidator);
        (MercuriOrderFiller fresh, address freshValidator) = h.deployPair(a);
        assertEq(address(fresh), predictedFiller);
        assertEq(address(fresh).codehash, fillerHash, "fresh filler runtime equals the adopted one");
        assertEq(freshValidator.codehash, validatorHash, "fresh validator runtime equals the adopted one");
        vm.revertToState(snapshot);
    }

    /// Any code at the predicted addresses other than exactly the expected pair is refused by name: unrelated code, a
    /// filler built with other immutables, the right filler without its validator, the right filler with a validator
    /// bound to another pool manager, and an occupied validator address while the filler's is free.
    function test_deployPairRefusesDifferentPredeployedPair() public {
        FillerHarness h = new FillerHarness();
        DeployOrderFiller.FillerArgs memory a = _args(address(8));
        (address predictedFiller, address predictedValidator) = h.predict(a);
        // The genuine runtimes, from a copier's deployment that is then rolled back.
        uint256 snapshot = vm.snapshotState();
        _copierDeploys(h, a);
        bytes memory fillerCode = predictedFiller.code;
        bytes memory validatorCode = predictedValidator.code;
        vm.revertToState(snapshot);
        assertEq(predictedFiller.code.length, 0);

        // Unrelated code at the filler address (its validator address is still empty).
        vm.etch(predictedFiller, hex"00");
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.NoCode.selector, "validator", predictedValidator));
        h.deployPair(a);
        vm.etch(predictedValidator, validatorCode);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "existing filler runtime"));
        h.deployPair(a);

        // A filler with one other immutable (the execution fee), with the genuine validator next to it.
        DeployOrderFiller.FillerArgs memory other = _args(address(8));
        other.executionFee = 1;
        MercuriOrderFiller otherFiller = MercuriOrderFiller(payable(_deployed(h, other)));
        vm.etch(predictedFiller, address(otherFiller).code);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "existing filler runtime"));
        h.deployPair(a);

        // The genuine filler without its validator.
        vm.etch(predictedFiller, fillerCode);
        vm.etch(predictedValidator, "");
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.NoCode.selector, "validator", predictedValidator));
        h.deployPair(a);

        // The genuine filler with a validator bound to another pool manager.
        vm.etch(predictedValidator, address(new MercuriOrderValidator(predictedFiller, IPoolManager(address(9)))).code);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "existing validator runtime"));
        h.deployPair(a);

        // The genuine pair is accepted.
        vm.etch(predictedValidator, validatorCode);
        (MercuriOrderFiller filler,) = h.deployPair(a);
        assertEq(address(filler), predictedFiller);

        // An occupied validator address while the filler address is free cannot come from the filler's constructor.
        vm.etch(predictedFiller, "");
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.AlreadyDeployed.selector, predictedValidator));
        h.deployPair(a);
    }

    /// Deploys `a` through the standard deployer and returns the filler address (for building look-alike code).
    function _deployed(FillerHarness h, DeployOrderFiller.FillerArgs memory a) internal returns (address filler) {
        (filler,) = h.predict(a);
        _copierDeploys(h, a);
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

    /// Only Arc testnet and Arc mainnet are accepted; any other chain is refused before a manifest is read.
    function test_scriptsRefuseOtherChains() public {
        uint256[3] memory chains = [uint256(1), 5041, 31337];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            DeployTestnetReactor reactorScript = new DeployTestnetReactor();
            vm.expectRevert(abi.encodeWithSelector(TradeManifest.WrongChain.selector, chains[i]));
            reactorScript.run();
            DeployOrderFiller fillerScript = new DeployOrderFiller();
            vm.expectRevert(abi.encodeWithSelector(TradeManifest.WrongChain.selector, chains[i]));
            fillerScript.run();
        }
    }

    /// A broadcast reaches only an Arc node or a loopback Anvil: another client reporting an Arc chain id is refused.
    function test_broadcastNeedsArcOrAnvilNode() public {
        FillerHarness h = new FillerHarness();
        h.requireArcOrAnvilNode(bytes("arc/v1"));
        h.requireArcOrAnvilNode(bytes("anvil/v1.4.3"));
        h.requireArcOrAnvilNode(bytes('"arc/v1"'));
        h.requireArcOrAnvilNode(bytes('"anvil/v1.4.3"'));
        string[4] memory others = ["tenderly/v1", '"HardhatNetwork/2.22.0"', "Geth/v1.14.0", "x-arc/v1"];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(TradeManifest.NotArcNode.selector, others[i]));
            h.requireArcOrAnvilNode(bytes(others[i]));
        }
    }

    /// With EXPECTED_REACTOR set, a reactor that lands anywhere else reverts the run before it is broadcast.
    function test_reactorScriptChecksExpectedAddress() public {
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        vm.etch(PERMIT2, hex"00");
        vm.setEnv("EXPECTED_REACTOR", "0x00000000000000000000000000000000000000E1");
        DeployTestnetReactor script = new DeployTestnetReactor();
        vm.expectPartialRevert(TradeManifest.UnexpectedReactor.selector);
        script.run();
        vm.setEnv("EXPECTED_REACTOR", "0x0000000000000000000000000000000000000000");
        script.run();
    }

    /// On chain 5042 the reactor script reads the mainnet manifest and Launch's mainnet record, and deploys the same
    /// pinned runtime owned by Launch's mainnet timelock.
    function test_reactorScriptDeploysOnMainnetWithMainnetTimelock() public {
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        vm.chainId(5042);
        vm.etch(PERMIT2, hex"00");
        V3DutchOrderReactor reactor = new DeployTestnetReactor().run();
        assertEq(reactor.owner(), 0x94aFdf4cF8fD025E8421C936f5647a175515eb40, "Launch's mainnet timelock");
        assertEq(address(reactor.feeController()), address(0));
        assertEq(
            address(reactor).codehash,
            new FillerHarness().reactorCodeHash(vm.readFile("deployments/manifest-5042.json"))
        );
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
        V3DutchOrderReactor reactor = h.newReactor(PERMIT2, ANVIL_1);
        bytes32 hash = address(reactor).codehash;
        h.requireDeployed(reactor, ANVIL_1, address(0), hash);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "codehash"));
        h.requireDeployed(reactor, ANVIL_1, address(0), bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "owner"));
        h.requireDeployed(reactor, address(0xbeef), address(0), hash);
        address controller = address(new MockFeeController(address(0xfee), 5, false));
        vm.prank(ANVIL_1);
        reactor.setProtocolFeeController(controller);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "feeController"));
        h.requireDeployed(reactor, ANVIL_1, address(0), hash);
        h.requireDeployed(reactor, ANVIL_1, controller, hash);
    }

    /// C-04 (re-audit of 5 Oct 2026): the reactor's runtime is pinned in each manifest, not supplied by the operator.
    /// The reactor this script deploys has exactly the pinned hash on both Arc chain ids, whatever its owner (owner and
    /// fee controller are storage, not code), and the reactor step itself refuses any other runtime.
    function test_reactorCodeHashPinned() public {
        FillerHarness f = new FillerHarness();
        bytes32 testnetPin = f.reactorCodeHash(vm.readFile("deployments/manifest-5042002.json"));
        bytes32 mainnetPin = f.reactorCodeHash(vm.readFile("deployments/manifest-5042.json"));
        assertEq(testnetPin, mainnetPin, "same permit2 and the same BlockNumberish branch on both networks");
        // The reactor step itself, end to end on the testnet chain id, deploys the pinned runtime.
        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        vm.etch(PERMIT2, hex"00");
        V3DutchOrderReactor reactor = new DeployTestnetReactor().run();
        assertEq(address(reactor).codehash, testnetPin, "testnet reactor runtime");
        ReactorHarness h = new ReactorHarness();
        assertEq(address(h.newReactor(PERMIT2, address(0xbeef))).codehash, testnetPin, "owner is not in the code");
        vm.chainId(5042);
        assertEq(address(h.newReactor(PERMIT2, ANVIL_1)).codehash, mainnetPin, "mainnet chain id, same runtime");
        // On a chain whose BlockNumberish reads ArbSys the runtime differs, so the pin is not chain-agnostic by luck.
        vm.chainId(42161);
        assertTrue(address(h.newReactor(PERMIT2, ANVIL_1)).codehash != testnetPin, "Arbitrum branch differs");
        // A reactor built for another permit2 is other code.
        vm.chainId(5042002);
        assertTrue(address(h.newReactor(address(0xdead), ANVIL_1)).codehash != testnetPin, "another permit2");
        // A missing or zero pin is refused before anything is read.
        vm.expectRevert(TradeManifest.ReactorCodeHashNotPinned.selector);
        f.reactorCodeHash(string.concat('{"reactorCodeHash":"', vm.toString(bytes32(0)), '"}'));
        vm.expectRevert();
        f.reactorCodeHash("{}");
    }

    /// The filler step's reactor check, given the manifest's pin, refuses a look-alike reactor with the same getters
    /// (permit2, owner, fee controller) but other runtime, here the same upstream source built for Arbitrum's
    /// block-number branch. This calls the check directly; `test_fillerRunUsesManifestReactorPin` proves that `run()`
    /// passes it the manifest's pin and not the environment's hash.
    function test_fillerReactorCheckUsesManifestPin() public {
        FillerHarness f = new FillerHarness();
        bytes32 pin = f.reactorCodeHash(vm.readFile("deployments/manifest-5042002.json"));
        ReactorHarness r = new ReactorHarness();
        address genuine = address(r.newReactor(PERMIT2, ANVIL_1));
        f.requireReactor(genuine, PERMIT2, ANVIL_1, address(0), pin);
        vm.chainId(42161);
        address lookAlike = address(r.newReactor(PERMIT2, ANVIL_1));
        vm.chainId(5042002);
        assertEq(address(V3DutchOrderReactor(payable(lookAlike)).permit2()), PERMIT2);
        assertEq(V3DutchOrderReactor(payable(lookAlike)).owner(), ANVIL_1);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "codehash"));
        f.requireReactor(lookAlike, PERMIT2, ANVIL_1, address(0), pin);
    }

    /// C-04 and N-02 (fix re-audit of 6 Oct 2026): `DeployOrderFiller.run()` itself compares TRADE_REACTOR against
    /// the manifest's `reactorCodeHash`, never against TRADE_REACTOR_CODEHASH. The run uses the shipped testnet
    /// manifest, whose keeper is chosen. A look-alike reactor (same getters, Arbitrum block-number branch) is
    /// refused at the reactor check even though the environment names its hash; the genuine reactor passes that check
    /// while the environment names the look-alike's hash, and the run stops at the next check, the router, which has
    /// no code here. Reading the hash from the environment instead fails both halves.
    function test_fillerRunUsesManifestReactorPin() public {
        string memory shipped = vm.readFile("deployments/manifest-5042002.json");
        address timelock = vm.parseJsonAddress(shipped, ".reactorFeeOwner");
        FillerRunHarness script = new FillerRunHarness(shipped);
        ReactorHarness r = new ReactorHarness();
        address genuine = address(r.newReactor(PERMIT2, timelock));
        assertEq(genuine.codehash, vm.parseJsonBytes32(shipped, ".reactorCodeHash"), "genuine reactor is the pin");
        vm.chainId(42161);
        address lookAlike = address(r.newReactor(PERMIT2, timelock));
        vm.chainId(5042002);
        assertTrue(lookAlike.codehash != genuine.codehash, "look-alike is other code");

        vm.setEnv("TRADE_LOCAL_REHEARSAL", "false");
        vm.setEnv("TRADE_REACTOR_CODEHASH", vm.toString(lookAlike.codehash));
        vm.setEnv("TRADE_REACTOR", vm.toString(lookAlike));
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.ReactorMismatch.selector, "codehash"));
        script.run();

        vm.setEnv("TRADE_REACTOR", vm.toString(genuine));
        address router = vm.parseJsonAddress(shipped, ".router");
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.NoCode.selector, "router", router));
        script.run();
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

    /// The mainnet owner choices are made (owner, 7 Oct 2026): the execution fee is the testnet's 0.05 USDC, the keeper
    /// is the mainnet keeper, written checksummed, and the reactor fee owner is Launch's mainnet timelock, whose
    /// proposer is the 2-of-3 Safe. Spec D27: mainnet uses our own reactor, deployed by the reactor step and owned by
    /// that timelock; the manifest names no existing reactor, so the Uniswap-owned mainnet reactor can never be taken
    /// for ours.
    function test_mainnetManifestShipsOwnerChoices() public view {
        string memory manifest = vm.readFile("deployments/manifest-5042.json");
        assertEq(vm.parseJsonUint(manifest, ".chainId"), 5042);
        assertEq(vm.parseJsonUint(manifest, ".executionFee"), 50_000);
        assertEq(vm.parseJsonAddress(manifest, ".feeRecipient"), MAINNET_KEEPER);
        assertEq(vm.parseJsonString(manifest, ".feeRecipient"), vm.toString(MAINNET_KEEPER), "keeper not checksummed");
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
