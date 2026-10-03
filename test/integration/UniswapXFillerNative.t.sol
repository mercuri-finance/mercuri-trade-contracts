// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {UniswapXFillerHarness} from "./UniswapXFiller.t.sol";

/// @notice The reactor refunds its whole native balance to the filler at the end of `executeWithCallback`. On Arc
///         native value is USDC, so a 1-wei native send or a 1-unit ERC-20 USDC transfer to the reactor is enough to
///         trigger that refund (independent audit, 3 Oct 2026, F1). The filler must accept it from the reactor, keep it
///         out of every fill and refuse native value from anyone else.
contract UniswapXFillerNativeTest is UniswapXFillerHarness {
    /// Audit PoC 1: anyone sends 1 wei of native value to the reactor, which has `receive()`.
    function test_nativeDustOnReactorDoesNotBlockFill() public {
        Market memory m = _market(true, false);
        uint256 net = _netQuote(m, true, 100e6, _executionFee());
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, net, 1);
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 1);
        vm.prank(griefer);
        (bool ok,) = address(reactor).call{value: 1}("");
        assertTrue(ok);
        uint256 beforeOut = IERC20(address(m.token)).balanceOf(trader);
        uint256 beforeKeeper = IERC20(USDC).balanceOf(feeRecipient);
        _fill(filler, signed, m.key);
        assertEq(IERC20(address(m.token)).balanceOf(trader) - beforeOut, net, "trader paid the signed output");
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - beforeKeeper, _executionFee(), "execution fee");
        assertEq(address(reactor).balance, 0, "reactor refunded its balance");
        assertEq(address(filler).balance, 1, "refund kept, unspent");
    }

    /// Audit PoC 2: a trader mistakenly sends 1 unit (0.000001) of USDC to the reactor through the ERC-20 interface.
    function test_usdcErc20TransferToReactorDoesNotBlockFill() public {
        Market memory m = _market(false, true);
        uint256 net = _netQuote(m, true, 100e6, _executionFee());
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, net, 1);
        vm.prank(trader);
        IERC20(USDC).transfer(address(reactor), 1);
        assertGt(address(reactor).balance, 0);
        uint256 beforeOut = IERC20(address(m.token)).balanceOf(trader);
        _fill(filler, signed, m.key);
        assertEq(IERC20(address(m.token)).balanceOf(trader) - beforeOut, net, "trader paid the signed output");
        assertEq(IERC20(USDC).balanceOf(address(filler)), 1, "refund kept, unspent");
    }

    /// On a sell the output is USDC, the same balance the refund lands in. The trader receives the swap's surplus
    /// only, never the refund, and a later sell and buy neither spend it nor are blocked by it.
    function test_reactorRefundNeverSubsidizesOrLaterFills() public {
        for (uint256 launchPool; launchPool < 2; ++launchPool) {
            Market memory m = _market(launchPool == 0, launchPool == 1);
            uint128 amount = launchPool == 1 ? 1000000e18 : 100e6;
            uint256 kept = IERC20(USDC).balanceOf(address(filler));
            vm.prank(trader);
            IERC20(USDC).transfer(address(reactor), 5);
            for (uint256 i; i < 2; ++i) {
                uint256 net = _netQuote(m, false, amount, _executionFee());
                uint256 beforeOut = IERC20(USDC).balanceOf(trader);
                _fill(filler, _order(address(m.token), USDC, amount, net, 10 * launchPool + i + 1), m.key);
                assertEq(IERC20(USDC).balanceOf(trader) - beforeOut, net, "sell paid exactly the swap output");
                assertEq(IERC20(USDC).balanceOf(address(filler)), kept + 5, "refund kept, unspent");
            }
            uint256 buyNet = _netQuote(m, true, 100e6, _executionFee());
            _fill(filler, _order(USDC, address(m.token), 100e6, buyNet, 10 * launchPool + 3), m.key);
            assertEq(IERC20(USDC).balanceOf(address(filler)), kept + 5, "a later buy does not spend it");
            assertEq(IERC20(address(m.token)).balanceOf(address(filler)), 0);
        }
    }

    /// Whatever dust sits on the reactor, the trader receives exactly what the same fill pays without it, the keeper
    /// exactly the execution fee, and the dust ends in the filler.
    function testFuzz_reactorDustNeverReachesTrader(uint64 dustSeed, bool buy, bool launchPool) public {
        uint256 dust = bound(dustSeed, 1, 1e6);
        Market memory m = _market(buy, launchPool);
        uint128 amount = buy || !launchPool ? 100e6 : 1000000e18;
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        uint256 net = _netQuote(m, buy, amount, _executionFee());
        vm.prank(trader);
        IERC20(USDC).transfer(address(reactor), dust);
        uint256 beforeOut = IERC20(output).balanceOf(trader);
        uint256 beforeKeeper = IERC20(USDC).balanceOf(feeRecipient);
        _fill(filler, _order(input, output, amount, net, 7), m.key);
        uint256 received = IERC20(output).balanceOf(trader) - beforeOut;
        assertEq(received, net, "trader paid the signed output only");
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - beforeKeeper, _executionFee(), "execution fee");
        assertEq(IERC20(USDC).balanceOf(address(filler)), dust, "dust kept in the filler");
        assertEq(address(reactor).balance, 0);
    }

    /// Native value from anyone but the reactor is refused: a stranger, the trader and the keeper itself.
    function test_nonReactorNativeRefused() public {
        address[3] memory senders = [makeAddr("stranger"), trader, feeRecipient];
        for (uint256 i; i < 3; ++i) {
            vm.deal(senders[i], 1 ether);
            vm.prank(senders[i]);
            (bool ok, bytes memory err) = address(filler).call{value: 1}("");
            assertFalse(ok, "native value accepted from a non-reactor");
            assertEq(bytes4(err), MercuriOrderFiller.NotReactor.selector);
        }
        assertEq(address(filler).balance, 0);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }
}
