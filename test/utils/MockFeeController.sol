// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProtocolFeeController} from "../../lib/uniswapx/src/interfaces/IProtocolFeeController.sol";
import {ResolvedOrder, OutputToken} from "../../lib/uniswapx/src/base/ReactorStructs.sol";

/// @notice Test-only reactor fee controller: charges `bps` of the order's first output (or its input).
contract MockFeeController is IProtocolFeeController {
    address public immutable recipient;
    uint256 public immutable bps;
    bool public immutable onInput;

    constructor(address recipient_, uint256 bps_, bool onInput_) {
        recipient = recipient_;
        bps = bps_;
        onInput = onInput_;
    }

    function getFeeOutputs(ResolvedOrder memory order) external view returns (OutputToken[] memory fees) {
        fees = new OutputToken[](1);
        fees[0] = onInput
            ? OutputToken(address(order.input.token), order.input.amount * bps / 10_000, recipient)
            : OutputToken(order.outputs[0].token, order.outputs[0].amount * bps / 10_000, recipient);
    }
}
