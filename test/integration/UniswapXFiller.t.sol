// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniversalRouterHarness} from "./UniversalRouterSwap.t.sol";
import {LocalOrderFiller, IOrderSwapRouter} from "../../src/LocalOrderFiller.sol";
import {V3DutchOrderReactor} from "../../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {
    V3DutchOrder,
    V3DutchOrderLib,
    V3DutchInput,
    V3DutchOutput,
    NonlinearDutchDecay,
    CosignerData
} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {OrderInfo, SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdversarialTradeToken} from "../utils/AdversarialTradeToken.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ResolvedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";

abstract contract UniswapXFillerHarness is UniversalRouterHarness {
    using V3DutchOrderLib for V3DutchOrder;
    V3DutchOrderReactor internal reactor;
    LocalOrderFiller internal filler;
    uint256 internal constant TRADER_KEY = 123456789;
    uint256 internal constant COSIGNER_KEY = 987654321;

    function _orderChainID() internal view virtual returns (uint256) {
        return 5042002;
    }

    function setUp() public virtual override {
        vm.chainId(_orderChainID());
        trader = vm.addr(TRADER_KEY);
        super.setUp();
        reactor = new V3DutchOrderReactor(XPermit2(address(permit2)), address(this));
        filler = new LocalOrderFiller(
            IReactor(address(reactor)), IOrderSwapRouter(address(router)), permit2, USDC, address(hook), appRecipient
        );
    }

    function _order(address input, address output, uint256 amount, uint256 minimum, uint256 nonce)
        internal
        view
        returns (SignedOrder memory signed)
    {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(output, minimum, flat, trader, minimum, 0);
        V3DutchOrder memory order;
        order.info = OrderInfo(
            IReactor(address(reactor)), trader, nonce, block.timestamp + 1 days, IValidationCallback(address(0)), ""
        );
        order.cosigner = vm.addr(COSIGNER_KEY);
        order.startingBaseFee = block.basefee;
        order.baseInput = V3DutchInput(XERC20(input), amount, flat, amount, 0);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(block.number, address(0), 0, 0, new uint256[](1));
        bytes32 h = order.hash();
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_KEY, order.cosignerDigest(h));
        order.cosignature = abi.encodePacked(cr, cs, cv);
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                V3DutchOrderLib.PERMIT2_ORDER_TYPE
            )
        );
        bytes32 permissions =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), input, amount));
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                permit2.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typeHash, permissions, address(reactor), nonce, order.info.deadline, h))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRADER_KEY, digest);
        signed = SignedOrder(abi.encode(order), abi.encodePacked(r, s, v));
    }

    function _fillPath(bool mercuri, bool buy) internal {
        Market memory m = _market(buy, mercuri);
        uint128 amount = buy || !mercuri ? 100e6 : 1000000e18;
        uint128 netInput = !mercuri && buy ? amount - amount * 50 / 10000 : amount;
        bytes memory data = mercuri ? abi.encode(uint256(uint160(trader))) : bytes("");
        uint256 gross = _quote(m, buy, netInput, data);
        uint256 net = !mercuri && !buy ? gross - gross * 50 / 10000 : gross;
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        uint256 beforeOut = IERC20(output).balanceOf(trader);
        SignedOrder memory signed = _order(input, output, amount, net, 1);
        filler.fill(signed, m.key);
        assertEq(IERC20(output).balanceOf(trader) - beforeOut, net);
        assertEq(IERC20(input).balanceOf(address(filler)), 0);
        assertEq(IERC20(output).balanceOf(address(filler)), 0);
        assertEq(IERC20(input).allowance(address(filler), address(permit2)), 0);
        assertEq(IERC20(output).allowance(address(filler), address(reactor)), 0);
        _assertEmpty(m);
        vm.expectRevert();
        filler.fill(signed, m.key);
    }

    function _adversarialMarket(bool narrow) internal returns (Market memory m, AdversarialTradeToken token) {
        token = new AdversarialTradeToken(trader);
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
        lp.modifyLiquidity(
            m.key,
            ModifyLiquidityParams(
                narrow ? int24(-60) : int24(-887220), narrow ? int24(60) : int24(887220), 1e9, bytes32(0)
            ),
            ""
        );
        vm.startPrank(trader);
        token.approve(address(permit2), type(uint256).max);
        IERC20(USDC).approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }
}

contract UniswapXFillerTest is UniswapXFillerHarness {
    function test_exportOrderFillReceipts() public {
        vm.createDir("test-export/trade-router", true);
        for (uint256 side; side < 2; ++side) {
            bool buy = side == 0;
            Market memory m = _market(buy, false);
            SignedOrder memory signed =
                _order(buy ? USDC : address(m.token), buy ? address(m.token) : USDC, 100e6, 1, side + 1);
            vm.recordLogs();
            filler.fill(signed, m.key);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            string memory raw = "[";
            for (uint256 i; i < logs.length; ++i) {
                string memory object = string.concat("fill-log", vm.toString(i));
                vm.serializeAddress(object, "address", logs[i].emitter);
                vm.serializeBytes32(object, "topics", logs[i].topics);
                string memory item = vm.serializeBytes(object, "data", logs[i].data);
                raw = string.concat(raw, i == 0 ? "" : ",", item);
            }
            raw = string.concat(raw, "]");
            string memory key = buy ? "order-buy" : "order-sell";
            vm.serializeAddress(key, "router", address(router));
            vm.serializeAddress(key, "filler", address(filler));
            vm.serializeAddress(key, "reactor", address(reactor));
            vm.serializeAddress(key, "keeper", address(this));
            vm.serializeAddress(key, "poolManager", address(poolManager));
            vm.serializeAddress(key, "usdc", USDC);
            vm.serializeAddress(key, "recipient", appRecipient);
            vm.serializeAddress(key, "trader", trader);
            vm.serializeAddress(key, "currency0", Currency.unwrap(m.key.currency0));
            vm.serializeAddress(key, "currency1", Currency.unwrap(m.key.currency1));
            vm.serializeBytes(key, "input", abi.encodeCall(LocalOrderFiller.fill, (signed, m.key)));
            string memory result = vm.serializeString(key, "logs", raw);
            vm.writeJson(result, string.concat("test-export/trade-router/", key, ".json"));
        }
    }

    function test_orderRejectsForeignCallbackAndWrongPool() public {
        vm.expectRevert(LocalOrderFiller.ForbiddenCallback.selector);
        filler.reactorCallback(new ResolvedOrder[](0), "");
        Market memory m = _market(true, false);
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, 1, 3);
        m.key.currency0 = Currency.wrap(address(0x1234));
        vm.expectRevert();
        filler.fill(signed, m.key);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_orderTransferTaxRollsBackAndReentrancyIsBlocked() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
        SignedOrder memory sell = _order(address(token), USDC, 100e6, 1, 4);
        token.configure(1000, address(0), "");
        uint256 beforeBalance = token.balanceOf(trader);
        vm.expectRevert();
        filler.fill(sell, m.key);
        assertEq(token.balanceOf(trader), beforeBalance);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        token.configure(0, address(filler), abi.encodeCall(LocalOrderFiller.fill, (sell, m.key)));
        filler.fill(sell, m.key);
        assertTrue(token.attempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(address(filler)), 0);
    }

    function test_orderTaxedOutputCannotMeetGrossMinimum() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
        uint256 quoted = _quote(m, true, 99500000, "");
        SignedOrder memory buy = _order(USDC, address(token), 100e6, quoted, 5);
        token.configure(1000, address(0), "");
        uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
        vm.expectRevert();
        filler.fill(buy, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), beforeUsdc);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        assertEq(appRecipient.balance, 0);
    }

    function test_orderRejectsPartialFillWhenLiquidityRunsOut() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(true);
        SignedOrder memory sell = _order(address(token), USDC, 100e6, 1, 7);
        uint256 beforeBalance = token.balanceOf(trader);
        vm.expectRevert(LocalOrderFiller.InvalidOrder.selector);
        filler.fill(sell, m.key);
        assertEq(token.balanceOf(trader), beforeBalance);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        assertEq(appRecipient.balance, 0);
    }

    function test_orderMercuriBuy() public {
        _fillPath(true, true);
    }

    function test_orderDonationsCannotBlockOrSubsidizeFills() public {
        Market memory m = _market(true, false);
        vm.startPrank(trader);
        IERC20(USDC).transfer(address(filler), 7);
        IERC20(address(m.token)).transfer(address(filler), 11);
        vm.stopPrank();
        // Both directions must work while unrelated donated balances stay put.
        for (uint256 side; side < 2; ++side) {
            bool buy = side == 0;
            uint256 gross = _quote(m, buy, buy ? 99500000 : 100e6, "");
            uint256 net = buy ? gross : gross - gross * 50 / 10000;
            SignedOrder memory signed =
                _order(buy ? USDC : address(m.token), buy ? address(m.token) : USDC, 100e6, net, 20 + side);
            filler.fill(signed, m.key);
            assertEq(IERC20(USDC).balanceOf(address(filler)), 7);
            assertEq(IERC20(address(m.token)).balanceOf(address(filler)), 11);
        }
    }

    function testFuzz_orderDonationIsolation(uint64 amountSeed, uint64 dustSeed, bool buy) public {
        Market memory m = _market(buy, false);
        uint128 amount = uint128(bound(amountSeed, 1e6, 100e6));
        uint256 dust = bound(dustSeed, 1, 1e6);
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        vm.startPrank(trader);
        IERC20(input).transfer(address(filler), dust);
        IERC20(output).transfer(address(filler), dust);
        vm.stopPrank();
        uint256 beforeInput = IERC20(input).balanceOf(trader);
        uint256 beforeOutput = IERC20(output).balanceOf(trader);
        uint256 gross = _quote(m, buy, buy ? uint128(amount - uint256(amount) * 50 / 10000) : amount, "");
        uint256 net = buy ? gross : gross - gross * 50 / 10000;
        filler.fill(_order(input, output, amount, net, 30), m.key);
        assertEq(beforeInput - IERC20(input).balanceOf(trader), amount);
        assertEq(IERC20(output).balanceOf(trader) - beforeOutput, net);
        assertEq(IERC20(input).balanceOf(address(filler)), dust);
        assertEq(IERC20(output).balanceOf(address(filler)), dust);
        assertEq(IERC20(input).allowance(address(filler), address(permit2)), 0);
        assertEq(IERC20(output).allowance(address(filler), address(reactor)), 0);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 1 << 30);
    }

    function test_orderTaxCannotSpendDonations() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
        token.transfer(address(filler), 100e6);
        token.configure(1000, address(0), "");
        uint256 beforeBalance = token.balanceOf(trader);
        SignedOrder memory signed = _order(address(token), USDC, 100e6, 1, 31);
        vm.expectRevert(LocalOrderFiller.InvalidOrder.selector);
        filler.fill(signed, m.key);
        assertEq(token.balanceOf(address(filler)), 100e6);
        assertEq(token.balanceOf(trader), beforeBalance);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_orderRejectsZeroHookConfiguration() public {
        vm.expectRevert();
        new LocalOrderFiller(
            IReactor(address(reactor)), IOrderSwapRouter(address(router)), permit2, USDC, address(0), appRecipient
        );
    }

    function test_orderMercuriSell() public {
        _fillPath(true, false);
    }

    function test_orderOtherBuy() public {
        _fillPath(false, true);
    }

    function test_orderOtherSell() public {
        _fillPath(false, false);
    }

    function test_orderSlippageRollsBackFeeAndNonce() public {
        Market memory m = _market(true, false);
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, type(uint128).max, 9);
        uint256 beforeBalance = trader.balance;
        vm.expectRevert();
        filler.fill(signed, m.key);
        assertEq(trader.balance, beforeBalance);
        assertEq(appRecipient.balance, 0);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }
}
