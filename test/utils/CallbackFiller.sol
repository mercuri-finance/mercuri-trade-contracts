// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IReactorCallback} from "../../lib/uniswapx/src/interfaces/IReactorCallback.sol";
import {ResolvedOrder, SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only filler that pays every resolved output from its own balance, with no swap. Funded, it
/// fills any order the reactor lets it fill, so its revert is the reactor's refusal. Used as an outside
/// (third-party) filler against our exclusive orders, and as the named filler of the exported vector.
contract CallbackFiller is IReactorCallback {
    IReactor public immutable reactor;

    constructor(IReactor reactor_) {
        reactor = reactor_;
    }

    function fill(SignedOrder calldata order) external {
        reactor.executeWithCallback(order, "");
    }

    function reactorCallback(ResolvedOrder[] memory orders, bytes memory) external {
        require(msg.sender == address(reactor), "reactor only");
        for (uint256 i; i < orders.length; ++i) {
            for (uint256 j; j < orders[i].outputs.length; ++j) {
                IERC20(orders[i].outputs[j].token).approve(address(reactor), orders[i].outputs[j].amount);
            }
        }
    }
}
