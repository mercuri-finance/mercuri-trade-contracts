// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniversalRouterHarness} from "./UniversalRouterSwap.t.sol";
import {MercuriOrderFiller, IOrderSwapRouter} from "../../src/MercuriOrderFiller.sol";
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

import {MockFeeController} from "../utils/MockFeeController.sol";
import {AdversarialTradeToken} from "../utils/AdversarialTradeToken.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ResolvedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {ExclusivityLib} from "../../lib/uniswapx/src/lib/ExclusivityLib.sol";
import {CallbackFiller} from "../utils/CallbackFiller.sol";

abstract contract UniswapXFillerHarness is UniversalRouterHarness {
    using V3DutchOrderLib for V3DutchOrder;
    V3DutchOrderReactor internal reactor;
    MercuriOrderFiller internal filler;
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
        filler = new MercuriOrderFiller(
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
        signed = SignedOrder(abi.encode(order), _traderSig(input, amount, nonce, order.info.deadline, h));
    }

    function _traderSig(address input, uint256 amount, uint256 nonce, uint256 deadline, bytes32 h)
        internal
        view
        returns (bytes memory)
    {
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
                keccak256(abi.encode(typeHash, permissions, address(reactor), nonce, deadline, h))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRADER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    uint256 internal constant EXPIRY_BLOCKS = 20;

    /// The trader-signed output curve: one point, relative block 1 -> -2^128. Until the cosigned decay start
    /// (head + 20) the output stays at its start amount; one block later it exceeds uint128 and cannot fill.
    function _expiryCurve() internal pure returns (NonlinearDutchDecay memory c) {
        int256[] memory amounts = new int256[](1);
        amounts[0] = -int256(uint256(1) << 128);
        c = NonlinearDutchDecay(1, amounts);
    }

    /// Re-cosigns and re-signs `order` after a test edits it, so the edit is the only change.
    function _resign(V3DutchOrder memory order, address input, uint256 amount, uint256 nonce)
        internal
        view
        returns (SignedOrder memory signed)
    {
        bytes32 h = order.hash();
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_KEY, order.cosignerDigest(h));
        order.cosignature = abi.encodePacked(cr, cs, cv);
        signed = SignedOrder(abi.encode(order), _traderSig(input, amount, nonce, order.info.deadline, h));
    }

    function _expiringOrder(
        address input,
        address output,
        uint256 amount,
        uint256 minimum,
        uint256 nonce,
        uint256 head,
        uint256 raised
    ) internal view returns (SignedOrder memory signed) {
        signed = _expiringOrderFor(input, output, amount, minimum, nonce, head, raised, address(filler));
    }

    /// Cosigned as the keeper does at block `head`: decay starts at head + 20 and, when `exclusive` is set,
    /// only that filler may fill until then (strict: override 0).
    function _expiringOrderFor(
        address input,
        address output,
        uint256 amount,
        uint256 minimum,
        uint256 nonce,
        uint256 head,
        uint256 raised,
        address exclusive
    ) internal view returns (SignedOrder memory signed) {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(output, minimum, _expiryCurve(), trader, minimum, 0);
        V3DutchOrder memory order;
        order.info = OrderInfo(
            IReactor(address(reactor)), trader, nonce, block.timestamp + 1 days, IValidationCallback(address(0)), ""
        );
        order.cosigner = vm.addr(COSIGNER_KEY);
        order.startingBaseFee = 0;
        order.baseInput = V3DutchInput(XERC20(input), amount, flat, amount, 0);
        order.baseOutputs = outputs;
        uint256[] memory overrides = new uint256[](1);
        overrides[0] = raised;
        order.cosignerData = CosignerData(head + EXPIRY_BLOCKS, exclusive, 0, 0, overrides);
        signed = _resign(order, input, amount, nonce);
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
    using V3DutchOrderLib for V3DutchOrder;

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
            vm.serializeBytes(key, "input", abi.encodeCall(MercuriOrderFiller.fill, (signed, m.key)));
            string memory result = vm.serializeString(key, "logs", raw);
            vm.writeJson(result, string.concat("test-export/trade-router/", key, ".json"));
        }
    }

    function test_orderRejectsForeignCallbackAndWrongPool() public {
        vm.expectRevert(MercuriOrderFiller.ForbiddenCallback.selector);
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
        token.configure(0, address(filler), abi.encodeCall(MercuriOrderFiller.fill, (sell, m.key)));
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
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
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
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
        filler.fill(signed, m.key);
        assertEq(token.balanceOf(address(filler)), 100e6);
        assertEq(token.balanceOf(trader), beforeBalance);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_orderRejectsZeroHookConfiguration() public {
        vm.expectRevert();
        new MercuriOrderFiller(
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

    function test_fillEmitsOrderFilled() public {
        Market memory m = _market(true, false); // listed (non-Launch) pool; first arg is token ordering, not side
        uint128 amount = 100e6;
        uint128 netInput = amount - amount * 50 / 10000;
        uint256 gross = _quote(m, true, netInput, "");
        SignedOrder memory signed = _order(USDC, address(m.token), amount, gross, 41);
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        vm.expectEmit(true, true, true, true, address(filler));
        emit MercuriOrderFiller.OrderFilled(order.hash(), trader, keccak256(abi.encode(m.key)));
        filler.fill(signed, m.key);
    }

    function _protocolFeeFill(bool mercuri, bool buy, uint256 bps) internal {
        address feeTo = makeAddr("uniswap fee");
        reactor.setProtocolFeeController(address(new MockFeeController(feeTo, bps, false)));
        Market memory m = _market(buy, mercuri);
        uint128 amount = buy || !mercuri ? 100e6 : 1000000e18;
        uint128 netInput = !mercuri && buy ? amount - amount * 50 / 10000 : amount;
        bytes memory data = mercuri ? abi.encode(uint256(uint160(trader))) : bytes("");
        uint256 gross = _quote(m, buy, netInput, data);
        uint256 net = !mercuri && !buy ? gross - gross * 50 / 10000 : gross;
        uint256 minimum = net * 10_000 / (10_000 + bps); // room for the protocol fee
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        uint256 beforeOut = IERC20(output).balanceOf(trader);
        uint256 beforeFee = IERC20(output).balanceOf(feeTo);
        filler.fill(_order(input, output, amount, minimum, 51), m.key);
        assertGe(IERC20(output).balanceOf(trader) - beforeOut, minimum);
        assertEq(IERC20(output).balanceOf(feeTo) - beforeFee, minimum * bps / 10_000);
        assertEq(IERC20(input).balanceOf(address(filler)), 0);
        assertEq(IERC20(output).balanceOf(address(filler)), 0);
        assertEq(IERC20(input).allowance(address(filler), address(permit2)), 0);
        assertEq(IERC20(output).allowance(address(filler), address(reactor)), 0);
    }

    function test_protocolFeeOutputMercuriSell() public {
        _protocolFeeFill(true, false, 5);
    }

    function test_protocolFeeOutputMercuriBuy() public {
        _protocolFeeFill(true, true, 5);
    }

    function test_protocolFeeOutputOtherBuy() public {
        _protocolFeeFill(false, true, 5);
    }

    function test_protocolFeeOutputOtherSell() public {
        _protocolFeeFill(false, false, 5);
    }

    function testFuzz_protocolFeeOutput(uint8 bps, bool buy, bool launchPool) public {
        _protocolFeeFill(launchPool, buy, bound(bps, 0, 5));
    }

    function test_protocolFeeOnInputFailsWithoutLoss() public {
        reactor.setProtocolFeeController(address(new MockFeeController(makeAddr("uniswap fee"), 5, true)));
        Market memory m = _market(true, false);
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, 1, 52);
        uint256 before = IERC20(USDC).balanceOf(trader);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
        filler.fill(signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), before);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_expiringOrderFillsInsideWindow() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 61, start, 0);
        vm.roll(start + EXPIRY_BLOCKS);
        filler.fill(signed, m.key); // last valid block
    }

    function test_expiringOrderDeadAfterWindow() public {
        Market memory m = _market(false, true);
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, 1, 62, start, 0);
        vm.roll(start + EXPIRY_BLOCKS + 1);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector); // owed > uint128
        filler.fill(signed, m.key);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    /// A funded outside filler that would fill any order the reactor allows it to.
    function _outsider() internal returns (CallbackFiller outsider) {
        outsider = new CallbackFiller(IReactor(address(reactor)));
        assertTrue(IERC20(USDC).transfer(address(outsider), 50_000e6));
    }

    function test_exclusiveWindowFillsThroughFiller() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 70, start, 0);
        uint256 snap = vm.snapshotState();
        for (uint256 offset = 1; offset <= EXPIRY_BLOCKS; ++offset) {
            vm.roll(start + offset);
            uint256 before = IERC20(USDC).balanceOf(trader);
            filler.fill(signed, m.key);
            assertGe(IERC20(USDC).balanceOf(trader) - before, gross / 2, "signed minimum");
            assertTrue(vm.revertToState(snap));
            snap = vm.snapshotState();
        }
    }

    function test_thirdPartyFillerBlockedInsideWindow() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        CallbackFiller outsider = _outsider();
        // Control: the same order cosigned without an exclusive filler fills through the outsider.
        SignedOrder memory open =
            _expiringOrderFor(address(m.token), USDC, 1000000e18, gross / 2, 71, start, 0, address(0));
        uint256 snap = vm.snapshotState();
        vm.roll(start + 1);
        uint256 before = IERC20(USDC).balanceOf(trader);
        outsider.fill(open);
        assertEq(IERC20(USDC).balanceOf(trader) - before, gross / 2, "outsider fills an open order");
        assertTrue(vm.revertToState(snap));
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 72, start, 0);
        snap = vm.snapshotState();
        // Each step restores the snapshot: under via-IR `start` re-reads block.number after a roll.
        for (uint256 offset = 1; offset <= EXPIRY_BLOCKS; ++offset) {
            vm.roll(start + offset);
            vm.expectRevert(ExclusivityLib.NoExclusiveOverride.selector);
            outsider.fill(signed);
            assertEq(IERC20(USDC).balanceOf(trader), before, "outsider moved output");
            assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0, "outsider used nonce");
            if (offset == EXPIRY_BLOCKS) filler.fill(signed, m.key); // still open for our filler at the last block
            assertTrue(vm.revertToState(snap));
            snap = vm.snapshotState();
        }
    }

    function test_thirdPartyFillerCannotFillAfterWindow() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        CallbackFiller outsider = _outsider();
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 73, start, 0);
        vm.roll(start + EXPIRY_BLOCKS + 1);
        uint256 beforeToken = IERC20(address(m.token)).balanceOf(trader);
        uint256 beforeOutsider = IERC20(USDC).balanceOf(address(outsider));
        vm.expectRevert(); // exclusivity has ended, but the output is now start + 2^128
        outsider.fill(signed);
        assertEq(IERC20(address(m.token)).balanceOf(trader), beforeToken);
        assertEq(IERC20(USDC).balanceOf(address(outsider)), beforeOutsider);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function testFuzz_exclusiveExpiryBoundary(uint8 offset) public {
        offset = uint8(bound(offset, 0, 40));
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        CallbackFiller outsider = _outsider();
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 65, start, 0);
        uint256 snap = vm.snapshotState();
        vm.roll(start + offset);
        try outsider.fill(signed) {
            fail("outsider filled an exclusive order");
        } catch (bytes memory err) {
            if (offset <= EXPIRY_BLOCKS) {
                assertEq(bytes4(err), ExclusivityLib.NoExclusiveOverride.selector, "window refusal");
            }
        }
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0, "outsider used nonce");
        bool filled;
        try filler.fill(signed, m.key) {
            filled = true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), MercuriOrderFiller.InvalidOrder.selector, "dead order must fail as InvalidOrder");
        }
        assertEq(filled, offset <= EXPIRY_BLOCKS, "fills iff inside the window");
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0) != 0, filled);
        assertTrue(vm.revertToState(snap));
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0, "snapshot restored");
    }

    function test_raisedOutputAboveMarketReverts() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 before = IERC20(USDC).balanceOf(trader);
        SignedOrder memory signed =
            _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 63, block.number, gross + 1);
        // The router refuses a swap that yields one unit less than the raised output.
        vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", gross + 1, gross));
        filler.fill(signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), before);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        // The same order at the market quote itself still fills.
        filler.fill(_expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 66, block.number, gross), m.key);
        assertEq(IERC20(USDC).balanceOf(trader) - before, gross);
    }

    function test_cosignerCannotLowerOutput() public {
        Market memory m = _market(false, true);
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, 1000e6, 64, block.number, 999e6);
        vm.expectRevert(V3DutchOrderReactor.InvalidCosignerOutput.selector);
        filler.fill(signed, m.key);
    }

    function test_feeControllerExpiringRaisedOutputStillFills() public {
        address feeTo = makeAddr("uniswap fee");
        reactor.setProtocolFeeController(address(new MockFeeController(feeTo, 5, false)));
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 raised = gross * 9_900 / 10_000;
        uint256 before = IERC20(USDC).balanceOf(trader);
        filler.fill(_expiringOrder(address(m.token), USDC, 1000000e18, raised / 2, 67, block.number, raised), m.key);
        assertGe(IERC20(USDC).balanceOf(trader) - before, raised);
        assertEq(IERC20(USDC).balanceOf(feeTo), raised * 5 / 10_000);
        assertEq(IERC20(USDC).balanceOf(address(filler)), 0);
        assertEq(IERC20(address(m.token)).balanceOf(address(filler)), 0);
        assertEq(IERC20(USDC).allowance(address(filler), address(reactor)), 0);
    }

    function test_orderWithConditionDataStillFills() public {
        // The reactor ignores additionalValidationData while the contract is zero; the keeper owns the trigger.
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 68, block.number, 0);
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        order.info.additionalValidationData = abi.encode(uint8(1), uint256(2e18));
        signed = _resign(order, address(m.token), 1000000e18, 68);
        filler.fill(signed, m.key);
    }

    function test_expiryBoundarySweep() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 69, start, 0);
        uint256 snap = vm.snapshotState();
        for (uint256 offset; offset <= 40; ++offset) {
            vm.roll(start + offset);
            if (offset <= EXPIRY_BLOCKS) {
                filler.fill(signed, m.key);
            } else {
                vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
                filler.fill(signed, m.key);
            }
            assertTrue(vm.revertToState(snap));
            snap = vm.snapshotState();
        }
    }

    function test_constructorRejectsZeroAddress() public {
        vm.expectRevert(MercuriOrderFiller.ZeroAddress.selector);
        new MercuriOrderFiller(
            IReactor(address(0)), IOrderSwapRouter(address(router)), permit2, USDC, address(hook), appRecipient
        );
    }
}
