// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Shared manifest reader for the Trade testnet deployment scripts. Holds no key and never broadcasts.
/// @dev Owner choices ship as sentinel strings and are refused until replaced with an address; the loopback rehearsal
///      override is honoured only on anvil (see `_resolveChoice`). `reactorFeeOwner` is decided: Launch's
///      TimelockController on the same network, required to equal `timelock` in Launch's deployment record.
abstract contract TradeManifest is Script {
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;
    string internal constant MANIFEST_PATH = "deployments/manifest-5042002.json";
    /// @dev Launch's tracked deployment records, `<chainId>.json`, from the pinned Launch submodule.
    string internal constant LAUNCH_RECORDS = "lib/mercuri-launch-contracts/deployments/";
    /// @dev Mirrors MercuriOrderFiller.MAX_EXECUTION_FEE so a bad manifest fails before any broadcast.
    uint256 internal constant MAX_EXECUTION_FEE = 100_000;

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

    /// @dev Refuses any chain other than Arc testnet. A local fork must keep chain id 5042002.
    function _requireTestnet() internal view {
        if (block.chainid != TESTNET_CHAIN_ID) revert WrongChain(block.chainid);
    }

    function _manifest() internal view returns (string memory) {
        return vm.readFile(MANIFEST_PATH);
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
    ///      shares Launch's governance delay. A loopback rehearsal owner is an anvil account and is not checked.
    function _requireTimelockOwner(address owner, string memory launchRecord, bool rehearsal) internal view {
        if (rehearsal) {
            console2.log("WARNING: LOCAL REHEARSAL on anvil. reactorFeeOwner is not Launch's timelock");
            return;
        }
        address timelock = vm.parseJsonAddress(launchRecord, ".timelock");
        if (owner != timelock) revert ReactorFeeOwnerNotTimelock(owner, timelock);
    }

    /// @dev The manifest's Launch-side inputs must be the ones in Launch's record for this chain: permit2, USDC, the
    ///      Launch hook and, as the app fee recipient, Launch's treasury.
    function _requireLaunchRecord(string memory manifest, string memory launchRecord) internal view {
        if (vm.parseJsonUint(manifest, ".chainId") != block.chainid) revert LaunchRecordMismatch("manifest chainId");
        if (vm.parseJsonUint(launchRecord, ".chainId") != block.chainid) revert LaunchRecordMismatch("record chainId");
        _requireSame(manifest, ".permit2", launchRecord, ".permit2", "permit2");
        _requireSame(manifest, ".usdc", launchRecord, ".usdc", "usdc");
        _requireSame(manifest, ".launchHook", launchRecord, ".launchHook", "launchHook");
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

    function _requireCode(string memory name, address account) internal view {
        if (account.code.length == 0) revert NoCode(name, account);
    }

    /// @dev `reactorFeeOwner` is an owner choice made at deployment time and ships as a sentinel string.
    ///      TRADE_LOCAL_REHEARSAL=true swaps in REACTOR_FEE_OWNER_OVERRIDE for a loopback fork rehearsal only. Because
    ///      the real testnet shares chain id 5042002, the override additionally needs an RPC that reports itself as
    ///      anvil and an owner that is one of anvil's public default accounts.
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
    ///      deployment (D3) and ships as a sentinel string. It is also the filler's only permitted `fill` caller (D20).
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
