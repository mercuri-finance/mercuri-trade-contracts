// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V3DutchOrder, V3DutchOrderLib} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";

/// @dev ABI and cross-language digest oracle for local backend tests only.
contract TradeOrderCodec {
    using V3DutchOrderLib for V3DutchOrder;

    function hashOrder(V3DutchOrder calldata order) external view returns (bytes32 orderHash, bytes32 cosignerDigest) {
        orderHash = order.hash();
        cosignerDigest = order.cosignerDigest(orderHash);
    }
}
