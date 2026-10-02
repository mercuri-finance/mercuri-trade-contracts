// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniswapXFillerHarness} from "../integration/UniswapXFiller.t.sol";
import {SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockFeeController} from "../utils/MockFeeController.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface ITradeExercise {
    function exercise(uint256 seed) external;
    function toggleOutputFee() external;
    function inputFeeAttempt(uint256 seed) external;
}

contract TradeSequenceHandler {
    ITradeExercise immutable suite;

    constructor(ITradeExercise s) {
        suite = s;
    }

    function step(uint256 seed) external {
        suite.exercise(seed);
    }

    function toggleOutputFee() external {
        suite.toggleOutputFee();
    }

    function inputFeeAttempt(uint256 seed) external {
        suite.inputFeeAttempt(seed);
    }
}

/// Sequence properties for the new Trade filler, separate from Launch invariants.
contract TradeInvariantsTest is UniswapXFillerHarness {
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
    bool internal outputFeeOn;
    uint256 private beforeProtocolFee; // storage: `exercise` is at the stack limit
    address internal feeTo;
    MockFeeController internal outputFee;
    MockFeeController internal inputFee;

    function setUp() public virtual override {
        super.setUp();
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
        targetContract(address(handler));
        feeTo = makeAddr("uniswap fee");
        outputFee = new MockFeeController(feeTo, 5, false);
        inputFee = new MockFeeController(feeTo, 5, true);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.step.selector;
        selectors[1] = handler.toggleOutputFee.selector;
        selectors[2] = handler.inputFeeAttempt.selector;
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
        SignedOrder memory signed = _order(USDC, address(m.token), 1e6 + seed % 5e6, 1, nonce);
        reactor.setProtocolFeeController(address(inputFee));
        uint256 beforeUSDC = IERC20(USDC).balanceOf(trader);
        uint256 beforeBitmap = XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8);
        try filler.fill(signed, m.key) {
            fail("input-fee fill succeeded");
        } catch {
            inputFeeRejections++;
        }
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
            try filler.fill(SignedOrder(lastOrder, lastSignature), lastPool) {
                fail("replay succeeded");
            } catch {
                expectedFailures++;
            }
            assertEq(IERC20(USDC).balanceOf(trader), beforeUSDC, "replay spent USDC");
            return;
        }
        uint256 minimum = 1;
        uint256 expectedAppFee;
        if (action <= 1) {
            bool app = address(m.key.hooks) == address(0);
            uint128 netInput = app && buy ? uint128(amount - uint256(amount) * 50 / 10000) : amount;
            minimum = _quote(m, buy, netInput, app ? bytes("") : abi.encode(uint256(uint160(trader))));
            expectedAppFee = app ? (buy ? uint256(amount) * 50 / 10000 : minimum * 50 / 10000) : 0;
            if (app && !buy) minimum -= minimum * 50 / 10000;
            if (outputFeeOn) minimum = minimum * 10_000 / 10_005; // room for the 5 bps protocol fee
            assertGt(minimum, 0, "meaningful quote");
        }
        if (action == 3) minimum = type(uint128).max;
        SignedOrder memory signed = _order(input, output, amount, minimum, nonce);
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
            try filler.fill(signed, m.key) {
                fail("invalid order succeeded");
            } catch {
                expectedFailures++;
            }
            assertEq(IERC20(input).balanceOf(trader), beforeInput, "failed fill spent input");
            assertEq(IERC20(output).balanceOf(trader), beforeOutput, "failed fill changed output");
            assertEq(IERC20(USDC).balanceOf(appRecipient), beforeFee, "failed fill charged fee");
            assertEq(
                XPermit2(address(permit2)).nonceBitmap(trader, nonce >> 8), beforeBitmap, "failed fill consumed nonce"
            );
        } else {
            filler.fill(signed, m.key);
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
        assertGt(feeFills, 0, "output-fee fills unreachable");
        assertGt(inputFeeRejections, 0, "input-fee rejections unreachable");
        assertGe(steps, 13);
    }
}
