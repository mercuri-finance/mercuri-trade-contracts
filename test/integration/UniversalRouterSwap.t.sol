// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Vm} from "forge-std/Vm.sol";

interface ICanonicalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract UniversalRouterSwapTest is LaunchFixture {
    ICanonicalRouter internal router;
    IV4Quoter internal quoter;
    address internal trader = makeAddr("router trader");
    address internal appRecipient = makeAddr("app fee recipient");

    struct RouterParameters {
        address permit2;
        address weth9;
        address v2Factory;
        address v3Factory;
        bytes32 pairInitCodeHash;
        bytes32 poolInitCodeHash;
        address v4PoolManager;
        address v3NFTPositionManager;
        address v4PositionManager;
        address spokePool;
    }

    struct Market {
        LaunchToken token;
        PoolKey key;
        bool usdcIs0;
    }

    function setUp() public virtual {
        _deploySystem();
        _configureRouter();
        vm.deal(trader, 100_000e18);
        vm.deal(address(this), 100_000e18);
    }

    function _configureRouter() internal virtual {
        RouterParameters memory params;
        params.permit2 = address(permit2);
        params.v4PoolManager = address(poolManager);
        params.v4PositionManager = address(posm);
        router = ICanonicalRouter(
            deployCode("out/trade-router/UniversalRouter.sol/UniversalRouter.json", abi.encode(params))
        );
        quoter = new V4Quoter(poolManager);
    }

    function _market(bool below, bool mercuri) internal returns (Market memory m) {
        BondingCurve curve;
        (m.token, curve) = _createOrdered(below);
        _graduate(curve);
        m.key = _key(address(m.token));
        m.usdcIs0 = Currency.unwrap(m.key.currency0) == USDC;
        vm.prank(bob);
        m.token.transfer(trader, 10_000_000e18);
        if (!mercuri) {
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
        }
        vm.startPrank(trader);
        m.token.approve(address(permit2), type(uint256).max);
        IERC20(USDC).approve(address(permit2), type(uint256).max);
        permit2.approve(address(m.token), address(router), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _quote(Market memory m, bool buy, uint128 amount, bytes memory hookData) internal returns (uint256 out) {
        (out,) =
            quoter.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(m.key, buy == m.usdcIs0, amount, hookData));
    }

    function _swapInput(
        Market memory m,
        bool buy,
        uint128 amount,
        uint128 minimum,
        bytes memory hookData,
        bool toRouter
    ) internal pure returns (bytes memory) {
        Currency input = buy ? Currency.wrap(USDC) : Currency.wrap(address(m.token));
        Currency output = buy ? Currency.wrap(address(m.token)) : Currency.wrap(USDC);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(m.key, buy == m.usdcIs0, amount, minimum, 0, hookData));
        params[1] = abi.encode(input, uint256(amount));
        // TAKE maps address(2) to the router; TAKE_ALL always pays the initiating trader.
        params[2] = toRouter ? abi.encode(output, address(2), uint256(0)) : abi.encode(output, uint256(minimum));
        return abi.encode(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                toRouter ? uint8(Actions.TAKE) : uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function _recipe(Market memory m, bool buy, uint128 amount, uint128 minimum, bytes memory hookData)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bool appFee = address(m.key.hooks) != address(hook);
        if (!appFee) {
            commands = hex"10";
            inputs = new bytes[](1);
            inputs[0] = _swapInput(m, buy, amount, minimum, hookData, false);
        } else if (buy) {
            uint128 fee = amount * 50 / 10_000;
            commands = hex"0210";
            inputs = new bytes[](2);
            inputs[0] = abi.encode(USDC, appRecipient, uint160(fee));
            inputs[1] = _swapInput(m, buy, amount - fee, minimum, "", false);
        } else {
            commands = hex"100604";
            inputs = new bytes[](3);
            inputs[0] = _swapInput(m, buy, amount, 0, "", true);
            inputs[1] = abi.encode(USDC, appRecipient, uint256(50));
            // The user's minimum is on net proceeds, after the app fee.
            inputs[2] = abi.encode(USDC, trader, uint256(minimum));
        }
    }

    function _execute(Market memory m, bool buy, uint128 amount, uint128 minimum, bytes memory hookData) internal {
        (bytes memory commands, bytes[] memory inputs) = _recipe(m, buy, amount, minimum, hookData);
        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp + 60);
    }

    function test_exportAppFeeReceipts() public {
        vm.createDir("test-export/trade-router", true);
        for (uint256 side; side < 2; ++side) {
            Market memory m = _market(side == 0, false);
            bool buy = side == 0;
            (bytes memory commands, bytes[] memory inputs) = _recipe(m, buy, 100e6, 0, "");
            bytes memory callData = abi.encodeCall(ICanonicalRouter.execute, (commands, inputs, block.timestamp + 60));
            vm.recordLogs();
            vm.prank(trader);
            router.execute(commands, inputs, block.timestamp + 60);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            string memory raw = "[";
            for (uint256 i; i < logs.length; ++i) {
                string memory object = string.concat("log", vm.toString(i));
                vm.serializeAddress(object, "address", logs[i].emitter);
                vm.serializeBytes32(object, "topics", logs[i].topics);
                string memory item = vm.serializeBytes(object, "data", logs[i].data);
                raw = string.concat(raw, i == 0 ? "" : ",", item);
            }
            raw = string.concat(raw, "]");
            string memory key = buy ? "buy" : "sell";
            vm.serializeAddress(key, "router", address(router));
            vm.serializeAddress(key, "poolManager", address(poolManager));
            vm.serializeAddress(key, "usdc", USDC);
            vm.serializeAddress(key, "recipient", appRecipient);
            vm.serializeAddress(key, "trader", trader);
            vm.serializeAddress(key, "currency0", Currency.unwrap(m.key.currency0));
            vm.serializeAddress(key, "currency1", Currency.unwrap(m.key.currency1));
            vm.serializeBytes(key, "input", callData);
            string memory result = vm.serializeString(key, "logs", raw);
            vm.writeJson(result, string.concat("test-export/trade-router/", key, ".json"));
        }
    }

    function _assertEmpty(Market memory m) internal view {
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(m.token.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    function test_R1MercuriBuyBothOrderings() public {
        vm.prank(trader);
        feeManager.bindReferrer(referrer);
        for (uint256 i; i < 2; ++i) {
            Market memory m = _market(i == 0, true);
            bytes memory data = abi.encode(uint256(uint160(trader)));
            uint128 input = 100e6;
            uint256 quoted = _quote(m, true, input, data);
            uint256 beforeToken = m.token.balanceOf(trader);
            uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
            uint256 beforeCreator = feeManager.balances(creator);
            uint256 beforeReferrer = feeManager.balances(referrer);
            uint256 beforePlatform = feeManager.platformBalance();
            _execute(m, true, input, uint128(quoted), data);
            uint256 feeWei = uint256(input) * 100 / 10_000 * 1e12;
            assertEq(m.token.balanceOf(trader) - beforeToken, quoted);
            assertEq(beforeUsdc - IERC20(USDC).balanceOf(trader), input);
            assertEq(feeManager.balances(creator) - beforeCreator, feeWei * cfg.creatorShareBps / 10_000);
            assertEq(feeManager.balances(referrer) - beforeReferrer, feeWei * cfg.referrerShareBps / 10_000);
            assertEq(
                feeManager.platformBalance() - beforePlatform,
                feeWei - feeWei * cfg.creatorShareBps / 10_000 - feeWei * cfg.referrerShareBps / 10_000
            );
            assertEq(appRecipient.balance, 0);
            _assertEmpty(m);
        }
    }

    function test_R2MercuriSellBothOrderings() public {
        for (uint256 i; i < 2; ++i) {
            Market memory m = _market(i == 0, true);
            bytes memory data = abi.encode(uint256(uint160(trader)));
            uint128 input = 1_000_000e18;
            uint256 quoted = _quote(m, false, input, data);
            uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
            uint256 beforeToken = m.token.balanceOf(trader);
            _execute(m, false, input, uint128(quoted), data);
            assertEq(IERC20(USDC).balanceOf(trader) - beforeUsdc, quoted);
            assertEq(beforeToken - m.token.balanceOf(trader), input);
            assertEq(appRecipient.balance, 0);
            _assertEmpty(m);
        }
    }

    function test_R3OtherPoolBuyFeeAndNoDust() public {
        Market memory m = _market(true, false);
        uint128 input = 100e6;
        uint256 quoted = _quote(m, true, input - input * 50 / 10_000, "");
        uint256 beforeToken = m.token.balanceOf(trader);
        uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
        _execute(m, true, input, uint128(quoted), "");
        assertEq(m.token.balanceOf(trader) - beforeToken, quoted);
        assertEq(beforeUsdc - IERC20(USDC).balanceOf(trader), input);
        assertEq(IERC20(USDC).balanceOf(appRecipient), input * 50 / 10_000);
        _assertEmpty(m);
    }

    function test_R4OtherPoolSellFeeAndNoDust() public {
        Market memory m = _market(false, false);
        uint128 input = 100e6;
        uint256 gross = _quote(m, false, input, "");
        uint256 fee = gross * 50 / 10_000;
        uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
        _execute(m, false, input, uint128(gross - fee), "");
        assertEq(IERC20(USDC).balanceOf(trader) - beforeUsdc, gross - fee);
        assertEq(IERC20(USDC).balanceOf(appRecipient), fee);
        _assertEmpty(m);
    }

    function test_slippageRevertsFeeTransferBuyAndSell() public {
        Market memory m = _market(true, false);
        for (uint256 i; i < 2; ++i) {
            uint256 beforeUsdc = IERC20(USDC).balanceOf(trader);
            uint256 beforeToken = m.token.balanceOf(trader);
            (bytes memory commands, bytes[] memory inputs) = _recipe(m, i == 0, 100e6, type(uint128).max, "");
            vm.expectRevert();
            vm.prank(trader);
            router.execute(commands, inputs, block.timestamp + 60);
            assertEq(IERC20(USDC).balanceOf(trader), beforeUsdc);
            assertEq(m.token.balanceOf(trader), beforeToken);
            assertEq(appRecipient.balance, 0);
            _assertEmpty(m);
        }
    }

    function test_expiredDeadlineAndPermit2AllowanceRevert() public {
        Market memory m = _market(true, true);
        (bytes memory commands, bytes[] memory inputs) = _recipe(m, true, 100e6, 0, "");
        vm.expectRevert();
        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp - 1);
        vm.prank(trader);
        permit2.approve(USDC, address(router), type(uint160).max, uint48(block.timestamp));
        vm.warp(block.timestamp + 1);
        vm.expectRevert();
        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp + 60);
        _assertEmpty(m);
    }

    function test_invalidHookDataStillSwapsWithoutReferral() public {
        Market memory m = _market(true, true);
        vm.prank(trader);
        feeManager.bindReferrer(referrer);
        bytes[] memory invalid = new bytes[](4);
        invalid[0] = "";
        invalid[1] = hex"01";
        invalid[2] = new bytes(64);
        invalid[3] = abi.encode(uint256(1) << 160 | uint256(uint160(trader)));
        for (uint256 i; i < invalid.length; ++i) {
            uint256 beforeRef = feeManager.balances(referrer);
            uint256 quote = _quote(m, true, 100e6, invalid[i]);
            _execute(m, true, 100e6, uint128(quote), invalid[i]);
            assertEq(feeManager.balances(referrer), beforeRef);
            _assertEmpty(m);
        }
    }

    function test_missingERC20ApprovalRevertsAtomically() public {
        Market memory m = _market(true, false);
        vm.prank(trader);
        IERC20(USDC).approve(address(permit2), 0);
        (bytes memory commands, bytes[] memory inputs) = _recipe(m, true, 100e6, 0, "");
        uint256 beforeUsdc = trader.balance;
        vm.expectRevert();
        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp + 60);
        assertEq(trader.balance, beforeUsdc);
        assertEq(appRecipient.balance, 0);
        _assertEmpty(m);
    }

    function testFuzz_otherPoolNetOutput(bool buy, bool below, uint128 rawInput) public {
        Market memory m = _market(below, false);
        uint128 input = uint128(bound(rawInput, 10000, 100e6));
        uint128 netInput = buy ? input - input * 50 / 10000 : input;
        uint256 gross = _quote(m, buy, netInput, "");
        uint256 fee = buy ? input * 50 / 10000 : gross * 50 / 10000;
        uint256 net = buy ? gross : gross - fee;
        IERC20 output = buy ? IERC20(address(m.token)) : IERC20(USDC);
        uint256 beforeOutput = output.balanceOf(trader);
        _execute(m, buy, input, uint128(net), "");
        assertEq(output.balanceOf(trader) - beforeOutput, net);
        assertEq(IERC20(USDC).balanceOf(appRecipient), fee);
        _assertEmpty(m);
    }
}
