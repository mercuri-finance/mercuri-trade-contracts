// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniswapXFillerHarness} from "../integration/UniswapXFiller.t.sol";
import {SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {MercuriOrderValidator} from "../../src/MercuriOrderValidator.sol";
import {IValidationCallback} from "../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {V3DutchOrder} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {MockFeeController} from "../utils/MockFeeController.sol";
import {CallbackFiller} from "../utils/CallbackFiller.sol";
import {ExclusivityLib} from "../../lib/uniswapx/src/lib/ExclusivityLib.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface ITradeExercise {
    function exercise(uint256 seed) external;
    function toggleOutputFee() external;
    function exerciseExpiring(uint256 offset) external;
    function inputFeeAttempt(uint256 seed) external;
    function feeFill(uint256 seed) external;
    function exerciseValidation(uint256 seed) external;
}

contract TradeSequenceHandler {
    ITradeExercise immutable suite;

    constructor(ITradeExercise s) {
        suite = s;
    }

    /// One fill-path action, then the four spec D22 actions in turn (an order without our validator, one routed through
    /// a pool it did not sign, an untriggered take-profit or stop-loss, and a triggered one). Running all four on every
    /// step, rather than a separate selector, keeps their per-run reachability checks as likely as the step itself.
    function step(uint256 seed) external {
        suite.exercise(seed);
        uint256 validation = uint256(keccak256(abi.encode(seed))) >> 2 << 2;
        for (uint256 action; action < 4; ++action) {
            suite.exerciseValidation(validation | action);
        }
    }

    function toggleOutputFee() external {
        suite.toggleOutputFee();
    }

    function inputFeeAttempt(uint256 seed) external {
        suite.inputFeeAttempt(seed);
    }

    function feeFill(uint256 seed) external {
        suite.feeFill(seed);
    }

    /// Settles one late-cosigned order inside its window and refuses one past it. The reachability checks in
    /// `afterInvariant` run per run, so a per-call coin flip between the two sides left about one run in 850 with no
    /// expired-order refusal (TRD-06); pairing them makes both depend only on this selector being called.
    function expiring(uint256 seed) external {
        uint256 even = seed >> 1 << 1;
        suite.exerciseExpiring(even); // even: inside the window, an outside filler refused, ours fills
        suite.exerciseExpiring(even | 1); // odd: past the window, ours refused
    }
}

/// @dev Sequence properties for the new Trade filler, separate from Launch invariants.
contract TradeInvariantsTest is UniswapXFillerHarness {
    using StateLibrary for IPoolManager;

    Market[4] internal markets;
    TradeSequenceHandler internal handler;
    mapping(address => uint256) internal donated;
    bytes private lastOrder;
    bytes private lastSignature;
    PoolKey private lastPool;
    uint256 private nextNonce;
    uint256 public successfulFills;
    uint256 public expectedFailures;
    uint256 public cancellations;
    uint256 public steps;
    uint256 public feeFills;
    uint256 public inputFeeRejections;
    uint256 internal feeFillsBase;
    uint256 internal inputFeeRejectionsBase;
    uint256 public expiredRejections;
    uint256 internal expiredRejectionsBase;
    uint256 public exclusiveRejections;
    uint256 internal exclusiveRejectionsBase;
    CallbackFiller internal outsider;
    bool internal outputFeeOn;
    uint256 private beforeProtocolFee; // storage: `exercise` is at the stack limit
    address internal feeTo;
    MockFeeController internal outputFee;
    MockFeeController internal inputFee;
    /// Non-keeper callers, none of whom is the trader, a fee recipient, the filler or the router. Before every fill
    /// one of them tries first and must be refused `NotKeeper` (spec D20); the keeper (`feeRecipient`) then fills.
    address[3] internal callers;
    uint256[3] public notKeeperRejections;
    uint256[3] internal notKeeperRejectionsBase;
    /// Ghost: the fee recipient's USDC gained across fills, measured per fill. Must equal fills x executionFee.
    uint256 public executionFeesPaid;
    uint256 internal executionFeesPaidBase;
    uint256 internal keeperStart;
    /// Spec D22 reachability: refusals of orders without our validator, of fills through an unsigned pool and of
    /// untriggered conditions, and fills of triggered take-profit and stop-loss orders.
    uint256 public wrongValidatorRejections;
    uint256 public unsignedPoolRejections;
    uint256 public untriggeredRejections;
    uint256 public triggeredFills;
    uint256[4] internal validationBase;
    MercuriOrderValidator internal lookalike;

    function setUp() public virtual override {
        super.setUp();
        keeperStart = IERC20(USDC).balanceOf(feeRecipient);
        for (uint256 i; i < 3; ++i) {
            callers[i] = makeAddr(string.concat("fill caller ", vm.toString(i)));
        }
        markets[0] = _market(true, true);
        markets[1] = _market(false, true);
        for (uint256 i; i < 2; ++i) {
            Market memory m = markets[i];
            m.key.hooks = IHooks(address(0));
            m.key.fee = 3000;
            m.key.tickSpacing = 60;
            poolManager.initialize(m.key, uint160(1 << 96));
            PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
            vm.prank(bob);
            m.token.transfer(address(this), 1e18);
            m.token.approve(address(lp), type(uint256).max);
            IERC20(USDC).approve(address(lp), type(uint256).max);
            lp.modifyLiquidity(m.key, ModifyLiquidityParams(-887220, 887220, 1e9, bytes32(0)), "");
            markets[i + 2] = m;
        }
        handler = new TradeSequenceHandler(ITradeExercise(address(this)));
        outsider = new CallbackFiller(IReactor(address(reactor)));
        targetContract(address(handler));
        feeTo = makeAddr("uniswap fee");
        for (uint256 i; i < 3; ++i) {
            address c = callers[i];
            require(
                c != trader && c != appRecipient && c != feeRecipient && c != feeTo && c != address(filler)
                    && c != address(router),
                "caller set must exclude every paid party"
            );
        }
        outputFee = new MockFeeController(feeTo, 5, false);
        inputFee = new MockFeeController(feeTo, 5, true);
        lookalike = new MercuriOrderValidator(address(filler), poolManager);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.step.selector;
        selectors[1] = handler.toggleOutputFee.selector;
        selectors[2] = handler.inputFeeAttempt.selector;
        selectors[3] = handler.feeFill.selector;
        selectors[4] = handler.expiring.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        // Warm each branch, including every pool/direction, before random sequences.
        for (uint256 i; i < 4; ++i) {
            this.exercise(i * 7);
            this.exercise(i * 7 + 1);
        }
        for (uint256 i = 2; i < 7; ++i) {
            this.exercise(i);
        }
        // Warm the protocol-fee paths: one output-fee fill per direction, then one input-fee refusal.
        this.toggleOutputFee();
        this.exercise(0);
        this.exercise(1);
        this.inputFeeAttempt(0);
        this.toggleOutputFee();
        this.exerciseExpiring(0);
        this.exerciseExpiring(EXPIRY_BLOCKS + 1);
        for (uint256 i; i < 8; ++i) {
            this.exerciseValidation(i);
        }
        // Reachability is judged on campaign activity only, not on this warm-up.
        feeFillsBase = feeFills;
        inputFeeRejectionsBase = inputFeeRejections;
        expiredRejectionsBase = expiredRejections;
        exclusiveRejectionsBase = exclusiveRejections;
        executionFeesPaidBase = executionFeesPaid;
        notKeeperRejectionsBase = notKeeperRejections;
        validationBase = [wrongValidatorRejections, unsignedPoolRejections, untriggeredRejections, triggeredFills];
    }

    /// A limit condition on this market's own pool: markets 0 and 2 (and 1 and 3) share a token, so the pool is named
    /// explicitly rather than taken from the token's latest market.
    function _limit(Market memory m) internal pure returns (bytes memory) {
        return _condition(0, m.key, 0);
    }

    /// One of the fixed non-keeper callers (chosen by `salt`) submits `signed` first and must be refused `NotKeeper`
    /// with nothing moved and the nonce unused; the keeper then submits it. A successful keeper fill pays the fee
    /// recipient exactly `executionFee`; a reverted one pays nothing.
    function _tryFill(SignedOrder memory signed, PoolKey memory key, uint256 salt)
        internal
        returns (bool ok, bytes memory err)
    {
        uint256 i = uint256(keccak256(abi.encode(salt))) % 3;
        address caller = callers[i];
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        uint256 bitmapBefore = XPermit2(address(permit2)).nonceBitmap(trader, order.info.nonce >> 8);
        uint256 keeperBefore = IERC20(USDC).balanceOf(feeRecipient);
        uint256 callerBefore = IERC20(USDC).balanceOf(caller);
        uint256 traderBefore = IERC20(USDC).balanceOf(trader);
        vm.prank(caller);
        try filler.fill(signed, key) {
            fail("a non-keeper filled");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), MercuriOrderFiller.NotKeeper.selector, "non-keeper refused for another reason");
        }
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, order.info.nonce >> 8), bitmapBefore, "nonce used");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), keeperBefore, "non-keeper attempt paid a fee");
        assertEq(IERC20(USDC).balanceOf(caller), callerBefore, "non-keeper moved its USDC");
        assertEq(IERC20(USDC).balanceOf(trader), traderBefore, "non-keeper moved trader USDC");
        notKeeperRejections[i]++;
        vm.prank(feeRecipient);
        try filler.fill(signed, key) {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
        uint256 paid = IERC20(USDC).balanceOf(feeRecipient) - keeperBefore;
        assertEq(paid, ok ? filler.executionFee() : 0, "execution fee once per fill, never on a revert");
        assertEq(IERC20(USDC).balanceOf(caller), callerBefore, "a non-keeper earns nothing");
        if (ok) executionFeesPaid += paid;
    }

    /// `_tryFill` for a fill that must succeed; bubbles the revert reason otherwise.
    function _fill(SignedOrder memory signed, PoolKey memory key, uint256 salt) internal {
        (bool ok, bytes memory err) = _tryFill(signed, key, salt);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    /// Runs one successful fill with the output-token protocol fee on, then restores the prior fee state.
    function feeFill(uint256 seed) external {
        require(msg.sender == address(handler) || msg.sender == address(this), "handler only");
        bool previous = outputFeeOn;
        if (!previous) {
            outputFeeOn = true;
            reactor.setProtocolFeeController(address(outputFee));
        }
        this.exercise(seed / 7 * 7 + seed % 2); // action 0 or 1: a fill that must succeed
        if (!previous) {
            outputFeeOn = false;
            reactor.setProtocolFeeController(address(0));
        }
    }

    /// Fills a late-cosigned expiring buy `offset` blocks after the cosigning head (even seeds land inside the window, odd
    /// ones past it). Inside the window an outside filler is refused as `NoExclusiveOverride` and ours fills through +20;
    /// from +21 ours is refused as `AmountOverflow`. The filler stays empty and a refused order leaves the nonce unused.
    function exerciseExpiring(uint256 offset) external {
        require(msg.sender == address(handler) || msg.sender == address(this), "handler only");
        offset = offset % 2 == 0 ? offset / 2 % (EXPIRY_BLOCKS + 1) : EXPIRY_BLOCKS + 1 + offset / 2 % 20; // both sides of +20
        Market memory m = markets[offset % 4];
        uint128 amount = 1e6 + uint128(offset) * 1e5;
        bool app = address(m.key.hooks) == address(0);
        uint256 minimum = _netQuote(m, true, amount, filler.executionFee()); // spec D14
        if (outputFeeOn) minimum = minimum * 10_000 / 10_005; // room for the 5 bps protocol fee
        uint256 nonce = nextNonce++;
        uint256 start = block.number;
        SignedOrder memory signed = _expiringOrderWith(
            USDC, address(m.token), amount, minimum / 2, nonce, start, minimum, address(filler), _limit(m)
        );
        vm.roll(start + offset);
        uint256 beforeInput = IERC20(USDC).balanceOf(trader);
        uint256 beforeOutput = IERC20(address(m.token)).balanceOf(trader);
        uint256 beforeBitmap = XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8);
        steps++;
        if (offset <= EXPIRY_BLOCKS) {
            try outsider.fill(signed) {
                fail("outsider filled an exclusive order");
            } catch (bytes memory err) {
                assertEq(
                    bytes4(err), ExclusivityLib.NoExclusiveOverride.selector, "outsider refused for another reason"
                );
                exclusiveRejections++;
            }
            assertEq(IERC20(USDC).balanceOf(trader), beforeInput, "outsider spent input");
            assertEq(XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8), beforeBitmap, "outsider used nonce");
            _fill(signed, m.key, nonce);
            assertEq(beforeInput - IERC20(USDC).balanceOf(trader), amount, "expiring exact input");
            assertGe(IERC20(address(m.token)).balanceOf(trader) - beforeOutput, minimum, "expiring output");
            assertEq(
                XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8),
                beforeBitmap | (1 << (nonce & 255)),
                "expiring nonce used"
            );
            successfulFills++;
        } else {
            (bool ok, bytes memory err) = _tryFill(signed, m.key, nonce);
            assertFalse(ok, "expired order filled");
            assertEq(bytes4(err), MercuriOrderFiller.AmountOverflow.selector, "expiry reverted for another reason");
            expiredRejections++;
            assertEq(IERC20(USDC).balanceOf(trader), beforeInput, "expired fill spent input");
            assertEq(
                XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8), beforeBitmap, "expired fill used nonce"
            );
        }
        assertEq(IERC20(USDC).balanceOf(address(filler)), donated[USDC], "expiring filler USDC");
        assertEq(
            IERC20(address(m.token)).balanceOf(address(filler)), donated[address(m.token)], "expiring filler token"
        );
        assertEq(IERC20(USDC).allowance(address(filler), address(reactor)), 0);
        assertEq(IERC20(address(m.token)).allowance(address(filler), address(reactor)), 0);
    }

    /// Switches the reactor's protocol fee (5 bps of the trader output) on or off.
    function toggleOutputFee() external {
        require(msg.sender == address(handler) || msg.sender == address(this), "handler only");
        outputFeeOn = !outputFeeOn;
        reactor.setProtocolFeeController(outputFeeOn ? address(outputFee) : address(0));
    }

    /// With an input-token fee controller the fill must be refused and leave the order open.
    function inputFeeAttempt(uint256 seed) external {
        require(msg.sender == address(handler) || msg.sender == address(this), "handler only");
        Market memory m = markets[seed % 4];
        uint256 nonce = nextNonce++;
        SignedOrder memory signed = _orderWith(USDC, address(m.token), 1e6 + seed % 5e6, 1, nonce, _limit(m));
        reactor.setProtocolFeeController(address(inputFee));
        uint256 beforeUSDC = IERC20(USDC).balanceOf(trader);
        uint256 beforeBitmap = XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8);
        (bool ok, bytes memory err) = _tryFill(signed, m.key, nonce);
        assertFalse(ok, "input-fee fill succeeded");
        assertEq(
            bytes4(err), MercuriOrderFiller.FeeOutputUnsupported.selector, "input-fee fill reverted for another reason"
        );
        inputFeeRejections++;
        assertEq(IERC20(USDC).balanceOf(trader), beforeUSDC, "input-fee fill spent input");
        assertEq(XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8), beforeBitmap, "input-fee nonce used");
        reactor.setProtocolFeeController(outputFeeOn ? address(outputFee) : address(0));
    }

    function exercise(uint256 seed) external {
        require(msg.sender == address(handler) || msg.sender == address(this), "handler only");
        steps++;
        uint256 action = seed % 7;
        Market memory m = markets[(seed / 7) % 4];
        bool buy = action != 1;
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        uint128 amount = uint128(1e6 + (seed / 28) % 5e6);
        if (!buy && address(m.key.hooks) != address(0)) amount = uint128(1000e18 + (seed / 28) % 10000e18);
        uint256 nonce = nextNonce++;
        if (action == 5) {
            uint256 dust = 1 + (seed / 28) % 100;
            address asset = seed / 28 % 2 == 0 ? input : output;
            vm.prank(trader);
            IERC20(asset).transfer(address(filler), dust);
            donated[asset] += dust;
            return;
        }
        if (action == 4) {
            require(lastOrder.length > 0, "warmup needs a fill");
            uint256 beforeUSDC = IERC20(USDC).balanceOf(trader);
            (bool replayed,) = _tryFill(SignedOrder(lastOrder, lastSignature), lastPool, nonce);
            assertFalse(replayed, "replay succeeded");
            expectedFailures++;
            assertEq(IERC20(USDC).balanceOf(trader), beforeUSDC, "replay spent USDC");
            return;
        }
        uint256 minimum = 1;
        uint256 expectedAppFee;
        if (action <= 1) {
            bool app = address(m.key.hooks) == address(0);
            expectedAppFee = app ? (buy ? uint256(amount) * 50 / 10000 : _quote(m, false, amount, "") * 50 / 10000) : 0;
            minimum = _netQuote(m, buy, amount, filler.executionFee()); // spec D14: net of app and execution fees
            if (outputFeeOn) minimum = minimum * 10_000 / 10_005; // room for the 5 bps protocol fee
            assertGt(minimum, 0, "meaningful quote");
        }
        if (action == 3) minimum = type(uint128).max;
        SignedOrder memory signed = _orderWith(input, output, amount, minimum, nonce, _limit(m));
        uint256 beforeInput = IERC20(input).balanceOf(trader);
        uint256 beforeOutput = IERC20(output).balanceOf(trader);
        uint256 beforeFee = IERC20(USDC).balanceOf(appRecipient);
        beforeProtocolFee = IERC20(output).balanceOf(feeTo);
        if (action == 2) {
            vm.prank(trader);
            XPermit2(address(permit2)).invalidateUnorderedNonces(nonce >> 8, 1 << (nonce & 255));
            cancellations++;
        }
        if (action == 6) vm.warp(block.timestamp + 1 days + 1);
        uint256 beforeBitmap = XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8);
        if (action >= 2) {
            (bool ok,) = _tryFill(signed, m.key, nonce);
            assertFalse(ok, "invalid order succeeded");
            expectedFailures++;
            assertEq(IERC20(input).balanceOf(trader), beforeInput, "failed fill spent input");
            assertEq(IERC20(output).balanceOf(trader), beforeOutput, "failed fill changed output");
            assertEq(IERC20(USDC).balanceOf(appRecipient), beforeFee, "failed fill charged fee");
            assertEq(
                XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8), beforeBitmap, "failed fill consumed nonce"
            );
        } else {
            _fill(signed, m.key, nonce);
            successfulFills++;
            assertEq(beforeInput - IERC20(input).balanceOf(trader), amount, "exact input");
            if (outputFeeOn) {
                feeFills++;
                assertGe(IERC20(output).balanceOf(trader) - beforeOutput, minimum, "net output with fee");
                assertEq(IERC20(output).balanceOf(feeTo) - beforeProtocolFee, minimum * 5 / 10_000, "protocol fee");
            } else {
                assertEq(IERC20(output).balanceOf(trader) - beforeOutput, minimum, "net output");
            }
            assertEq(IERC20(USDC).balanceOf(appRecipient) - beforeFee, expectedAppFee, "app fee");
            assertEq(
                XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8),
                beforeBitmap | (1 << (nonce & 255)),
                "nonce used"
            );
            lastOrder = signed.order;
            lastSignature = signed.sig;
            lastPool = m.key;
        }
    }

    /// Spec D22 actions, chosen by `seed % 4` on market `seed / 4 % 4`, buy or sell by `seed / 16`:
    /// 0. an order naming no validator or a look-alike validator that also accepts our filler: `WrongValidator`;
    /// 1. an order signed for this market's pool, filled through the other pool of the same token: `PoolNotSigned`;
    /// 2. a take-profit or stop-loss one unit short of its trigger: `TriggerNotReached`;
    /// 3. the same at the pool's current price: it fills and pays at least the signed minimum.
    /// Every refusal follows a refused non-keeper attempt and moves nothing, pays no fee and leaves the nonce unused.
    function exerciseValidation(uint256 seed) external {
        require(msg.sender == address(handler) || msg.sender == address(this), "handler only");
        steps++;
        uint256 action = seed % 4;
        uint256 index = seed / 4 % 4;
        Market memory m = markets[index];
        bool buy = seed / 16 % 2 == 0;
        (address input, address output) = buy ? (USDC, address(m.token)) : (address(m.token), USDC);
        uint128 amount = uint128(1e6 + (seed / 32) % 5e6);
        if (!buy && address(m.key.hooks) != address(0)) amount = uint128(1000e18 + (seed / 32) % 10000e18);
        uint256 nonce = nextNonce++;
        uint8 kind = uint8(1 + seed / 64 % 2);
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(keccak256(abi.encode(m.key))));
        bool up = (kind == 1) == (input < output);
        SignedOrder memory signed;
        PoolKey memory key = m.key;
        if (action == 0) {
            IValidationCallback other = seed / 128 % 2 == 0 ? IValidationCallback(address(0)) : lookalike;
            signed = _orderFor(input, output, amount, 1, nonce, other, _limit(m));
        } else if (action == 1) {
            signed = _orderWith(input, output, amount, 1, nonce, _limit(m));
            key = markets[(index + 2) % 4].key; // the same token's other pool
        } else {
            uint160 trigger = action == 3 ? price : (up ? price + 1 : price - 1);
            uint256 minimum = 1;
            if (action == 3) {
                minimum = _netQuote(m, buy, amount, filler.executionFee()) / 2;
                if (outputFeeOn) minimum = minimum * 10_000 / 10_005;
            }
            signed = _orderWith(input, output, amount, minimum, nonce, _condition(kind, m.key, trigger));
        }
        uint256 beforeInput = IERC20(input).balanceOf(trader);
        uint256 beforeOutput = IERC20(output).balanceOf(trader);
        (bool ok, bytes memory err) = _tryFill(signed, key, nonce);
        if (action == 3) {
            if (!ok) {
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
            successfulFills++;
            triggeredFills++;
            assertEq(beforeInput - IERC20(input).balanceOf(trader), amount, "triggered exact input");
            assertGt(IERC20(output).balanceOf(trader), beforeOutput, "triggered output");
            assertTrue(_nonceUsedBy(nonce), "triggered nonce used");
            return;
        }
        assertFalse(ok, "invalid order filled");
        bytes4[3] memory expected = [
            MercuriOrderFiller.WrongValidator.selector,
            MercuriOrderFiller.PoolNotSigned.selector,
            MercuriOrderValidator.TriggerNotReached.selector
        ];
        assertEq(bytes4(err), expected[action], "refused for another reason");
        if (action == 0) wrongValidatorRejections++;
        else if (action == 1) unsignedPoolRejections++;
        else untriggeredRejections++;
        assertEq(IERC20(input).balanceOf(trader), beforeInput, "refused order moved input");
        assertEq(IERC20(output).balanceOf(trader), beforeOutput, "refused order moved output");
        assertFalse(_nonceUsedBy(nonce), "refused order used its nonce");
    }

    function _nonceUsedBy(uint256 nonce) internal view returns (bool) {
        return XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8) & (1 << (nonce & 255)) != 0;
    }

    /// The filler and its validator name each other for life (spec D22).
    function invariant_validatorBinding() public view {
        MercuriOrderValidator v = MercuriOrderValidator(address(filler.validator()));
        assertGt(address(v).code.length, 0, "validator code");
        assertEq(v.filler(), address(filler), "validator bound to the filler");
        assertEq(address(v.poolManager()), address(poolManager), "validator pool manager");
    }

    /// The fee recipient's USDC grew by exactly one execution fee per successful fill, and by nothing else.
    function invariant_executionFeePerFill() public view {
        assertEq(executionFeesPaid, successfulFills * filler.executionFee(), "ghost: fills x fee");
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - keeperStart, executionFeesPaid, "fee recipient balance");
    }

    function invariant_tradeCustodyAndApprovals() public view {
        assertEq(IERC20(USDC).balanceOf(address(filler)), donated[USDC], "USDC donation isolation");
        assertEq(IERC20(USDC).allowance(address(filler), address(permit2)), 0);
        assertEq(IERC20(USDC).allowance(address(filler), address(reactor)), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router USDC dust");
        for (uint256 i; i < 4; ++i) {
            address token = address(markets[i].token);
            assertEq(IERC20(token).balanceOf(address(filler)), donated[token], "token donation isolation");
            assertEq(IERC20(token).balanceOf(address(router)), 0, "router token dust");
            assertEq(IERC20(token).allowance(address(filler), address(permit2)), 0);
            assertEq(IERC20(token).allowance(address(filler), address(reactor)), 0);
        }
    }

    function afterInvariant() public view {
        assertGe(successfulFills, 8, "warmup did not exercise all routes");
        assertGt(cancellations, 0);
        assertGt(expectedFailures, 0);
        assertGt(feeFills, feeFillsBase, "campaign never ran an output-fee fill");
        assertGt(inputFeeRejections, inputFeeRejectionsBase, "campaign never saw an input-fee rejection");
        assertGt(expiredRejections, expiredRejectionsBase, "campaign never saw an expired-order rejection");
        assertGt(exclusiveRejections, exclusiveRejectionsBase, "campaign never saw an exclusivity rejection");
        assertGt(executionFeesPaid, executionFeesPaidBase, "campaign never paid an execution fee");
        assertEq(executionFeesPaid, successfulFills * filler.executionFee(), "ghost: fills x fee");
        for (uint256 i; i < 3; ++i) {
            assertGt(notKeeperRejections[i], notKeeperRejectionsBase[i], "campaign never refused every non-keeper");
        }
        assertGt(wrongValidatorRejections, validationBase[0], "campaign never refused an order without our validator");
        assertGt(unsignedPoolRejections, validationBase[1], "campaign never refused an unsigned pool");
        assertGt(untriggeredRejections, validationBase[2], "campaign never refused an untriggered order");
        assertGt(triggeredFills, validationBase[3], "campaign never filled a triggered order");
        assertGe(steps, 13);
    }
}
