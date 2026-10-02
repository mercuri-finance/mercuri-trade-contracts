// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {ResolvedOrder, SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRouterExecute {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Test-only contract that submits fills to MercuriOrderFiller. Armed with a second order, any call into it
///         during a fill (receive, fallback or `reenter`, e.g. from a token transfer hook) tries every re-entry it can:
///         a nested `fill`, a direct `reactorCallback`, a reactor execution, a router sweep and a USDC pull from the
///         filler. Each attempt's outcome is recorded; none may succeed.
contract FillCaller {
    MercuriOrderFiller public immutable filler;
    IReactor public immutable reactor;
    address public immutable router;
    address public immutable usdc;
    bytes private armedOrder;
    bytes private armedSig;
    PoolKey private armedKey;
    uint256 public reentries;
    uint256 public attempts;
    uint256 public successes;

    constructor(MercuriOrderFiller filler_, address usdc_) {
        filler = filler_;
        reactor = filler_.reactor();
        router = address(filler_.router());
        usdc = usdc_;
    }

    function fill(SignedOrder calldata signed, PoolKey calldata key) external {
        filler.fill(signed, key);
    }

    function arm(SignedOrder calldata signed, PoolKey calldata key) external {
        armedOrder = signed.order;
        armedSig = signed.sig;
        armedKey = key;
    }

    function reenter() public {
        reentries++;
        SignedOrder memory second = SignedOrder(armedOrder, armedSig);
        _try(address(filler), abi.encodeCall(MercuriOrderFiller.fill, (second, armedKey)));
        _try(address(filler), abi.encodeCall(MercuriOrderFiller.reactorCallback, (new ResolvedOrder[](0), "")));
        _try(address(reactor), abi.encodeCall(IReactor.executeWithCallback, (second, "")));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(usdc, address(this), uint256(0));
        _try(router, abi.encodeCall(IRouterExecute.execute, (hex"04", inputs, block.timestamp)));
        _try(usdc, abi.encodeCall(IERC20.transferFrom, (address(filler), address(this), 1)));
    }

    /// The reactor would call this if it ever executed an order for this contract; it pays nothing.
    function reactorCallback(ResolvedOrder[] memory, bytes memory) external {}

    receive() external payable {
        reenter();
    }

    fallback() external payable {
        reenter();
    }

    function _try(address target, bytes memory data) private {
        attempts++;
        (bool ok,) = target.call(data);
        if (ok) successes++;
    }
}
