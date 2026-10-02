// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Shared manifest reader for the Trade testnet deployment scripts. Holds no key and never broadcasts.
abstract contract TradeManifest is Script {
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;
    string internal constant MANIFEST_PATH = "deployments/manifest-5042002.json";

    error WrongChain(uint256 chainId);
    error NoCode(string name, address account);

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

    function _requireCode(string memory name, address account) internal view {
        if (account.code.length == 0) revert NoCode(name, account);
    }

    /// @dev `reactorFeeOwner` is an owner choice made at deployment time and ships as a sentinel string.
    /// `vm.parseAddress` reverts on anything that is not an address, so the sentinel stops the script.
    /// TRADE_LOCAL_REHEARSAL=true swaps in REACTOR_FEE_OWNER_OVERRIDE for a loopback fork rehearsal only.
    function _reactorFeeOwner(string memory manifest) internal view returns (address owner) {
        if (vm.envOr("TRADE_LOCAL_REHEARSAL", false)) {
            owner = vm.envAddress("REACTOR_FEE_OWNER_OVERRIDE");
            console2.log(
                "WARNING: LOCAL REHEARSAL. reactorFeeOwner overridden; NEVER set TRADE_LOCAL_REHEARSAL on a real deployment"
            );
        } else {
            owner = vm.parseAddress(vm.parseJsonString(manifest, ".reactorFeeOwner"));
        }
        if (owner == address(0)) revert NoCode("reactorFeeOwner", owner);
    }
}
