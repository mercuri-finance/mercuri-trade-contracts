// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IReactorCallback} from "../../lib/uniswapx/src/interfaces/IReactorCallback.sol";
import {ResolvedOrder, SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";

/// @notice Test-only filler that asks the reactor to resolve an order and reverts from the callback with the input
///         amount the reactor resolved (and has just pulled through Permit2), so nothing is kept. Used to compare the
///         filler's early guard with the reactor's own input resolution.
contract InputProbe is IReactorCallback {
    error Resolved(uint256 inputAmount);

    IReactor public immutable reactor;

    constructor(IReactor reactor_) {
        reactor = reactor_;
    }

    function probe(SignedOrder calldata order) external {
        reactor.executeWithCallback(order, "");
    }

    function reactorCallback(ResolvedOrder[] memory orders, bytes memory) external pure {
        revert Resolved(orders[0].input.amount);
    }
}
