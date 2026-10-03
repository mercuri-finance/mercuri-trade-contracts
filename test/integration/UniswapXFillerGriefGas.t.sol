// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {console2} from "forge-std/console2.sol";
import {UniswapXFillerHarness} from "./UniswapXFiller.t.sol";

/// @notice Gas of a fill the trader griefs between the keeper's simulation and inclusion (moved balance, revoked
///         Permit2 allowance, invalidated nonce, passed deadline), next to a successful fill on the same path. The
///         measurement does not depend on the revert reason, so the same file measures any filler revision.
/// @dev Method: one low-level call per scenario from the keeper, then `vm.lastCallGas().gasTotalUsed`. Under
///      `forge test --isolate` that call runs as its own transaction with cold accounts and slots, and `gasTotalUsed`
///      is the whole transaction's gas: intrinsic 21,000, calldata and execution (a 4-byte view call on the filler
///      measures 21,331 = 21,000 + 64 + 267 isolated, 267 without isolation). Without `--isolate` it is the call's
///      execution gas alone, with whatever the test already warmed. The call's calldata cost (EIP-2028) is logged too.
contract UniswapXFillerGriefGasTest is UniswapXFillerHarness {
    enum Grief {
        None,
        Balance,
        Allowance,
        Nonce,
        Deadline
    }

    function _calldataCost(bytes memory data) internal pure returns (uint256 cost) {
        for (uint256 i; i < data.length; ++i) {
            cost += data[i] == 0 ? 4 : 16;
        }
    }

    /// `Vm.Gas` in the pinned forge-std has a sixth field (`gasStateUsed`) that forge 1.4.3 does not return, so the
    /// struct is read word by word: word 1 is `gasTotalUsed`.
    function _lastCallGasUsed() internal view returns (uint256 used) {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok && ret.length >= 64, "lastCallGas");
        assembly ("memory-safe") {
            used := mload(add(ret, 64))
        }
    }

    function _grief(Grief g, address input, uint256 nonce) internal {
        vm.startPrank(trader);
        if (g == Grief.Balance) IERC20(input).transfer(makeAddr("elsewhere"), IERC20(input).balanceOf(trader));
        if (g == Grief.Allowance) IERC20(input).approve(address(permit2), 0);
        if (g == Grief.Nonce) XPermit2(address(permit2)).invalidateUnorderedNonces(nonce >> 8, 1 << (nonce & 255));
        vm.stopPrank();
        if (g == Grief.Deadline) vm.warp(block.timestamp + 1 days + 1);
    }

    function _measure(bool buy, Grief g) internal returns (bool ok, uint256 used) {
        Market memory m = _market(buy, false);
        uint128 amount = 100e6;
        uint256 net = _netQuote(m, buy, amount, _executionFee());
        (address input, address output) = buy ? (USDC, address(m.token)) : (address(m.token), USDC);
        SignedOrder memory signed = _order(input, output, amount, net, 7);
        _grief(g, input, 7);
        bytes memory data = abi.encodeCall(filler.fill, (signed, m.key));
        vm.prank(feeRecipient);
        bytes memory ret;
        (ok, ret) = address(filler).call(data);
        used = _lastCallGasUsed();
        bytes4 selector = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        console2.log(buy ? "buy " : "sell", uint256(g), ok ? 1 : 0);
        console2.log("  gasTotalUsed / calldata cost", used, _calldataCost(data));
        console2.logBytes4(selector);
        assertEq(ok, g == Grief.None, "only the ungriefed fill succeeds");
    }

    function test_griefGasBuy() public {
        uint256 snap = vm.snapshotState();
        for (uint256 g; g < 5; ++g) {
            _measure(true, Grief(g));
            vm.revertToState(snap);
        }
    }

    function test_griefGasSell() public {
        uint256 snap = vm.snapshotState();
        for (uint256 g; g < 5; ++g) {
            _measure(false, Grief(g));
            vm.revertToState(snap);
        }
    }
}
