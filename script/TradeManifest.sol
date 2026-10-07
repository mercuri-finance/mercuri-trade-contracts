// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Shared manifest reader for the Trade deployment scripts on Arc testnet and Arc mainnet. Holds no key and
///         never broadcasts.
/// @dev Owner choices ship as sentinel strings and are refused until replaced with an address; the loopback rehearsal
///      override is honoured only on Anvil (see `_resolveChoice`). `reactorFeeOwner` is decided: Launch's
///      TimelockController on the same network, required to equal `timelock` in Launch's deployment record. The filler
///      is deployed through the standard CREATE2 deployer with `FILLER_SALT`, and deploys its validator with CREATE2,
///      so both addresses are predicted before broadcasting and asserted after.
abstract contract TradeManifest is Script {
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;
    uint256 internal constant MAINNET_CHAIN_ID = 5042;
    /// @dev Each network's manifest is `deployments/manifest-<chainId>.json`, chosen by the chain the script runs on.
    string internal constant MANIFEST_PREFIX = "deployments/manifest-";
    /// @dev Launch's tracked deployment records, `<chainId>.json`, from the pinned Launch submodule.
    string internal constant LAUNCH_RECORDS = "lib/mercuri-launch-contracts/deployments/";
    /// @dev Mirrors MercuriOrderFiller.MAX_EXECUTION_FEE so a bad manifest fails before any broadcast.
    uint256 internal constant MAX_EXECUTION_FEE = 100_000;
    /// @dev Mirrors MercuriOrderFiller.VALIDATOR_SALT, the salt with which the filler deploys its validator.
    bytes32 internal constant VALIDATOR_SALT = bytes32(0);
    /// @dev Salt of the filler's CREATE2 deployment through `CREATE2_FACTORY` (forge-std's standard deployer).
    bytes32 internal constant FILLER_SALT = bytes32(0);
    /// @dev Runtime keccak of the standard deterministic deployer at `CREATE2_FACTORY`, read with `eth_getCode` on both
    ///      Arc networks (report section 20).
    bytes32 internal constant CREATE2_FACTORY_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    error WrongChain(uint256 chainId);
    error NoCode(string name, address account);
    error ReactorFeeOwnerNotChosen();
    error FeeRecipientNotChosen();
    error ExecutionFeeTooHigh(uint256 fee);
    error RehearsalNeedsAnvil();
    error RehearsalOwnerNotAnvilAccount(address owner);
    error ReactorFeeControllerNotAddress();
    error ReactorMismatch(string what);
    error ReactorFeeOwnerNotTimelock(address owner, address timelock);
    error LaunchRecordMismatch(string field);
    error RouterMismatch(string what);
    error Create2FactoryMismatch(bytes32 codeHash);
    error AlreadyDeployed(address account);
    error DeploymentMismatch(string what);
    error ReactorCodeHashNotPinned();

    /// @dev Refuses any chain other than Arc testnet and Arc mainnet. A local fork keeps its network's chain id, so it
    ///      reads that network's manifest and Launch record.
    function _requireArc() internal view {
        if (block.chainid != TESTNET_CHAIN_ID && block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
    }

    /// @dev Virtual only so a test harness can run a script's `run()` end to end against a manifest fixture with the
    ///      owner choices filled in (`test_fillerRunUsesManifestReactorPin`); the scripts themselves never override it.
    function _manifest() internal view virtual returns (string memory) {
        return vm.readFile(string.concat(MANIFEST_PREFIX, vm.toString(block.chainid), ".json"));
    }

    function _address(string memory manifest, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(manifest, key);
    }

    /// @dev Launch's deployment record for the current chain.
    function _launchRecord() internal view returns (string memory) {
        return vm.readFile(string.concat(LAUNCH_RECORDS, vm.toString(block.chainid), ".json"));
    }

    function _rehearsal() internal view returns (bool) {
        return vm.envOr("TRADE_LOCAL_REHEARSAL", false);
    }

    /// @dev The reactor fee owner must be Launch's timelock from the record, read rather than restated, so the reactor
    ///      shares Launch's governance delay. A loopback rehearsal owner is an Anvil account and is not checked.
    function _requireTimelockOwner(address owner, string memory launchRecord, bool rehearsal) internal view {
        if (rehearsal) {
            console2.log("WARNING: LOCAL REHEARSAL on anvil. reactorFeeOwner is not Launch's timelock");
            return;
        }
        address timelock = vm.parseJsonAddress(launchRecord, ".timelock");
        if (owner != timelock) revert ReactorFeeOwnerNotTimelock(owner, timelock);
    }

    /// @dev The manifest's Launch-side inputs must be the ones in Launch's record for this chain: permit2, USDC, the
    ///      Launch hook, the v4 PoolManager and, as the app fee recipient, Launch's treasury.
    function _requireLaunchRecord(string memory manifest, string memory launchRecord) internal view {
        if (vm.parseJsonUint(manifest, ".chainId") != block.chainid) revert LaunchRecordMismatch("manifest chainId");
        if (vm.parseJsonUint(launchRecord, ".chainId") != block.chainid) revert LaunchRecordMismatch("record chainId");
        _requireSame(manifest, ".permit2", launchRecord, ".permit2", "permit2");
        _requireSame(manifest, ".usdc", launchRecord, ".usdc", "usdc");
        _requireSame(manifest, ".launchHook", launchRecord, ".launchHook", "launchHook");
        _requireSame(manifest, ".poolManager", launchRecord, ".poolManager", "poolManager");
        _requireSame(manifest, ".appRecipient", launchRecord, ".treasury", "appRecipient");
    }

    function _requireSame(
        string memory manifest,
        string memory key,
        string memory launchRecord,
        string memory recordKey,
        string memory field
    ) internal pure {
        if (vm.parseJsonAddress(manifest, key) != vm.parseJsonAddress(launchRecord, recordKey)) {
            revert LaunchRecordMismatch(field);
        }
    }

    /// @dev The Universal Router keeps its permit2 in an internal immutable with no getter, so its runtime is pinned by
    ///      the manifest's `routerCodeHash`. `verify-trade-filler.py --preflight` proves that runtime is the pinned
    ///      router source with the manifest's permit2 in its PERMIT2 immutable.
    function _requireRouter(address router, string memory manifest) internal view {
        if (router.code.length == 0) revert NoCode("router", router);
        if (router.codehash != vm.parseJsonBytes32(manifest, ".routerCodeHash")) revert RouterMismatch("codehash");
    }

    /// @dev The reactor's runtime keccak pinned in the manifest's `reactorCodeHash`. The runtime is deterministic per
    ///      chain: its only immutables are the manifest permit2 and a via-IR function id fixed by the build and by the
    ///      chain id (Arbitrum One and Robinhood Chain aside, which Arc is not). `test_reactorCodeHashPinned` deploys
    ///      the reactor with this script and requires its code hash to equal the pin for both Arc networks, and
    ///      `verify-trade-filler.py --preflight` reproduces the pin from the built reactor and the manifest permit2.
    function _reactorCodeHash(string memory manifest) internal pure returns (bytes32 codeHash) {
        codeHash = vm.parseJsonBytes32(manifest, ".reactorCodeHash");
        if (codeHash == bytes32(0)) revert ReactorCodeHashNotPinned();
    }

    function _requireCode(string memory name, address account) internal view {
        if (account.code.length == 0) revert NoCode(name, account);
    }

    /// @dev The filler is deployed through the standard deterministic deployer, so its code must be the known runtime.
    function _requireCreate2Factory() internal view {
        if (CREATE2_FACTORY.codehash != CREATE2_FACTORY_CODEHASH) {
            revert Create2FactoryMismatch(CREATE2_FACTORY.codehash);
        }
    }

    /// @dev `reactorFeeOwner` is an owner choice made at deployment time; until it is made the manifest carries a
    ///      sentinel string, which is refused.
    ///      TRADE_LOCAL_REHEARSAL=true swaps in REACTOR_FEE_OWNER_OVERRIDE for a loopback fork rehearsal only. Because
    ///      a fork shares its network's chain id, the override additionally needs an RPC that reports itself as Anvil
    ///      and an owner that is one of Anvil's public default accounts.
    function _reactorFeeOwner(string memory manifest) internal returns (address) {
        bool rehearsal = vm.envOr("TRADE_LOCAL_REHEARSAL", false);
        address override_ = rehearsal ? vm.envAddress("REACTOR_FEE_OWNER_OVERRIDE") : address(0);
        bytes memory client = rehearsal ? vm.rpc("web3_clientVersion", "[]") : bytes("");
        return _resolveFeeOwner(manifest, rehearsal, override_, client);
    }

    /// @dev Pure decision logic, parameterised so tests need no environment variables.
    function _resolveFeeOwner(string memory manifest, bool rehearsal, address override_, bytes memory clientVersion)
        internal
        view
        returns (address owner)
    {
        owner = _resolveChoice(manifest, ".reactorFeeOwner", rehearsal, override_, clientVersion);
        if (owner == address(0)) revert ReactorFeeOwnerNotChosen();
    }

    /// @dev `feeRecipient` (the keeper's transaction address, spec D13) is an owner choice made at the filler
    ///      deployment (D3); until it is made the manifest carries a sentinel string, which is refused. It is also the
    ///      filler's only permitted `fill` caller (D20).
    ///      The rehearsal guard is the same as for the reactor fee owner, with FEE_RECIPIENT_OVERRIDE as the override.
    function _feeRecipient(string memory manifest) internal returns (address) {
        bool rehearsal = vm.envOr("TRADE_LOCAL_REHEARSAL", false);
        address override_ = rehearsal ? vm.envAddress("FEE_RECIPIENT_OVERRIDE") : address(0);
        bytes memory client = rehearsal ? vm.rpc("web3_clientVersion", "[]") : bytes("");
        return _resolveFeeRecipient(manifest, rehearsal, override_, client);
    }

    /// @dev Pure decision logic, parameterised so tests need no environment variables.
    function _resolveFeeRecipient(
        string memory manifest,
        bool rehearsal,
        address override_,
        bytes memory clientVersion
    ) internal view returns (address recipient) {
        recipient = _resolveChoice(manifest, ".feeRecipient", rehearsal, override_, clientVersion);
        if (recipient == address(0)) revert FeeRecipientNotChosen();
    }

    /// @dev The reactor's protocol fee controller the deployment expects: the manifest's `reactorFeeController`, zero
    ///      when the key is absent. Zero means the reactor takes no protocol fee; anything else is a reviewed choice.
    function _reactorFeeController(string memory manifest) internal view returns (address) {
        if (!vm.keyExistsJson(manifest, ".reactorFeeController")) return address(0);
        string memory text = vm.parseJsonString(manifest, ".reactorFeeController");
        if (!_isAddressString(text)) revert ReactorFeeControllerNotAddress();
        return vm.parseAddress(text);
    }

    /// @dev The execution fee (USDC, 6 decimals) is fixed for the filler's life; refuse a value the filler would.
    function _executionFee(string memory manifest) internal pure returns (uint256 fee) {
        fee = vm.parseJsonUint(manifest, ".executionFee");
        if (fee > MAX_EXECUTION_FEE) revert ExecutionFeeTooHigh(fee);
    }

    /// @dev An address chosen at deployment time: the manifest value, or under the rehearsal guard the override.
    ///      Returns zero when the manifest still holds a sentinel or anything that is not an address.
    function _resolveChoice(
        string memory manifest,
        string memory key,
        bool rehearsal,
        address override_,
        bytes memory clientVersion
    ) internal view returns (address chosen) {
        if (rehearsal) {
            if (!_contains(clientVersion, bytes("anvil"))) revert RehearsalNeedsAnvil();
            if (!_isAnvilDefaultAccount(override_)) revert RehearsalOwnerNotAnvilAccount(override_);
            console2.log(
                string.concat("WARNING: LOCAL REHEARSAL on anvil. ", key, " overridden with a public dev account")
            );
            return override_;
        }
        string memory text = vm.parseJsonString(manifest, key);
        if (_isAddressString(text)) chosen = vm.parseAddress(text);
    }

    /// @dev Checked in Solidity because `vm.parseAddress` reverts uncatchably without an external call, and a
    ///      script may not call itself.
    function _isAddressString(string memory text) internal pure returns (bool) {
        bytes memory b = bytes(text);
        if (b.length != 42 || b[0] != "0" || (b[1] != "x" && b[1] != "X")) return false;
        for (uint256 i = 2; i < 42; ++i) {
            bytes1 c = b[i];
            bool hex_ = (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F");
            if (!hex_) return false;
        }
        return true;
    }

    function _isAnvilDefaultAccount(address a) internal pure returns (bool) {
        return a == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 || a == 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
            || a == 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC || a == 0x90F79bf6EB2c4f870365E785982E1f101E93b906
            || a == 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 || a == 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
            || a == 0x976EA74026E726554dB657fA54763abd0C3a0aa9 || a == 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955
            || a == 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f || a == 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
