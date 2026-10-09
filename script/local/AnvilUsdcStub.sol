// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice LOCAL ONLY. Stand-in for Arc's USDC ERC-20 view at 0x3600…0000 on a plain Anvil, which has none of Arc's
///         precompiles. `balanceOf` mirrors the native balance in 6 decimals; transfers are not modelled and revert,
///         so graduation (which moves the ERC-20 view) is deferred on Anvil.
contract AnvilUsdcStub {
    uint256 private constant SCALE = 1e12;

    /// @notice Raised by every transfer: the ERC-20 view cannot move native balances without Arc's precompiles.
    error NotModelledOnAnvil();

    /// @notice Token name.
    /// @return "USDC"
    function name() external pure returns (string memory) {
        return "USDC";
    }

    /// @notice Token symbol.
    /// @return "USDC"
    function symbol() external pure returns (string memory) {
        return "USDC";
    }

    /// @notice ERC-20 decimals of the view.
    /// @return 6
    function decimals() external pure returns (uint8) {
        return 6;
    }

    /// @notice Balance in usdc6, mirrored from the native balance.
    /// @param account holder
    /// @return native balance / 1e12
    function balanceOf(address account) external view returns (uint256) {
        return account.balance / SCALE;
    }

    /// @notice Always zero on Anvil.
    /// @return 0
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Accepted and ignored, so callers that pre-approve do not fail.
    /// @return true
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    /// @notice Not modelled.
    function transfer(address, uint256) external pure returns (bool) {
        revert NotModelledOnAnvil();
    }

    /// @notice Not modelled.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NotModelledOnAnvil();
    }
}
