// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Universal Router entry point the order filler calls, and the only one it uses.
interface IOrderSwapRouter {
    /// @notice Runs `commands` with their `inputs` in order; reverts after `deadline`.
    /// @param commands Router commands, one byte each.
    /// @param inputs ABI-encoded input for each command.
    /// @param deadline Last timestamp at which the call may run.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
