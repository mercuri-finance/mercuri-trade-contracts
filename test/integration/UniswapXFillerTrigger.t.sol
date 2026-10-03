// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {ExclusivityLib} from "../../lib/uniswapx/src/lib/ExclusivityLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {MercuriOrderValidator} from "../../src/MercuriOrderValidator.sol";
import {IOrderSwapRouter} from "../../src/interfaces/IOrderSwapRouter.sol";
import {UniswapXFillerHarness} from "./UniswapXFiller.t.sol";
import {CallbackFiller} from "../utils/CallbackFiller.sol";

/// @notice On-chain order validation (spec D22) through the real reactor, filler and validator: the filler refuses
///         orders that do not name its validator and pools other than the signed one, take-profit and stop-loss fill
///         only at or beyond their trigger on every route, and a key-compromise drill (the attacker holds the keeper
///         and the cosigner keys) can neither fill an untriggered order, nor route through another pool, nor use
///         another filler, and extracts at most the order's value less its signed minimum from a triggered one.
contract UniswapXFillerTriggerTest is UniswapXFillerHarness {
    using StateLibrary for IPoolManager;

    uint8 internal constant LIMIT = 0;
    uint8 internal constant TAKE_PROFIT = 1;
    uint8 internal constant STOP_LOSS = 2;
    /// A listed pool's default stop-loss band (spec D21): 3%.
    uint256 internal constant BAND_BPS = 300;

    address internal attacker = makeAddr("attacker");
    PoolSwapTest internal swapper;

    function setUp() public override {
        super.setUp();
        swapper = new PoolSwapTest(poolManager);
        vm.deal(attacker, 1_000_000e18); // native USDC backs the attacker's ERC-20 USDC balance
    }

    function _nonceUsed(uint256 nonce) internal view returns (bool) {
        return XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8) & (1 << (nonce & 255)) != 0;
    }

    function _price(PoolKey memory key) internal view returns (uint160 price) {
        (price,,,) = poolManager.getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
    }

    /// Whether `kind` fires at `price` for an order selling `input` for `output`: the rate (output per input) rises
    /// with the pool price exactly when the input is currency0.
    function _fires(address input, address output, uint8 kind, uint160 price, uint160 trigger)
        internal
        pure
        returns (bool)
    {
        bool up = (kind == TAKE_PROFIT) == (input < output);
        return up ? price >= trigger : price <= trigger;
    }

    /// The trigger one unit short of firing at `price`.
    function _justShort(address input, address output, uint8 kind, uint160 price) internal pure returns (uint160) {
        bool up = (kind == TAKE_PROFIT) == (input < output);
        return up ? price + 1 : price - 1;
    }

    /// The attacker swaps `amount` of `input` on `key` (exact input, no limit beyond v4's range).
    function _push(PoolKey memory key, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        vm.startPrank(attacker);
        IERC20(input).approve(address(swapper), type(uint256).max);
        swapper.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
    }

    function _fundAttacker(Market memory m, uint256 tokens) internal {
        vm.prank(bob);
        m.token.transfer(attacker, tokens);
    }

    /// An order with no validator, and one naming another validator that also accepts this filler, are both refused
    /// before the reactor with nothing moved and the nonce unused; the same order naming ours fills.
    function test_fillerRefusesOrderWithoutItsValidator() public {
        Market memory m = _market(true, false);
        uint256 net = _netQuote(m, true, 100e6, _executionFee());
        MercuriOrderValidator lookalike = new MercuriOrderValidator(address(filler), poolManager);
        IValidationCallback[2] memory wrong = [IValidationCallback(address(0)), lookalike];
        for (uint256 i; i < 2; ++i) {
            SignedOrder memory signed =
                _orderFor(USDC, address(m.token), 100e6, net, 400 + i, wrong[i], _limitData(USDC, address(m.token)));
            uint256 before = IERC20(USDC).balanceOf(trader);
            vm.expectRevert(MercuriOrderFiller.WrongValidator.selector);
            _fill(filler, signed, m.key);
            assertEq(IERC20(USDC).balanceOf(trader), before);
            assertFalse(_nonceUsed(400 + i));
        }
        _fill(filler, _order(USDC, address(m.token), 100e6, net, 402), m.key);
        assertTrue(_nonceUsed(402));
    }

    /// A listed market's token also has its Launch pool. An order signed for one pool is refused through the other,
    /// and through an unsigned pool of the same pair with another fee, with nothing moved; it fills through its own.
    function test_fillerRefusesPoolOtherThanSigned() public {
        Market memory m = _market(false, false);
        PoolKey memory launchKey = _key(address(m.token));
        PoolKey memory otherFee = PoolKey(m.key.currency0, m.key.currency1, 500, 10, IHooks(address(0)));
        poolManager.initialize(otherFee, _price(m.key));
        uint256 amount = 100e6;
        uint256 net = _netQuote(m, false, amount, _executionFee());
        SignedOrder memory signed = _orderWith(address(m.token), USDC, amount, net, 410, _condition(LIMIT, m.key, 0));
        PoolKey[2] memory others = [launchKey, otherFee];
        for (uint256 i; i < 2; ++i) {
            uint256 before = IERC20(USDC).balanceOf(trader);
            vm.expectRevert(MercuriOrderFiller.PoolNotSigned.selector);
            _fill(filler, signed, others[i]);
            assertEq(IERC20(USDC).balanceOf(trader), before);
            assertFalse(_nonceUsed(410));
        }
        // Signed for the Launch pool, the same order is refused through the listed one.
        SignedOrder memory forLaunch =
            _orderWith(address(m.token), USDC, 1000000e18, 1, 411, _condition(LIMIT, launchKey, 0));
        vm.expectRevert(MercuriOrderFiller.PoolNotSigned.selector);
        _fill(filler, forLaunch, m.key);
        _fill(filler, signed, m.key);
        _fill(filler, forLaunch, launchKey);
        assertTrue(_nonceUsed(410) && _nonceUsed(411));
    }

    /// Take-profit and stop-loss, buy and sell, on Launch and listed pools, with the token below and above USDC: one
    /// unit short of the trigger the validator refuses the fill (nothing moves, nonce unused); at the trigger it fills.
    function test_triggeredOrdersOnEveryRoute() public {
        uint256 nonce = 420;
        for (uint256 r; r < 4; ++r) {
            bool below = r % 2 == 0;
            bool launch = r < 2;
            Market memory m = _market(below, launch);
            for (uint256 side; side < 2; ++side) {
                bool buy = side == 0;
                (address input, address output) = buy ? (USDC, address(m.token)) : (address(m.token), USDC);
                uint256 amount = buy || !launch ? 100e6 : 1000000e18;
                for (uint8 kind = TAKE_PROFIT; kind <= STOP_LOSS; ++kind) {
                    uint160 price = _price(m.key);
                    uint160 short = _justShort(input, output, kind, price);
                    assertFalse(_fires(input, output, kind, price, short));
                    assertTrue(_fires(input, output, kind, price, price));
                    SignedOrder memory early =
                        _orderWith(input, output, amount, 1, nonce, _condition(kind, m.key, short));
                    uint256 before = IERC20(input).balanceOf(trader);
                    vm.expectRevert(MercuriOrderValidator.TriggerNotReached.selector);
                    _fill(filler, early, m.key);
                    assertEq(IERC20(input).balanceOf(trader), before, "untriggered fill moved input");
                    assertFalse(_nonceUsed(nonce));
                    uint256 snap = vm.snapshotState();
                    _fill(filler, _orderWith(input, output, amount, 1, nonce, _condition(kind, m.key, price)), m.key);
                    assertTrue(_nonceUsed(nonce));
                    assertTrue(vm.revertToState(snap));
                    ++nonce;
                }
            }
        }
    }

    /// A stop-loss sell held by a real price move: refused while the token's price is above the trigger, filled at
    /// the trigger after another trader's sale moves the pool through it.
    function test_stopLossFillsAfterMarketFalls() public {
        Market memory m = _market(true, false);
        _fundAttacker(m, 100e6);
        uint256 snap = vm.snapshotState();
        _push(m.key, address(m.token), 30e6);
        uint160 fallen = _price(m.key);
        assertTrue(vm.revertToState(snap));
        uint256 net = _netQuote(m, false, 100e6, _executionFee());
        uint256 minimum = net * (10_000 - 2 * BAND_BPS) / 10_000;
        SignedOrder memory stop =
            _orderWith(address(m.token), USDC, 100e6, minimum / 2, 430, _condition(STOP_LOSS, m.key, fallen));
        vm.expectRevert(MercuriOrderValidator.TriggerNotReached.selector);
        _fill(filler, stop, m.key);
        _push(m.key, address(m.token), 30e6);
        uint256 before = IERC20(USDC).balanceOf(trader);
        _fill(filler, stop, m.key);
        assertGe(IERC20(USDC).balanceOf(trader) - before, minimum / 2);
    }

    /// Spec §10 stress bar 12, contract part. The attacker holds the keeper key (it can call `fill`) and the cosigner
    /// key (it can cosign any order, exclusive to any filler), and has the victim's signed stop-loss. The order is
    /// not triggered. The attacker cannot fill it through our filler, through its own MercuriOrderFiller, or through
    /// a bare reactor filler; once the attacker pushes the pool through the trigger it cannot route through the Launch
    /// pool or a pool of its own, and the fill through the signed pool pays the victim at least the signed minimum,
    /// so the attacker extracts at most the order's value less that minimum (band x notional).
    function test_compromiseDrill() public {
        for (uint256 i; i < 2; ++i) {
            // A push the victim's band absorbs: the fill goes through at the manipulated price, above the minimum.
            assertTrue(_compromiseDrill(i == 0, 1e6), "small push should fill within the band");
            // A push beyond the band: the fill is refused and nothing moves.
            assertFalse(_compromiseDrill(i == 0, 100e6), "large push should leave the order unfilled");
        }
    }

    /// The bound over the push size and the token's position: every fill pays at least the signed minimum, or none
    /// happens.
    function testFuzz_compromiseExtractionBound(bool below, uint256 pushSeed) public {
        _compromiseDrill(below, bound(pushSeed, 1e6, 400e6));
    }

    function _compromiseDrill(bool below, uint256 push) internal returns (bool filled) {
        uint256 snap0 = vm.snapshotState();
        Market memory m = _market(below, false);
        uint256 amount = 100e6;
        _fundAttacker(m, 500e6);
        // The victim's protected stop: trigger = the price after the attacker's push, minimum = today's net value
        // less the 3% band. Value is the net-of-fee quote at today's (untriggered) price.
        uint256 snap = vm.snapshotState();
        _push(m.key, address(m.token), push);
        uint160 trigger = _price(m.key);
        assertTrue(vm.revertToState(snap));
        uint256 value = _netQuote(m, false, amount, _executionFee());
        uint256 minimum = value * (10_000 - BAND_BPS) / 10_000;
        uint256 nonce = 440;
        // The attacker cosigns as it likes: exclusive to our filler, and open (for an outside filler).
        SignedOrder memory ours = _expiringOrderWith(
            address(m.token),
            USDC,
            amount,
            minimum,
            nonce,
            block.number,
            0,
            address(filler),
            _condition(STOP_LOSS, m.key, trigger)
        );
        SignedOrder memory open = _expiringOrderWith(
            address(m.token),
            USDC,
            amount,
            minimum,
            nonce,
            block.number,
            0,
            address(0),
            _condition(STOP_LOSS, m.key, trigger)
        );
        uint256 traderUsdc = IERC20(USDC).balanceOf(trader);
        uint256 traderToken = IERC20(address(m.token)).balanceOf(trader);

        // 1. Untriggered: our filler (the attacker holds its keeper key) is refused by the validator.
        vm.expectRevert(MercuriOrderValidator.TriggerNotReached.selector);
        _fill(filler, ours, m.key);
        // 2. Another filler: the attacker's own MercuriOrderFiller, keyed to the attacker, and a bare reactor filler.
        MercuriOrderFiller rogue = new MercuriOrderFiller(
            IReactor(address(reactor)),
            IOrderSwapRouter(address(router)),
            permit2,
            USDC,
            address(hook),
            appRecipient,
            0,
            attacker,
            poolManager
        );
        vm.prank(attacker);
        vm.expectRevert(MercuriOrderFiller.WrongValidator.selector);
        rogue.fill(open, m.key);
        CallbackFiller outside = new CallbackFiller(IReactor(address(reactor)));
        vm.prank(attacker);
        IERC20(USDC).transfer(address(outside), 100_000e6);
        vm.expectRevert(MercuriOrderValidator.WrongFiller.selector);
        outside.fill(open);
        // Exclusive to our filler, the cosigned copy is refused for the outside filler before the validator even runs.
        vm.expectRevert(ExclusivityLib.NoExclusiveOverride.selector);
        outside.fill(ours);

        // 3. The attacker pushes the pool through the trigger (R9: same block). Other pools are still refused.
        _push(m.key, address(m.token), push);
        PoolKey memory own = PoolKey(m.key.currency0, m.key.currency1, 100, 1, IHooks(address(0)));
        poolManager.initialize(own, trigger);
        PoolKey[2] memory elsewhere = [_key(address(m.token)), own];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(MercuriOrderFiller.PoolNotSigned.selector);
            _fill(filler, ours, elsewhere[i]);
        }
        vm.expectRevert(MercuriOrderValidator.WrongFiller.selector);
        outside.fill(open);
        assertEq(IERC20(USDC).balanceOf(trader), traderUsdc, "refused attempts moved USDC");
        assertEq(IERC20(address(m.token)).balanceOf(trader), traderToken, "refused attempts moved the token");
        assertFalse(_nonceUsed(nonce));

        // 4. Through the signed pool, at the manipulated price: the victim gets at least the minimum, or nothing moves.
        vm.prank(feeRecipient);
        try filler.fill(ours, m.key) {
            uint256 received = IERC20(USDC).balanceOf(trader) - traderUsdc;
            assertGe(received, minimum, "below the signed minimum");
            uint256 extracted = value > received ? value - received : 0;
            assertLe(extracted, value - minimum, "extraction above band x notional");
            assertLe(extracted, value * BAND_BPS / 10_000, "extraction above the band");
            assertTrue(_nonceUsed(nonce));
            filled = true;
        } catch {
            assertEq(IERC20(USDC).balanceOf(trader), traderUsdc, "a refused fill moved USDC");
            assertEq(IERC20(address(m.token)).balanceOf(trader), traderToken, "a refused fill moved the token");
            assertFalse(_nonceUsed(nonce));
        }
        assertTrue(vm.revertToState(snap0));
    }
}
