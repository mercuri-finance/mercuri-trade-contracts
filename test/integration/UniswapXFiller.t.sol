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
import {FillCaller} from "../utils/FillCaller.sol";

abstract contract UniswapXFillerHarness is UniversalRouterHarness {
    using V3DutchOrderLib for V3DutchOrder;
    V3DutchOrderReactor internal reactor;
    MercuriOrderFiller internal filler;
    uint256 internal constant TRADER_KEY = 123456789;
    uint256 internal constant COSIGNER_KEY = 987654321;
    /// The keeper's transaction address: the fixed execution-fee recipient.
    address internal feeRecipient = makeAddr("keeper");

    /// The execution fee of the filler under test (spec D13 default). Suites override it to rerun at another fee.
    function _executionFee() internal view virtual returns (uint256) {
        return 30_000;
    }

    function _orderChainID() internal view virtual returns (uint256) {
        return 5042002;
    }

    function setUp() public virtual override {
        vm.chainId(_orderChainID());
        trader = vm.addr(TRADER_KEY);
        super.setUp();
        reactor = new V3DutchOrderReactor(XPermit2(address(permit2)), address(this));
        filler = _newFiller(_executionFee());
    }

    function _newFiller(uint256 fee) internal returns (MercuriOrderFiller) {
        return new MercuriOrderFiller(
            IReactor(address(reactor)),
            IOrderSwapRouter(address(router)),
            permit2,
            USDC,
            address(hook),
            appRecipient,
            fee,
            feeRecipient
        );
    }

    /// Fills as the configured keeper: only `feeRecipient` may call `fill` (spec D20).
    function _fill(MercuriOrderFiller f, SignedOrder memory signed, PoolKey memory key) internal {
        vm.prank(feeRecipient);
        f.fill(signed, key);
    }

    /// Spec D14: what the trader signs is net of the execution fee. A buy is priced from the input less the app
    /// fee (listed pools) and the execution fee; a sell's minimum is the net quote less the execution fee.
    function _netQuote(Market memory m, bool buy, uint256 amount, uint256 fee) internal returns (uint256) {
        bool launch = address(m.key.hooks) == address(hook);
        uint256 swapIn = buy ? amount - (launch ? 0 : amount * 50 / 10000) - fee : amount;
        uint256 gross = _quote(m, buy, uint128(swapIn), launch ? abi.encode(uint256(uint160(trader))) : bytes(""));
        if (buy) return gross;
        uint256 net = launch ? gross : gross - gross * 50 / 10000;
        return net - fee;
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
        uint256 net = _netQuote(m, buy, amount, _executionFee());
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        uint256 beforeOut = IERC20(output).balanceOf(trader);
        uint256 beforeKeeper = IERC20(USDC).balanceOf(feeRecipient);
        SignedOrder memory signed = _order(input, output, amount, net, 1);
        _fill(filler, signed, m.key);
        assertEq(IERC20(output).balanceOf(trader) - beforeOut, net);
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - beforeKeeper, _executionFee(), "execution fee");
        assertEq(IERC20(input).balanceOf(address(filler)), 0);
        assertEq(IERC20(output).balanceOf(address(filler)), 0);
        assertEq(IERC20(input).allowance(address(filler), address(permit2)), 0);
        assertEq(IERC20(output).allowance(address(filler), address(reactor)), 0);
        _assertEmpty(m);
        vm.expectRevert();
        _fill(filler, signed, m.key);
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

    function test_exportOrderFillReceipts() public virtual {
        vm.createDir("test-export/trade-router", true);
        for (uint256 side; side < 2; ++side) {
            bool buy = side == 0;
            Market memory m = _market(buy, false);
            SignedOrder memory signed =
                _order(buy ? USDC : address(m.token), buy ? address(m.token) : USDC, 100e6, 1, side + 1);
            vm.recordLogs();
            _fill(filler, signed, m.key);
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
            vm.serializeAddress(key, "keeper", feeRecipient);
            vm.serializeAddress(key, "feeRecipient", feeRecipient);
            vm.serializeUint(key, "executionFee", _executionFee());
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
        _fill(filler, signed, m.key);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_orderTransferTaxRollsBackAndReentrancyIsBlocked() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
        SignedOrder memory sell = _order(address(token), USDC, 100e6, 1, 4);
        token.configure(1000, address(0), "");
        uint256 beforeBalance = token.balanceOf(trader);
        vm.expectRevert();
        _fill(filler, sell, m.key);
        assertEq(token.balanceOf(trader), beforeBalance);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        token.configure(0, address(filler), abi.encodeCall(MercuriOrderFiller.fill, (sell, m.key)));
        _fill(filler, sell, m.key);
        assertTrue(token.attempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(address(filler)), 0);
    }

    function test_orderTaxedOutputCannotMeetGrossMinimum() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
        uint256 quoted = _netQuote(m, true, 100e6, _executionFee());
        SignedOrder memory buy = _order(USDC, address(token), 100e6, quoted, 5);
        uint256 beforeKeeper = IERC20(USDC).balanceOf(feeRecipient);
        token.configure(1000, address(0), "");
        uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
        vm.expectRevert();
        _fill(filler, buy, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), beforeUsdc);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        assertEq(appRecipient.balance, 0);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), beforeKeeper, "no execution fee on a revert");
    }

    function test_orderRejectsPartialFillWhenLiquidityRunsOut() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(true);
        SignedOrder memory sell = _order(address(token), USDC, 100e6, 1, 7);
        uint256 beforeBalance = token.balanceOf(trader);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
        _fill(filler, sell, m.key);
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
            uint256 net = _netQuote(m, buy, 100e6, _executionFee());
            SignedOrder memory signed =
                _order(buy ? USDC : address(m.token), buy ? address(m.token) : USDC, 100e6, net, 20 + side);
            _fill(filler, signed, m.key);
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
        uint256 net = _netQuote(m, buy, amount, _executionFee());
        uint256 beforeKeeper = IERC20(USDC).balanceOf(feeRecipient);
        _fill(filler, _order(input, output, amount, net, 30), m.key);
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - beforeKeeper, _executionFee(), "fee from this fill only");
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
        _fill(filler, signed, m.key);
        assertEq(token.balanceOf(address(filler)), 100e6);
        assertEq(token.balanceOf(trader), beforeBalance);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_orderRejectsZeroHookConfiguration() public {
        vm.expectRevert();
        new MercuriOrderFiller(
            IReactor(address(reactor)),
            IOrderSwapRouter(address(router)),
            permit2,
            USDC,
            address(0),
            appRecipient,
            _executionFee(),
            feeRecipient
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
        _fill(filler, signed, m.key);
        assertEq(trader.balance, beforeBalance);
        assertEq(appRecipient.balance, 0);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_fillEmitsOrderFilled() public {
        Market memory m = _market(true, false); // listed (non-Launch) pool; first arg is token ordering, not side
        uint256 gross = _netQuote(m, true, 100e6, _executionFee());
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, gross, 41);
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        vm.expectEmit(true, true, true, true, address(filler));
        emit MercuriOrderFiller.OrderFilled(order.hash(), trader, keccak256(abi.encode(m.key)));
        _fill(filler, signed, m.key);
    }

    function _protocolFeeFill(bool mercuri, bool buy, uint256 bps) internal {
        address feeTo = makeAddr("uniswap fee");
        reactor.setProtocolFeeController(address(new MockFeeController(feeTo, bps, false)));
        Market memory m = _market(buy, mercuri);
        uint128 amount = buy || !mercuri ? 100e6 : 1000000e18;
        uint256 net = _netQuote(m, buy, amount, _executionFee());
        uint256 minimum = net * 10_000 / (10_000 + bps); // room for the protocol fee
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        uint256 beforeOut = IERC20(output).balanceOf(trader);
        uint256 beforeFee = IERC20(output).balanceOf(feeTo);
        uint256 beforeKeeper = IERC20(USDC).balanceOf(feeRecipient);
        _fill(filler, _order(input, output, amount, minimum, 51), m.key);
        assertGe(IERC20(output).balanceOf(trader) - beforeOut, minimum);
        assertEq(IERC20(output).balanceOf(feeTo) - beforeFee, minimum * bps / 10_000);
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - beforeKeeper, _executionFee(), "execution fee");
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
        _fill(filler, signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), before);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
    }

    function test_expiringOrderFillsInsideWindow() public {
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 61, start, 0);
        vm.roll(start + EXPIRY_BLOCKS);
        _fill(filler, signed, m.key); // last valid block
    }

    function test_expiringOrderDeadAfterWindow() public {
        Market memory m = _market(false, true);
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, 1, 62, start, 0);
        vm.roll(start + EXPIRY_BLOCKS + 1);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector); // owed > uint128
        _fill(filler, signed, m.key);
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
            _fill(filler, signed, m.key);
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
            if (offset == EXPIRY_BLOCKS) _fill(filler, signed, m.key); // still open for our filler at the last block
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
        // Exclusivity has ended (not NoExclusiveOverride): the reactor resolves the order and then cannot take
        // start + 2^128 of output from the outsider, whatever its balance.
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
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
            } else {
                // Exclusivity lapsed; the curve, not the window, kills the order.
                assertEq(err, abi.encodeWithSignature("Error(string)", "TRANSFER_FROM_FAILED"), "dead-order refusal");
            }
        }
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0, "outsider used nonce");
        bool filled;
        vm.prank(feeRecipient);
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
        uint256 netQuote = gross - _executionFee(); // what the keeper may raise the output to (spec D14)
        uint256 before = IERC20(USDC).balanceOf(trader);
        SignedOrder memory signed =
            _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 63, block.number, netQuote + 1);
        // The router refuses a swap that yields one unit less than the raised output plus the execution fee.
        vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", gross + 1, gross));
        _fill(filler, signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), before);
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, 0), 0);
        // The same order at the net-of-fee market quote itself still fills.
        _fill(filler, _expiringOrder(address(m.token), USDC, 1000000e18, gross / 2, 66, block.number, netQuote), m.key);
        assertEq(IERC20(USDC).balanceOf(trader) - before, netQuote);
    }

    function test_cosignerCannotLowerOutput() public {
        Market memory m = _market(false, true);
        SignedOrder memory signed = _expiringOrder(address(m.token), USDC, 1000000e18, 1000e6, 64, block.number, 999e6);
        vm.expectRevert(V3DutchOrderReactor.InvalidCosignerOutput.selector);
        _fill(filler, signed, m.key);
    }

    function test_feeControllerExpiringRaisedOutputStillFills() public {
        address feeTo = makeAddr("uniswap fee");
        reactor.setProtocolFeeController(address(new MockFeeController(feeTo, 5, false)));
        Market memory m = _market(false, true);
        uint256 gross = _quote(m, false, 1000000e18, abi.encode(uint256(uint160(trader))));
        uint256 raised = gross * 9_900 / 10_000;
        uint256 before = IERC20(USDC).balanceOf(trader);
        _fill(filler, _expiringOrder(address(m.token), USDC, 1000000e18, raised / 2, 67, block.number, raised), m.key);
        assertGe(IERC20(USDC).balanceOf(trader) - before, raised);
        assertEq(IERC20(USDC).balanceOf(feeTo), raised * 5 / 10_000);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), _executionFee(), "execution fee");
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
        _fill(filler, signed, m.key);
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
                _fill(filler, signed, m.key);
            } else {
                vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
                _fill(filler, signed, m.key);
            }
            assertTrue(vm.revertToState(snap));
            snap = vm.snapshotState();
        }
    }

    function test_constructorRejectsZeroAddress() public {
        vm.expectRevert(MercuriOrderFiller.ZeroAddress.selector);
        new MercuriOrderFiller(
            IReactor(address(0)),
            IOrderSwapRouter(address(router)),
            permit2,
            USDC,
            address(hook),
            appRecipient,
            _executionFee(),
            feeRecipient
        );
    }
}

/// Reruns every `UniswapXFillerTest` case against a filler with no execution fee. With a zero fee the D14 quote
/// math reduces to the pre-fee math, so each case proves that a zero fee behaves exactly as before.
contract UniswapXFillerZeroFeeTest is UniswapXFillerTest {
    function _executionFee() internal pure override returns (uint256) {
        return 0;
    }

    /// The receipt export is written once, by the default (fee-on) suite.
    function test_exportOrderFillReceipts() public override {
        vm.skip(true);
    }
}

/// Execution fee (spec D13/D14): paid once per successful fill, in USDC, to the fixed `feeRecipient`.
contract UniswapXFillerExecFeeTest is UniswapXFillerHarness {
    using V3DutchOrderLib for V3DutchOrder;

    uint256 internal constant MAX_FEE = 100_000;

    function _usdcOf(address who) internal view returns (uint256) {
        return IERC20(USDC).balanceOf(who);
    }

    /// Balances that a fill may move, read before and after.
    struct Snap {
        uint256 traderUsdc;
        uint256 traderToken;
        uint256 keeper;
        uint256 app;
        uint256 caller;
        uint256 fillerUsdc;
        uint256 fillerToken;
    }

    function _snap(Market memory m, MercuriOrderFiller f, address caller) internal view returns (Snap memory s) {
        s.traderUsdc = IERC20(USDC).balanceOf(trader);
        s.traderToken = IERC20(address(m.token)).balanceOf(trader);
        s.keeper = IERC20(USDC).balanceOf(feeRecipient);
        s.app = IERC20(USDC).balanceOf(appRecipient);
        s.caller = IERC20(USDC).balanceOf(caller);
        s.fillerUsdc = IERC20(USDC).balanceOf(address(f));
        s.fillerToken = IERC20(address(m.token)).balanceOf(address(f));
    }

    function _assertUnchanged(Snap memory a, Snap memory b, string memory what) internal pure {
        assertEq(a.traderUsdc, b.traderUsdc, string.concat(what, ": trader USDC"));
        assertEq(a.traderToken, b.traderToken, string.concat(what, ": trader token"));
        assertEq(a.keeper, b.keeper, string.concat(what, ": fee recipient"));
        assertEq(a.app, b.app, string.concat(what, ": app recipient"));
        assertEq(a.caller, b.caller, string.concat(what, ": caller"));
        assertEq(a.fillerUsdc, b.fillerUsdc, string.concat(what, ": filler USDC"));
        assertEq(a.fillerToken, b.fillerToken, string.concat(what, ": filler token"));
    }

    /// Filler holds nothing of either token and has no live approval anywhere, including Permit2's router allowance.
    function _assertFillerClean(Market memory m, MercuriOrderFiller f) internal view {
        address[2] memory tokens = [USDC, address(m.token)];
        for (uint256 i; i < 2; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(f)), 0, "filler balance");
            assertEq(IERC20(tokens[i]).allowance(address(f), address(permit2)), 0, "permit2 approval");
            assertEq(IERC20(tokens[i]).allowance(address(f), address(reactor)), 0, "reactor approval");
            (uint160 allowed,,) = permit2.allowance(address(f), tokens[i], address(router));
            assertEq(allowed, 0, "permit2 router allowance");
        }
    }

    function _nonceUsed(uint256 nonce) internal view returns (bool) {
        return XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8) & (1 << (nonce & 255)) != 0;
    }

    function _amount(bool launch, bool buy) internal pure returns (uint128) {
        return buy || !launch ? 100e6 : 1000000e18;
    }

    function _io(Market memory m, bool buy) internal pure returns (address input, address output) {
        (input, output) = buy ? (USDC, address(m.token)) : (address(m.token), USDC);
    }

    /// The app fee a listed-pool fill pays: 50 bps of a buy's input or of a sell's gross USDC output.
    function _appFee(Market memory m, bool buy, uint256 amount) internal returns (uint256) {
        if (address(m.key.hooks) == address(hook)) return 0;
        return buy ? amount * 50 / 10000 : _quote(m, false, uint128(amount), "") * 50 / 10000;
    }

    function test_execFeeConstructorRejectsFeeAboveMax() public {
        vm.expectRevert(MercuriOrderFiller.ExecutionFeeTooHigh.selector);
        _newFiller(MAX_FEE + 1);
        vm.expectRevert(MercuriOrderFiller.ExecutionFeeTooHigh.selector);
        _newFiller(type(uint256).max);
        MercuriOrderFiller atMax = _newFiller(MAX_FEE);
        assertEq(atMax.MAX_EXECUTION_FEE(), MAX_FEE);
        assertEq(atMax.executionFee(), MAX_FEE);
        assertEq(atMax.feeRecipient(), feeRecipient);
        assertEq(_newFiller(0).executionFee(), 0);
        assertEq(filler.executionFee(), 30_000, "harness default (spec D13)");
    }

    function test_execFeeConstructorRejectsZeroRecipient() public {
        for (uint256 fee; fee <= MAX_FEE; fee += MAX_FEE) {
            vm.expectRevert(MercuriOrderFiller.ZeroAddress.selector);
            new MercuriOrderFiller(
                IReactor(address(reactor)),
                IOrderSwapRouter(address(router)),
                permit2,
                USDC,
                address(hook),
                appRecipient,
                fee,
                address(0)
            );
        }
    }

    /// A zero-fee filler pays the pre-fee amounts exactly on all four routes (see also UniswapXFillerZeroFeeTest).
    function test_execFeeZeroBehavesAsBefore() public {
        MercuriOrderFiller f = _newFiller(0);
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = _amount(launch, buy);
            // The pre-fee formulas, written out as they were before the fee existed.
            uint128 netInput = !launch && buy ? amount - amount * 50 / 10000 : amount;
            uint256 gross = _quote(m, buy, netInput, launch ? abi.encode(uint256(uint160(trader))) : bytes(""));
            uint256 net = !launch && !buy ? gross - gross * 50 / 10000 : gross;
            (address input, address output) = _io(m, buy);
            Snap memory before = _snap(m, f, address(this));
            uint256 appFee = _appFee(m, buy, amount);
            _fill(f, _order(input, output, amount, net, 100 + route), m.key);
            Snap memory afterFill = _snap(m, f, address(this));
            assertEq(
                buy ? afterFill.traderToken - before.traderToken : afterFill.traderUsdc - before.traderUsdc,
                net,
                "pre-fee net"
            );
            assertEq(afterFill.keeper, before.keeper, "no fee transfer");
            assertEq(afterFill.app - before.app, appFee, "app fee");
            _assertFillerClean(m, f);
        }
    }

    function test_execFeePaidOnEachRoute() public {
        uint256 fee = filler.executionFee();
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = _amount(launch, buy);
            uint256 net = _netQuote(m, buy, amount, fee);
            uint256 appFee = _appFee(m, buy, amount);
            (address input, address output) = _io(m, buy);
            Snap memory before = _snap(m, filler, address(this));
            _fill(filler, _order(input, output, amount, net, 110 + route), m.key);
            Snap memory afterFill = _snap(m, filler, address(this));
            if (buy) {
                assertEq(afterFill.traderToken - before.traderToken, net, "trader output");
                assertEq(before.traderUsdc - afterFill.traderUsdc, amount, "trader input");
            } else {
                assertEq(afterFill.traderUsdc - before.traderUsdc, net, "trader output");
                assertEq(before.traderToken - afterFill.traderToken, amount, "trader input");
            }
            assertEq(afterFill.keeper - before.keeper, fee, "fee recipient paid exactly the fee");
            assertEq(afterFill.app - before.app, appFee, "app fee");
            assertEq(afterFill.caller, before.caller, "the caller earns nothing");
            _assertFillerClean(m, filler);
            _assertEmpty(m);
        }
    }

    /// The input amount `a` at which a buy's input exactly equals its app fee plus the execution fee.
    function _exactFeeInput(bool launch, uint256 fee) internal pure returns (uint256 a) {
        a = fee;
        while (a != (launch ? 0 : a * 50 / 10000) + fee) ++a;
    }

    function test_execFeeBuyInputTooSmall() public {
        uint256 fee = filler.executionFee();
        for (uint256 route; route < 2; ++route) {
            bool launch = route == 0;
            Market memory m = _market(true, launch);
            uint256 exact = _exactFeeInput(launch, fee);
            for (uint256 under; under < 2; ++under) {
                uint256 amount = exact - under; // equal to app fee + fee, then one below
                uint256 nonce = 120 + route * 2 + under;
                SignedOrder memory signed = _order(USDC, address(m.token), amount, 1, nonce);
                Snap memory before = _snap(m, filler, address(this));
                vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
                _fill(filler, signed, m.key);
                _assertUnchanged(before, _snap(m, filler, address(this)), "too-small buy");
                assertFalse(_nonceUsed(nonce), "nonce unused");
            }
        }
    }

    function _expectShortSell(Market memory m, uint256 needed, uint256 got) internal {
        if (address(m.key.hooks) == address(hook)) {
            vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", needed, got));
        } else {
            vm.expectRevert(abi.encodeWithSignature("InsufficientToken()"));
        }
    }

    function _sellBoundary(MercuriOrderFiller f, bool launch, uint256 nonce) internal {
        uint256 fee = f.executionFee();
        Market memory m = _market(false, launch);
        uint128 amount = _amount(launch, false);
        uint256 net = _netQuote(m, false, amount, 0); // USDC the filler receives after any app fee
        Snap memory before = _snap(m, f, address(this));
        // One unit short of owed + fee: refused, nothing moves.
        SignedOrder memory shortOrder = _order(address(m.token), USDC, amount, net - fee + 1, nonce);
        _expectShortSell(m, net + 1, net);
        _fill(f, shortOrder, m.key);
        _assertUnchanged(before, _snap(m, f, address(this)), "short sell");
        assertFalse(_nonceUsed(nonce));
        // Exactly owed + fee: fills with no leftover; the trader gets exactly the signed minimum.
        _fill(f, _order(address(m.token), USDC, amount, net - fee, nonce + 1), m.key);
        Snap memory afterFill = _snap(m, f, address(this));
        assertEq(afterFill.traderUsdc - before.traderUsdc, net - fee, "trader gets exactly the minimum");
        assertEq(afterFill.keeper - before.keeper, fee, "fee");
        _assertFillerClean(m, f);
    }

    function test_execFeeSellExactBoundary() public {
        _sellBoundary(filler, true, 130);
        _sellBoundary(filler, false, 132);
        MercuriOrderFiller atMax = _newFiller(MAX_FEE);
        _sellBoundary(atMax, true, 134);
        _sellBoundary(atMax, false, 136);
    }

    /// Spec D20: only the configured keeper may call `fill`. The trader, a stranger and a contract each revert
    /// `NotKeeper` before the order is touched: no balance moves and the nonce stays unused.
    function test_notKeeperCannotFill() public {
        FillCaller contractCaller = new FillCaller(filler, USDC);
        address[3] memory callers = [trader, makeAddr("stranger"), address(contractCaller)];
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = _amount(launch, buy);
            uint256 net = _netQuote(m, buy, amount, filler.executionFee());
            (address input, address output) = _io(m, buy);
            SignedOrder memory signed = _order(input, output, amount, net, 140 + route);
            for (uint256 i; i < callers.length; ++i) {
                Snap memory before = _snap(m, filler, callers[i]);
                vm.expectRevert(MercuriOrderFiller.NotKeeper.selector);
                if (callers[i] == address(contractCaller)) {
                    contractCaller.fill(signed, m.key);
                } else {
                    vm.prank(callers[i]);
                    filler.fill(signed, m.key);
                }
                _assertUnchanged(before, _snap(m, filler, callers[i]), "non-keeper");
                assertFalse(_nonceUsed(140 + route), "nonce unused");
            }
            // The same order still fills through the keeper afterwards.
            _fill(filler, signed, m.key);
            assertTrue(_nonceUsed(140 + route), "keeper filled");
        }
    }

    /// A filler whose keeper is a FillCaller contract, so the keeper path itself can be exercised from a contract.
    function _contractKeeper() internal returns (MercuriOrderFiller f, FillCaller caller) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        f = new MercuriOrderFiller(
            IReactor(address(reactor)),
            IOrderSwapRouter(address(router)),
            permit2,
            USDC,
            address(hook),
            appRecipient,
            _executionFee(),
            predicted
        );
        caller = new FillCaller(f, USDC);
        assertEq(address(caller), predicted, "keeper address");
        assertEq(f.feeRecipient(), address(caller));
    }

    /// A contract keeper fills through the keeper path and earns exactly the execution fee, nothing more.
    function test_execFeeContractKeeper() public {
        (MercuriOrderFiller f, FillCaller caller) = _contractKeeper();
        uint256 fee = f.executionFee();
        for (uint256 side; side < 2; ++side) {
            bool buy = side == 0;
            Market memory m = _market(buy, false);
            uint256 net = _netQuote(m, buy, 100e6, fee);
            (address input, address output) = _io(m, buy);
            Snap memory before = _snap(m, f, address(caller));
            caller.fill(_order(input, output, 100e6, net, 150 + side), m.key);
            Snap memory afterFill = _snap(m, f, address(caller));
            assertEq(afterFill.caller - before.caller, fee, "keeper earns exactly the fee");
            assertEq(IERC20(address(m.token)).balanceOf(address(caller)), 0);
            _assertFillerClean(m, f);
        }
        assertEq(caller.reentries(), 0);
    }

    /// The keeper itself is a contract whose receive / fallback / `reenter` runs mid-fill (from the output token's
    /// transfer hook, while the router holds the filler's allowance): it cannot re-enter fill, the callback, the
    /// reactor or the router, cannot pull the filler's USDC, and the fee is paid exactly once.
    function test_execFeeReentrantKeeperCannotDoublePay() public {
        bytes[3] memory hooks = [bytes(""), bytes(hex"deadbeef"), abi.encodeCall(FillCaller.reenter, ())];
        for (uint256 i; i < 3; ++i) {
            (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
            (MercuriOrderFiller f, FillCaller caller) = _contractKeeper();
            uint256 fee = f.executionFee();
            uint256 net = _netQuote(m, true, 100e6, fee);
            SignedOrder memory first = _order(USDC, address(token), 100e6, net / 2, 160 + i * 2);
            uint256 secondNet = net / 4;
            SignedOrder memory second = _order(USDC, address(token), 100e6, secondNet, 161 + i * 2);
            caller.arm(second, m.key);
            // The hook fires on the token's first transfer: the pool paying the filler inside the router call.
            token.configure(0, address(caller), hooks[i]);
            Snap memory before = _snap(m, f, address(caller));
            caller.fill(first, m.key);
            Snap memory afterFill = _snap(m, f, address(caller));
            assertTrue(token.attempted(), "hook ran");
            assertEq(caller.reentries(), 1, "re-entry attempted once");
            assertEq(caller.attempts(), 5);
            assertEq(caller.successes(), 0, "every re-entry refused");
            assertEq(afterFill.caller - before.caller, fee, "fee paid exactly once");
            assertEq(before.traderUsdc - afterFill.traderUsdc, 100e6, "only the first order spent input");
            assertFalse(_nonceUsed(161 + i * 2), "second order untouched");
            _assertFillerClean(m, f);
            // The second order was valid all along: the keeper fills it normally afterwards, one fee.
            caller.fill(second, m.key);
            assertEq(IERC20(USDC).balanceOf(address(caller)) - afterFill.caller, fee);
        }
    }

    function test_execFeeWithProtocolFeeOutputs() public {
        address feeTo = makeAddr("uniswap fee");
        reactor.setProtocolFeeController(address(new MockFeeController(feeTo, 5, false)));
        uint256 fee = filler.executionFee();
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = _amount(launch, buy);
            uint256 net = _netQuote(m, buy, amount, fee); // trader's share of the swap after app and execution fees
            uint256 minimum = net * 10_000 / 10_005;
            uint256 protocolFee = minimum * 5 / 10_000;
            uint256 appFee = _appFee(m, buy, amount);
            (address input, address output) = _io(m, buy);
            Snap memory before = _snap(m, filler, address(this));
            uint256 beforeFeeTo = IERC20(output).balanceOf(feeTo);
            _fill(filler, _order(input, output, amount, minimum, 170 + route), m.key);
            Snap memory afterFill = _snap(m, filler, address(this));
            uint256 traderDelta =
                buy ? afterFill.traderToken - before.traderToken : afterFill.traderUsdc - before.traderUsdc;
            assertEq(traderDelta, net - protocolFee, "trader: everything but the fees");
            assertGe(traderDelta, minimum, "trader minimum");
            assertEq(IERC20(output).balanceOf(feeTo) - beforeFeeTo, protocolFee, "protocol fee");
            assertEq(afterFill.app - before.app, appFee, "app fee");
            assertEq(afterFill.keeper - before.keeper, fee, "execution fee");
            _assertFillerClean(m, filler);
        }
    }

    /// The keeper raises the cosigned output to the net-of-fee quote (spec D14): that fills; one unit more reverts.
    function test_execFeeWithExpiringOrderAndRaisedOutput() public {
        uint256 fee = filler.executionFee();
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = _amount(launch, buy);
            uint256 raised = _netQuote(m, buy, amount, fee);
            (address input, address output) = _io(m, buy);
            uint256 nonce = 180 + route * 2;
            Snap memory before = _snap(m, filler, address(this));
            SignedOrder memory above =
                _expiringOrder(input, output, amount, raised / 2, nonce, block.number, raised + 1);
            if (buy) {
                vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", raised + 1, raised));
            } else {
                _expectShortSell(m, raised + fee + 1, raised + fee);
            }
            _fill(filler, above, m.key);
            _assertUnchanged(before, _snap(m, filler, address(this)), "raised above the net quote");
            assertFalse(_nonceUsed(nonce));
            _fill(filler, _expiringOrder(input, output, amount, raised / 2, nonce + 1, block.number, raised), m.key);
            Snap memory afterFill = _snap(m, filler, address(this));
            assertEq(
                buy ? afterFill.traderToken - before.traderToken : afterFill.traderUsdc - before.traderUsdc,
                raised,
                "trader gets the raised output"
            );
            assertEq(afterFill.keeper - before.keeper, fee);
            _assertFillerClean(m, filler);
        }
    }

    /// USDC and tokens donated to the filler never pay the fee, never reach the trader and never rescue a short fill.
    function test_execFeeDonationIsolation() public {
        uint256 fee = filler.executionFee();
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            vm.startPrank(trader);
            IERC20(USDC).transfer(address(filler), 7e6); // far more than the fee
            IERC20(address(m.token)).transfer(address(filler), 11e18);
            vm.stopPrank();
            uint128 amount = _amount(launch, buy);
            uint256 net = _netQuote(m, buy, amount, fee);
            (address input, address output) = _io(m, buy);
            uint256 nonce = 190 + route * 3;
            // A fill one unit short of its fee is not completed from the donation.
            Snap memory before = _snap(m, filler, address(this));
            // Orders are signed before vm.expectRevert: signing reads Permit2, which would be the "next call".
            if (buy) {
                SignedOrder memory small = _order(USDC, address(m.token), _exactFeeInput(launch, fee), 1, nonce);
                vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
                _fill(filler, small, m.key);
            } else {
                uint256 got = _netQuote(m, false, amount, 0);
                SignedOrder memory shortOrder = _order(input, output, amount, net + 1, nonce);
                _expectShortSell(m, got + 1, got);
                _fill(filler, shortOrder, m.key);
            }
            _assertUnchanged(before, _snap(m, filler, address(this)), "donation cannot rescue a short fill");
            _fill(filler, _order(input, output, amount, net, nonce + 1), m.key);
            Snap memory afterFill = _snap(m, filler, address(this));
            assertEq(
                buy ? afterFill.traderToken - before.traderToken : afterFill.traderUsdc - before.traderUsdc,
                net,
                "trader gets this fill's output only"
            );
            assertEq(afterFill.keeper - before.keeper, fee, "fee from this fill, not the donation");
            assertEq(afterFill.fillerUsdc, 7e6, "USDC donation untouched");
            assertEq(afterFill.fillerToken, 11e18, "token donation untouched");
            vm.startPrank(address(filler));
            IERC20(USDC).transfer(address(0xdead), 7e6);
            IERC20(address(m.token)).transfer(address(0xdead), 11e18);
            vm.stopPrank();
        }
    }

    /// Every revert path leaves the fee recipient (and everyone else) unchanged.
    function test_execFeeNotPaidOnRevert() public {
        Market memory m = _market(true, false);
        Market memory launchSell = _market(false, true);
        uint256 fee = filler.executionFee();
        uint256 net = _netQuote(m, true, 100e6, fee);
        Snap memory before = _snap(m, filler, address(this));
        uint256 keeper = before.keeper;

        // Orders are signed before vm.expectRevert: signing reads Permit2, which would be the "next call".
        // Slippage: a minimum the pool cannot meet.
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, type(uint128).max, 200);
        vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", type(uint128).max, net));
        _fill(filler, signed, m.key);
        // Too small for the app fee plus the execution fee.
        signed = _order(USDC, address(m.token), _exactFeeInput(false, fee), 1, 201);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
        _fill(filler, signed, m.key);
        // A sell one unit short of owed + fee.
        uint256 got = _netQuote(launchSell, false, 1000000e18, 0);
        signed = _order(address(launchSell.token), USDC, 1000000e18, got - fee + 1, 202);
        _expectShortSell(launchSell, got + 1, got);
        _fill(filler, signed, launchSell.key);
        // Cancelled nonce.
        SignedOrder memory cancelled = _order(USDC, address(m.token), 100e6, net, 203);
        vm.prank(trader);
        XPermit2(address(permit2)).invalidateUnorderedNonces(0, 1 << 203);
        vm.expectRevert();
        _fill(filler, cancelled, m.key);
        // Wrong pool.
        PoolKey memory wrong = PoolKey(m.key.currency0, m.key.currency1, 500, m.key.tickSpacing, m.key.hooks);
        signed = _order(USDC, address(m.token), 100e6, net, 204);
        vm.expectRevert();
        _fill(filler, signed, wrong);
        // Input-token protocol fee.
        reactor.setProtocolFeeController(address(new MockFeeController(makeAddr("uniswap fee"), 5, true)));
        signed = _order(USDC, address(m.token), 100e6, net, 205);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
        _fill(filler, signed, m.key);
        reactor.setProtocolFeeController(address(0));
        // Dead expiring order (+21).
        SignedOrder memory dead = _expiringOrder(USDC, address(m.token), 100e6, net / 2, 206, block.number, 0);
        uint256 head = block.number;
        SignedOrder memory expired = _order(USDC, address(m.token), 100e6, net, 207);
        vm.roll(head + EXPIRY_BLOCKS + 1);
        vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
        _fill(filler, dead, m.key);
        // Past the deadline.
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert();
        _fill(filler, expired, m.key);
        _assertUnchanged(before, _snap(m, filler, address(this)), "revert paths");
        for (uint256 nonce = 200; nonce < 208; ++nonce) {
            if (nonce != 203) assertFalse(_nonceUsed(nonce), "refused order left open");
        }
        // Replay: the first fill pays once; the replay pays nothing.
        vm.warp(block.timestamp - 1 days - 1);
        SignedOrder memory once = _order(USDC, address(m.token), 100e6, net / 2, 208);
        _fill(filler, once, m.key);
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - keeper, fee);
        vm.expectRevert();
        _fill(filler, once, m.key);
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - keeper, fee, "replay paid nothing");
    }

    /// The trader's output falls short after a transfer tax: NetMinimumNotMet, and no fee.
    function test_execFeeNotPaidWhenNetMinimumUnmet() public {
        (Market memory m, AdversarialTradeToken token) = _adversarialMarket(false);
        uint256 net = _netQuote(m, true, 100e6, filler.executionFee());
        // A 10% tax: the filler keeps 90% of the swap, enough to pay the reactor 85%, but the trader's two taxed
        // receipts come to 81%, below the 85% minimum.
        SignedOrder memory signed = _order(USDC, address(token), 100e6, net * 85 / 100, 210);
        token.configure(1000, address(0), "");
        Snap memory before = _snap(m, filler, address(this));
        vm.expectRevert(MercuriOrderFiller.NetMinimumNotMet.selector);
        _fill(filler, signed, m.key);
        _assertUnchanged(before, _snap(m, filler, address(this)), "net minimum unmet");
        assertFalse(_nonceUsed(210));
    }

    /// The smallest sell whose USDC output covers a 10 USDC signed minimum plus the maximum fee.
    function _smallestViableSell(Market memory m, uint256 needed) internal returns (uint256 lo) {
        uint256 hi = _amount(address(m.key.hooks) == address(hook), false) * 4;
        lo = 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_netQuote(m, false, mid, 0) >= needed) hi = mid;
            else lo = mid + 1;
        }
    }

    /// Fee at its maximum with the minimum order (spec D15: 10 USDC on the USDC side).
    function test_execFeeAtMaxWithMinimumOrder() public {
        MercuriOrderFiller f = _newFiller(MAX_FEE);
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            Snap memory before = _snap(m, f, address(this));
            if (buy) {
                uint256 net = _netQuote(m, true, 10e6, MAX_FEE);
                _fill(f, _order(USDC, address(m.token), 10e6, net, 220 + route), m.key);
                assertEq(IERC20(address(m.token)).balanceOf(trader) - before.traderToken, net);
                assertEq(before.traderUsdc - IERC20(USDC).balanceOf(trader), 10e6);
            } else {
                uint256 amount = _smallestViableSell(m, 10e6 + MAX_FEE);
                uint256 got = _netQuote(m, false, amount, 0);
                assertLt(_netQuote(m, false, amount - 1, 0), 10e6 + MAX_FEE, "one unit less is not viable");
                _fill(f, _order(address(m.token), USDC, amount, 10e6, 220 + route), m.key);
                assertEq(IERC20(USDC).balanceOf(trader) - before.traderUsdc, got - MAX_FEE);
                assertGe(got - MAX_FEE, 10e6);
            }
            assertEq(IERC20(USDC).balanceOf(feeRecipient) - before.keeper, MAX_FEE);
            _assertFillerClean(m, f);
        }
    }

    /// Orders bind the reactor and cosigner, not the filler, so an order signed before the fee existed (same
    /// format) fills through the fee-charging filler when it has room above its minimum, and is refused with
    /// nothing moved when its minimum leaves no room for the fee.
    function test_execFeePreFeeOrderFillsThroughNewFiller() public {
        MercuriOrderFiller old = _newFiller(0);
        uint256 fee = filler.executionFee();
        Market memory m = _market(false, true);
        uint256 gross = _netQuote(m, false, 1000000e18, 0);
        // Signed at the exact pre-fee quote: the old filler fills it; the new one refuses (V4TooLittleReceived).
        SignedOrder memory exact = _order(address(m.token), USDC, 1000000e18, gross, 230);
        uint256 snap = vm.snapshotState();
        _fill(old, exact, m.key);
        assertTrue(vm.revertToState(snap));
        Snap memory before = _snap(m, filler, address(this));
        _expectShortSell(m, gross + fee, gross);
        _fill(filler, exact, m.key);
        _assertUnchanged(before, _snap(m, filler, address(this)), "pre-fee exact quote");
        assertFalse(_nonceUsed(230));
        // A standing order with room above its minimum: same trader signature, fills through the new filler.
        SignedOrder memory forOld =
            _expiringOrderFor(address(m.token), USDC, 1000000e18, gross / 2, 231, block.number, 0, address(old));
        SignedOrder memory forNew =
            _expiringOrderFor(address(m.token), USDC, 1000000e18, gross / 2, 231, block.number, 0, address(filler));
        assertEq(forOld.sig, forNew.sig, "the trader's signature does not name the filler");
        _fill(filler, forNew, m.key);
        assertEq(IERC20(USDC).balanceOf(trader) - before.traderUsdc, gross - fee);
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - before.keeper, fee);
        _assertFillerClean(m, filler);
    }

    /// Fee on vs fee off on the same signed order: the trader's result differs by the fee and nothing else.
    function test_execFeeTraderSurplusMatchesZeroFeeExceptFee() public {
        MercuriOrderFiller off = _newFiller(0);
        uint256 fee = filler.executionFee();
        for (uint256 route; route < 4; ++route) {
            bool launch = route < 2;
            bool buy = route % 2 == 0;
            Market memory m = _market(buy, launch);
            uint128 amount = _amount(launch, buy);
            (address input, address output) = _io(m, buy);
            SignedOrder memory signed = _order(input, output, amount, _netQuote(m, buy, amount, fee) / 2, 240 + route);
            uint256 expectedOn = _netQuote(m, buy, amount, fee);
            uint256 expectedOff = _netQuote(m, buy, amount, 0);
            Snap memory before = _snap(m, filler, address(this));
            uint256 snap = vm.snapshotState();
            _fill(off, signed, m.key);
            Snap memory withoutFee = _snap(m, off, address(this));
            assertTrue(vm.revertToState(snap));
            _fill(filler, signed, m.key);
            Snap memory withFee = _snap(m, filler, address(this));
            if (buy) {
                assertEq(withFee.traderUsdc, withoutFee.traderUsdc, "same input spent");
                assertEq(withFee.traderToken - before.traderToken, expectedOn, "output priced from input less fee");
                assertEq(withoutFee.traderToken - before.traderToken, expectedOff, "fee-off output");
            } else {
                assertEq(withoutFee.traderUsdc - before.traderUsdc, expectedOff, "fee-off output");
                assertEq(withoutFee.traderUsdc - withFee.traderUsdc, fee, "sell: exactly the fee less");
                assertEq(withFee.traderToken, withoutFee.traderToken, "same input spent");
            }
            assertEq(withFee.app, withoutFee.app, "same app fee");
            assertEq(withFee.keeper - withoutFee.keeper, fee, "the fee is the only difference");
        }
    }

    function testFuzz_executionFeeConservation(
        uint256 amountSeed,
        uint256 feeSeed,
        uint256 minSeed,
        bool buy,
        bool launch,
        bool protocolOn
    ) public {
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        MercuriOrderFiller f = _newFiller(fee);
        Market memory m = _market(buy, launch);
        uint256 amount = buy || !launch ? bound(amountSeed, 1, 100e6) : bound(amountSeed, 1e12, 1e24);
        (address input, address output) = _io(m, buy);
        uint256 appFee = _appFee(m, buy, amount);
        Snap memory before = _snap(m, f, address(this));
        // Signed before vm.expectRevert: signing reads Permit2, which would be the "next call".
        SignedOrder memory tiny = _order(input, output, amount, 1, 250);
        if (buy && amount <= appFee + fee) {
            vm.expectRevert(MercuriOrderFiller.InvalidOrder.selector);
            _fill(f, tiny, m.key);
            _assertUnchanged(before, _snap(m, f, address(this)), "too-small buy");
            assertFalse(_nonceUsed(250));
            return;
        }
        uint256 got = _netQuote(m, buy, amount, buy ? fee : 0); // buy: tokens out; sell: USDC after any app fee
        if (!buy && got < fee + 1) {
            // Output cannot cover a 1-unit minimum plus the fee.
            if (launch) {
                vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", fee + 1, got));
            } else {
                vm.expectRevert(abi.encodeWithSignature("InsufficientToken()"));
            }
            _fill(f, tiny, m.key);
            _assertUnchanged(before, _snap(m, f, address(this)), "sell below the fee");
            assertFalse(_nonceUsed(250));
            return;
        }
        // The signed minimum is fuzzed over everything the fill can pay: a buy's output, a sell's output less the fee,
        // each less room for a 5 bps protocol fee when it is on (the reactor takes it on top of the minimum).
        uint256 bps = protocolOn ? 5 : 0;
        address feeTo = makeAddr("uniswap fee");
        uint256 cap = (buy ? got : got - fee) * 10_000 / (10_000 + bps);
        if (cap == 0) return; // no signable minimum of at least 1 leaves room for the fee
        uint256 minimum = bound(minSeed, 1, cap);
        if (protocolOn) reactor.setProtocolFeeController(address(new MockFeeController(feeTo, bps, false)));
        SignedOrder memory signed = _order(input, output, amount, minimum, 250);
        uint256 pmBefore = _usdcOf(address(poolManager));
        uint256 hookBefore = _usdcOf(address(feeManager));
        uint256 feeToBefore = IERC20(output).balanceOf(feeTo);
        before = _snap(m, f, address(this));
        _fill(f, signed, m.key);
        Snap memory afterFill = _snap(m, f, address(this));
        uint256 protocolFee = IERC20(output).balanceOf(feeTo) - feeToBefore;
        assertEq(protocolFee, minimum * bps / 10_000, "protocol fee");
        assertEq(afterFill.keeper - before.keeper, fee, "fee recipient gets exactly the fee");
        assertEq(afterFill.app - before.app, appFee, "app fee");
        assertEq(afterFill.caller, before.caller, "caller earns nothing");
        if (buy) {
            // Independent quantity: the USDC the pool manager received is the swap input, and the trader's whole USDC
            // outlay is that plus the app fee and the execution fee. The protocol fee is in the token, not USDC.
            // A Launch pool's hook fee is taken out of the pool manager to the fee manager, so add it back.
            uint256 swapIn = _usdcOf(address(poolManager)) + (_usdcOf(address(feeManager)) - hookBefore) - pmBefore;
            assertEq(swapIn, amount - appFee - fee, "pool manager received the swap input");
            assertEq(before.traderUsdc - afterFill.traderUsdc, swapIn + appFee + fee, "conservation");
            assertGe(afterFill.traderToken - before.traderToken, minimum, "trader gets at least the signed minimum");
            assertEq(
                afterFill.traderToken - before.traderToken + protocolFee, got, "token: trader + protocol fee = output"
            );
        } else {
            // Independent quantity: the USDC the pool manager paid out is the swap output, and it splits exactly into
            // trader + execution fee + app fee + protocol fee.
            uint256 swapOut = pmBefore - _usdcOf(address(poolManager)) - (_usdcOf(address(feeManager)) - hookBefore);
            uint256 traderDelta = afterFill.traderUsdc - before.traderUsdc;
            assertEq(swapOut, traderDelta + fee + appFee + protocolFee, "conservation");
            assertGe(traderDelta, minimum, "trader gets at least the signed minimum");
            assertEq(before.traderToken - afterFill.traderToken, amount);
        }
        _assertFillerClean(m, f);
        assertTrue(_nonceUsed(250));
    }
}
