// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {SignedOrder, OrderInfo} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {
    V3DutchOrder,
    V3DutchOrderLib,
    V3DutchInput,
    V3DutchOutput,
    NonlinearDutchDecay,
    CosignerData
} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {UniswapXFillerHarness} from "./UniswapXFiller.t.sol";
import {InputProbe} from "../utils/InputProbe.sol";
import {MisreportingTradeToken} from "../utils/MisreportingTradeToken.sol";

/// @notice The filler's early guard (hybrid griefing defence): between the keeper's simulation and inclusion a trader
///         can move the input, revoke the Permit2 approval, cancel the nonce or let the deadline pass. `fill` must then
///         revert with a typed error before the reactor runs, move nothing and leave the nonce as it was, while every
///         order the reactor would fill still fills.
contract UniswapXFillerGuardTest is UniswapXFillerHarness {
    using V3DutchOrderLib for V3DutchOrder;

    uint8 internal constant GRIEF_BALANCE = 0;
    uint8 internal constant GRIEF_ALLOWANCE = 1;
    uint8 internal constant GRIEF_NONCE = 2;
    uint8 internal constant GRIEF_DEADLINE = 3;

    struct Balances {
        uint256 traderInput;
        uint256 traderOutput;
        uint256 keeper;
        uint256 app;
    }

    function _nonceUsed(uint256 nonce) internal view returns (bool) {
        return XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8) & (1 << (nonce & 255)) != 0;
    }

    function _balances(address input, address output) internal view returns (Balances memory b) {
        b = Balances(
            IERC20(input).balanceOf(trader),
            IERC20(output).balanceOf(trader),
            IERC20(USDC).balanceOf(feeRecipient),
            IERC20(USDC).balanceOf(appRecipient)
        );
    }

    function _assertUnmoved(Balances memory a, Balances memory b) internal pure {
        assertEq(a.traderInput, b.traderInput, "trader input moved");
        assertEq(a.traderOutput, b.traderOutput, "trader output moved");
        assertEq(a.keeper, b.keeper, "keeper paid");
        assertEq(a.app, b.app, "app fee paid");
    }

    /// Applies one griefing step to an order of `amount` that the keeper has just simulated. Balance and allowance
    /// are left exactly one unit short, so the guard's bound is the reactor's amount, not a rough one.
    function _grief(uint8 grief, address input, uint256 amount, uint256 nonce) internal returns (bytes4 expected) {
        vm.startPrank(trader);
        if (grief == GRIEF_BALANCE) {
            IERC20(input).transfer(makeAddr("elsewhere"), IERC20(input).balanceOf(trader) - (amount - 1));
            expected = MercuriOrderFiller.SwapperBalanceTooLow.selector;
        } else if (grief == GRIEF_ALLOWANCE) {
            IERC20(input).approve(address(permit2), amount - 1);
            expected = MercuriOrderFiller.SwapperAllowanceTooLow.selector;
        } else if (grief == GRIEF_NONCE) {
            XPermit2(address(permit2)).invalidateUnorderedNonces(nonce >> 8, 1 << (nonce & 255));
            expected = MercuriOrderFiller.NonceUsed.selector;
        }
        vm.stopPrank();
        if (grief == GRIEF_DEADLINE) {
            vm.warp(block.timestamp + 1 days + 1);
            expected = MercuriOrderFiller.OrderExpired.selector;
        }
    }

    function _griefed(bool launch, bool buy, uint8 grief) internal {
        Market memory m = _market(buy, launch);
        uint128 amount = buy || !launch ? 100e6 : 1000000e18;
        uint256 net = _netQuote(m, buy, amount, _executionFee());
        (address input, address output) = buy ? (USDC, address(m.token)) : (address(m.token), USDC);
        uint256 nonce = 300 + grief;
        SignedOrder memory signed = _order(input, output, amount, net, nonce);
        // The keeper's simulation: the order fills as signed.
        uint256 snap = vm.snapshotState();
        _fill(filler, signed, m.key);
        assertTrue(vm.revertToState(snap));

        bytes4 expected = _grief(grief, input, amount, nonce);
        Balances memory before = _balances(input, output);
        vm.expectRevert(expected);
        _fill(filler, signed, m.key);
        _assertUnmoved(before, _balances(input, output));
        assertEq(_nonceUsed(nonce), grief == GRIEF_NONCE, "nonce changed by a refused fill");
    }

    /// Every griefing step on every fill path (Launch and listed pool, buy and sell) reverts with its typed error.
    function test_guardRefusesEachGriefOnEveryPath() public {
        for (uint256 path; path < 4; ++path) {
            for (uint8 grief; grief < 4; ++grief) {
                uint256 snap = vm.snapshotState();
                _griefed(path < 2, path % 2 == 0, grief);
                assertTrue(vm.revertToState(snap));
            }
        }
    }

    function test_guardMovedBalance() public {
        _griefed(false, true, GRIEF_BALANCE);
    }

    function test_guardRevokedAllowance() public {
        _griefed(true, false, GRIEF_ALLOWANCE);
    }

    function test_guardInvalidatedNonce() public {
        _griefed(false, false, GRIEF_NONCE);
    }

    function test_guardExpiredOrder() public {
        _griefed(true, true, GRIEF_DEADLINE);
    }

    /// The guard is never stricter than the reactor: exactly the input amount in balance and allowance, and a fill in
    /// the deadline's own second, still fill.
    function test_guardExactBoundariesStillFill() public {
        for (uint256 path; path < 4; ++path) {
            uint256 snap = vm.snapshotState();
            bool launch = path < 2;
            bool buy = path % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = buy || !launch ? 100e6 : 1000000e18;
            uint256 net = _netQuote(m, buy, amount, _executionFee());
            (address input, address output) = buy ? (USDC, address(m.token)) : (address(m.token), USDC);
            SignedOrder memory signed = _order(input, output, amount, net, 310);
            vm.startPrank(trader);
            IERC20(input).transfer(makeAddr("elsewhere"), IERC20(input).balanceOf(trader) - amount);
            IERC20(input).approve(address(permit2), amount);
            vm.stopPrank();
            vm.warp(abi.decode(signed.order, (V3DutchOrder)).info.deadline);
            uint256 beforeOut = IERC20(output).balanceOf(trader);
            _fill(filler, signed, m.key);
            assertEq(IERC20(input).balanceOf(trader), 0, "exact input taken");
            assertEq(IERC20(output).balanceOf(trader) - beforeOut, net, "trader paid");
            assertTrue(vm.revertToState(snap));
        }
    }

    /// A filled order's replay is refused by the guard, before the reactor.
    function test_guardRefusesReplay() public {
        Market memory m = _market(true, false);
        uint256 net = _netQuote(m, true, 100e6, _executionFee());
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, net, 311);
        _fill(filler, signed, m.key);
        vm.expectRevert(MercuriOrderFiller.NonceUsed.selector);
        _fill(filler, signed, m.key);
    }

    /// An order with a fuzzed input side: cosigned input, base-fee adjustment and a two-point input curve.
    function _curvedOrder(
        uint256 start,
        uint256 max,
        uint256 cosigned,
        uint256 adjustment,
        uint256 startingBaseFee,
        NonlinearDutchDecay memory curve,
        uint256 decayStartBlock,
        address output,
        uint256 nonce
    ) internal view returns (SignedOrder memory signed) {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(output, 1, flat, trader, 1, 0);
        V3DutchOrder memory order;
        order.info = OrderInfo(
            IReactor(address(reactor)), trader, nonce, block.timestamp + 1 days, IValidationCallback(address(0)), ""
        );
        order.cosigner = vm.addr(COSIGNER_KEY);
        order.startingBaseFee = startingBaseFee;
        order.baseInput = V3DutchInput(XERC20(USDC), start, curve, max, adjustment);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(decayStartBlock, address(0), 0, cosigned, new uint256[](1));
        bytes32 h = order.hash();
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_KEY, order.cosignerDigest(h));
        order.cosignature = abi.encodePacked(cr, cs, cv);
        // Permit2 is signed for the curve's maximum, as `Permit2Lib.toPermit` requests it.
        signed = SignedOrder(abi.encode(order), _traderSig(USDC, max, nonce, order.info.deadline, h));
    }

    struct CurveSeed {
        uint64 start;
        uint64 headroom;
        uint64 cosigned;
        uint32 adjustment;
        uint40 startingBaseFee;
        uint40 baseFee;
        uint8 block0;
        uint8 gap;
        int64 amount0;
        int64 amount1;
        uint8 decayDelay;
        uint16 elapsed;
    }

    /// Differential check of the guard's input amount against the reactor's own resolution: with one unit less
    /// balance or allowance than the reactor resolves the guard refuses; with exactly that amount the order fills and
    /// the trader pays exactly it. So the guard's amount equals the reactor's, for any input curve.
    function testFuzz_guardAmountMatchesReactor(CurveSeed memory s) public {
        Market memory m = _market(true, false);
        uint256 start = bound(s.start, 1e6, 50e6);
        uint256 max = start + bound(s.headroom, 0, 50e6);
        uint256 cosigned = s.cosigned % 3 == 0 ? 0 : bound(s.cosigned, 1e6, start);
        uint256 adjustment = s.adjustment % 2 == 0 ? 0 : bound(s.adjustment, 1, 1e6);
        uint256 startingBaseFee = bound(s.startingBaseFee, 0, 100 gwei);
        vm.fee(bound(s.baseFee, 0, 100 gwei));
        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(bound(s.amount0, -50e6, 20e6));
        amounts[1] = int256(bound(s.amount1, -50e6, 20e6));
        uint256 b0 = bound(s.block0, 1, 100);
        uint256 b1 = b0 + bound(s.gap, 1, 100);
        NonlinearDutchDecay memory curve = NonlinearDutchDecay(b0 | (b1 << 16), amounts);
        uint256 decayStart = block.number + bound(s.decayDelay, 0, 10);
        SignedOrder memory signed =
            _curvedOrder(start, max, cosigned, adjustment, startingBaseFee, curve, decayStart, address(m.token), 320);
        vm.roll(block.number + bound(s.elapsed, 0, 300));

        InputProbe probe = new InputProbe(IReactor(address(reactor)));
        uint256 resolved;
        try probe.probe(signed) {
            revert("probe returned");
        } catch (bytes memory err) {
            assertEq(bytes4(err), InputProbe.Resolved.selector, "reactor refused the probe");
            resolved = abi.decode(_tail(err), (uint256));
        }
        // Below the fees a buy cannot fill at all; the bound itself is still checked.
        vm.assume(resolved > 1e6);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        IERC20(USDC).approve(address(permit2), resolved - 1);
        vm.expectRevert(MercuriOrderFiller.SwapperAllowanceTooLow.selector);
        _fill(filler, signed, m.key);
        assertTrue(vm.revertToState(snap));

        uint256 excess = IERC20(USDC).balanceOf(trader) - (resolved - 1);
        vm.prank(trader);
        IERC20(USDC).transfer(makeAddr("elsewhere"), excess);
        vm.expectRevert(MercuriOrderFiller.SwapperBalanceTooLow.selector);
        _fill(filler, signed, m.key);
        assertTrue(vm.revertToState(snap));

        vm.startPrank(trader);
        IERC20(USDC).transfer(makeAddr("elsewhere"), IERC20(USDC).balanceOf(trader) - resolved);
        IERC20(USDC).approve(address(permit2), resolved);
        vm.stopPrank();
        _fill(filler, signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), 0, "trader paid exactly the resolved input");
    }

    function _tail(bytes memory err) internal pure returns (bytes memory tail) {
        tail = new bytes(err.length - 4);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = err[i + 4];
        }
    }

    function _misreportingMarket() internal returns (Market memory m, MisreportingTradeToken token) {
        token = new MisreportingTradeToken(trader);
        m.token = LaunchToken(address(token));
        m.usdcIs0 = USDC < address(token);
        m.key = PoolKey(
            Currency.wrap(m.usdcIs0 ? USDC : address(token)),
            Currency.wrap(m.usdcIs0 ? address(token) : USDC),
            3000,
            60,
            IHooks(address(0))
        );
        poolManager.initialize(m.key, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
        token.approve(address(lp), type(uint256).max);
        IERC20(USDC).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(m.key, ModifyLiquidityParams(-887220, 887220, 1e9, bytes32(0)), "");
        vm.prank(trader);
        token.approve(address(permit2), type(uint256).max);
    }

    /// An input token whose views lie can only make a fill revert, never fill one the reactor refuses. Overstated
    /// views pass the guard and the reactor still refuses the unfunded or unapproved input; understated views are
    /// refused early; reverting views make the fill revert. The honest control fills.
    function test_guardMisreportingTokenNeverFillsWrongly() public {
        (Market memory m, MisreportingTradeToken token) = _misreportingMarket();
        SignedOrder memory signed = _order(address(token), USDC, 100e6, 1, 330);
        uint256 snap = vm.snapshotState();

        // Overstated balance, nothing held: the reactor's Permit2 transfer fails.
        uint256 held = token.balanceOf(trader);
        vm.prank(trader);
        token.transfer(makeAddr("elsewhere"), held);
        token.setReport(MisreportingTradeToken.Report.Overstate, trader);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        _fill(filler, signed, m.key);
        assertFalse(_nonceUsed(330), "overstated balance consumed the nonce");
        assertTrue(vm.revertToState(snap));

        // Overstated allowance, approval revoked: the reactor's Permit2 transfer fails.
        vm.prank(trader);
        token.approve(address(permit2), 0);
        token.setReport(MisreportingTradeToken.Report.Overstate, trader);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        _fill(filler, signed, m.key);
        assertFalse(_nonceUsed(330), "overstated allowance consumed the nonce");
        assertTrue(vm.revertToState(snap));

        // Understated views on a funded, approved trader: refused early, nothing moves.
        token.setReport(MisreportingTradeToken.Report.Understate, trader);
        uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
        vm.expectRevert(MercuriOrderFiller.SwapperBalanceTooLow.selector);
        _fill(filler, signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), beforeUsdc);
        assertFalse(_nonceUsed(330));
        assertTrue(vm.revertToState(snap));

        // Reverting views.
        token.setReport(MisreportingTradeToken.Report.Revert, trader);
        vm.expectRevert(bytes("misreporting view"));
        _fill(filler, signed, m.key);
        assertFalse(_nonceUsed(330));
        assertTrue(vm.revertToState(snap));

        // Honest control: the same order fills.
        _fill(filler, signed, m.key);
        assertTrue(_nonceUsed(330), "control fill");
    }
}
