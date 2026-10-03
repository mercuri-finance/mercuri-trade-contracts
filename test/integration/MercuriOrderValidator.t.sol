// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ResolvedOrder, OrderInfo, InputToken, OutputToken} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {MercuriOrderValidator} from "../../src/MercuriOrderValidator.sol";

/// @notice Every branch of `MercuriOrderValidator.validate` against a real v4 PoolManager: filler binding, condition
///         decoding and, for take-profit and stop-loss, the trigger direction for each kind x side x USDC position at,
///         before and after the trigger. The expected outcome is derived independently of the contract, from the
///         token's USDC price (see `_expected`).
contract MercuriOrderValidatorTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    /// A token address below USDC (USDC is then currency1) and one above it (USDC is then currency0).
    address internal constant TOKEN_BELOW = 0x1000000000000000000000000000000000000001;
    address internal constant TOKEN_ABOVE = 0xF000000000000000000000000000000000000001;
    address internal constant FILLER = address(0xF111);
    uint8 internal constant LIMIT = 0;
    uint8 internal constant TAKE_PROFIT = 1;
    uint8 internal constant STOP_LOSS = 2;

    IPoolManager internal manager;
    MercuriOrderValidator internal validator;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        validator = new MercuriOrderValidator(FILLER, manager);
    }

    function _key(address token, int24 tickSpacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = token < USDC ? (token, USDC) : (USDC, token);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, tickSpacing, IHooks(address(0)));
    }

    function _pool(address token, uint160 price, int24 tickSpacing) internal returns (bytes32) {
        PoolKey memory key = _key(token, tickSpacing);
        manager.initialize(key, price);
        return keccak256(abi.encode(key));
    }

    function _data(uint8 kind, bytes32 pool, uint160 trigger) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), kind, pool, trigger);
    }

    function _order(address input, address output, bytes memory data) internal view returns (ResolvedOrder memory o) {
        o.info = OrderInfo(IReactor(address(0xBEEF)), address(0xCAFE), 1, block.timestamp + 1, validator, data);
        o.input = InputToken(XERC20(input), 100, 100);
        o.outputs = new OutputToken[](1);
        o.outputs[0] = OutputToken(output, 50, address(0xCAFE));
    }

    function _validate(ResolvedOrder memory o) external view {
        validator.validate(FILLER, o);
    }

    /// Independent oracle. The token's USDC price rises with the pool price exactly when USDC is currency1. A sell's
    /// take-profit wants the token price at or above the trigger and its stop-loss at or below; a buy's take-profit
    /// (its rate, tokens per USDC, risen) wants the token price at or below and its stop-loss at or above.
    function _expected(bool usdcIs1, bool buy, uint8 kind, uint160 price, uint160 trigger)
        internal
        pure
        returns (bool)
    {
        bool wantTokenPriceUp = (kind == TAKE_PROFIT) != buy;
        bool tokenPriceUpMeansPriceUp = usdcIs1;
        bool wantPriceUp = wantTokenPriceUp == tokenPriceUpMeansPriceUp;
        return wantPriceUp ? price >= trigger : price <= trigger;
    }

    /// 2 kinds x 2 sides x 2 USDC positions x (before, at, after the trigger) = 24 cases, each checked against the
    /// oracle; every orientation has both a refused and an accepted case.
    function test_triggerDirectionTable() public {
        uint160 price = uint160(1 << 96) * 3 / 2;
        bytes32[2] memory pools = [_pool(TOKEN_BELOW, price, 60), _pool(TOKEN_ABOVE, price, 60)];
        uint256 accepted;
        uint256 refused;
        for (uint256 u; u < 2; ++u) {
            address token = u == 0 ? TOKEN_BELOW : TOKEN_ABOVE;
            bool usdcIs1 = token < USDC;
            for (uint256 side; side < 2; ++side) {
                bool buy = side == 1;
                (address input, address output) = buy ? (USDC, token) : (token, USDC);
                for (uint8 kind = TAKE_PROFIT; kind <= STOP_LOSS; ++kind) {
                    uint160[3] memory triggers = [price - 1, price, price + 1];
                    uint256 orientationAccepted;
                    for (uint256 t; t < 3; ++t) {
                        ResolvedOrder memory o = _order(input, output, _data(kind, pools[u], triggers[t]));
                        bool ok = _expected(usdcIs1, buy, kind, price, triggers[t]);
                        if (!ok) vm.expectRevert(MercuriOrderValidator.TriggerNotReached.selector);
                        this._validate(o);
                        if (ok) {
                            ++accepted;
                            ++orientationAccepted;
                        } else {
                            ++refused;
                        }
                    }
                    // At the trigger always passes; exactly one of the two neighbours does.
                    assertEq(orientationAccepted, 2, "inclusive trigger, one side only");
                }
            }
        }
        assertEq(accepted, 16);
        assertEq(refused, 8);
    }

    /// The same direction rule over any pool price and trigger.
    function testFuzz_triggerDirectionMatchesOracle(uint160 priceSeed, uint160 triggerSeed, uint8 caseSeed) public {
        uint160 price = uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 trigger = uint160(bound(triggerSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        if (caseSeed & 8 != 0) trigger = price; // land on the boundary often
        address token = caseSeed & 1 == 0 ? TOKEN_BELOW : TOKEN_ABOVE;
        bool buy = caseSeed & 2 != 0;
        uint8 kind = caseSeed & 4 == 0 ? TAKE_PROFIT : STOP_LOSS;
        bytes32 pool = _pool(token, price, 60);
        (address input, address output) = buy ? (USDC, token) : (token, USDC);
        ResolvedOrder memory o = _order(input, output, _data(kind, pool, trigger));
        if (!_expected(token < USDC, buy, kind, price, trigger)) {
            vm.expectRevert(MercuriOrderValidator.TriggerNotReached.selector);
        }
        this._validate(o);
    }

    /// A real price move: a sell's stop-loss on a pool where the token's price falls through the trigger.
    function test_stopLossFiresOnlyAfterPriceFalls() public {
        uint160 trigger = uint160(1 << 96);
        bytes32 pool = _pool(TOKEN_BELOW, trigger + 1, 60); // USDC is currency1: token price = pool price
        ResolvedOrder memory o = _order(TOKEN_BELOW, USDC, _data(STOP_LOSS, pool, trigger));
        vm.expectRevert(MercuriOrderValidator.TriggerNotReached.selector);
        this._validate(o);
        bytes32 lower = _pool(TOKEN_BELOW, trigger, 10); // same pair, another pool, at the trigger
        this._validate(_order(TOKEN_BELOW, USDC, _data(STOP_LOSS, lower, trigger)));
    }

    function test_wrongFillerRefused() public {
        ResolvedOrder memory o = _order(USDC, TOKEN_BELOW, _data(LIMIT, bytes32(0), 0));
        vm.expectRevert(MercuriOrderValidator.WrongFiller.selector);
        validator.validate(address(0xBAD), o);
        vm.expectRevert(MercuriOrderValidator.WrongFiller.selector);
        validator.validate(address(0), o);
        validator.validate(FILLER, o);
    }

    /// A limit is never price-checked: it passes on a pool that does not even exist; its trigger must be zero.
    function test_limitNeedsNoPrice() public {
        this._validate(_order(USDC, TOKEN_BELOW, _data(LIMIT, keccak256("no such pool"), 0)));
        this._validate(_order(TOKEN_ABOVE, USDC, _data(LIMIT, bytes32(0), 0)));
        ResolvedOrder memory o = _order(USDC, TOKEN_BELOW, _data(LIMIT, bytes32(0), 1));
        vm.expectRevert(MercuriOrderValidator.InvalidTrigger.selector);
        this._validate(o);
    }

    function test_triggerOutsideV4RangeRefused() public {
        bytes32 pool = _pool(TOKEN_BELOW, uint160(1 << 96), 60);
        uint160[4] memory bad = [uint160(0), TickMath.MIN_SQRT_PRICE - 1, TickMath.MAX_SQRT_PRICE, type(uint160).max];
        for (uint256 i; i < bad.length; ++i) {
            for (uint8 kind = TAKE_PROFIT; kind <= STOP_LOSS; ++kind) {
                ResolvedOrder memory o = _order(TOKEN_BELOW, USDC, _data(kind, pool, bad[i]));
                vm.expectRevert(MercuriOrderValidator.InvalidTrigger.selector);
                this._validate(o);
            }
        }
        // The range's own ends are accepted as triggers (each is reached from one side).
        this._validate(_order(TOKEN_BELOW, USDC, _data(TAKE_PROFIT, pool, TickMath.MIN_SQRT_PRICE)));
        this._validate(_order(TOKEN_BELOW, USDC, _data(STOP_LOSS, pool, TickMath.MAX_SQRT_PRICE - 1)));
    }

    function test_uninitializedPoolRefused() public {
        for (uint8 kind = TAKE_PROFIT; kind <= STOP_LOSS; ++kind) {
            ResolvedOrder memory o = _order(TOKEN_BELOW, USDC, _data(kind, keccak256("no such pool"), 1 << 96));
            vm.expectRevert(MercuriOrderValidator.PoolNotInitialized.selector);
            this._validate(o);
        }
    }

    /// Unknown versions and kinds, wrong lengths, dirty words and a trigger wider than 160 bits are typed refusals.
    function test_malformedConditionRefused() public {
        bytes32 pool = _pool(TOKEN_BELOW, uint160(1 << 96), 60);
        bytes[13] memory data = [
            bytes(""),
            abi.encode(uint8(1), uint256(2e18)), // the superseded D11 encoding
            abi.encodePacked(_data(LIMIT, pool, 0), uint8(0)), // 129 bytes
            _slice(_data(LIMIT, pool, 0), 127),
            abi.encode(uint8(0), LIMIT, pool, uint160(0)), // version 0
            abi.encode(uint8(2), LIMIT, pool, uint160(0)), // version 2
            abi.encode(uint256(257), LIMIT, pool, uint160(0)), // version with dirty high bits
            abi.encode(uint8(1), uint8(3), pool, uint160(0)), // kind 3
            abi.encode(uint8(1), uint8(255), pool, uint160(0)),
            abi.encode(uint8(1), uint256(256 + 1), pool, uint160(1 << 96)), // kind with dirty high bits
            abi.encode(uint8(1), TAKE_PROFIT, pool, uint256(type(uint160).max) + 1), // trigger wider than 160 bits
            abi.encode(uint8(1), LIMIT, pool, uint256(1) << 160),
            new bytes(128) // version 0, all zero
        ];
        bytes4[13] memory errors = [
            MercuriOrderValidator.InvalidValidationData.selector,
            MercuriOrderValidator.InvalidValidationData.selector,
            MercuriOrderValidator.InvalidValidationData.selector,
            MercuriOrderValidator.InvalidValidationData.selector,
            MercuriOrderValidator.UnsupportedVersion.selector,
            MercuriOrderValidator.UnsupportedVersion.selector,
            MercuriOrderValidator.UnsupportedVersion.selector,
            MercuriOrderValidator.UnknownKind.selector,
            MercuriOrderValidator.UnknownKind.selector,
            MercuriOrderValidator.UnknownKind.selector,
            MercuriOrderValidator.InvalidValidationData.selector,
            MercuriOrderValidator.InvalidValidationData.selector,
            MercuriOrderValidator.UnsupportedVersion.selector
        ];
        for (uint256 i; i < data.length; ++i) {
            ResolvedOrder memory o = _order(TOKEN_BELOW, USDC, data[i]);
            vm.expectRevert(errors[i]);
            this._validate(o);
        }
    }

    function testFuzz_arbitraryDataNeverPanics(bytes memory data) public {
        ResolvedOrder memory o = _order(TOKEN_BELOW, USDC, data);
        try this._validate(o) {
            // Only a well-formed limit can pass without a pool.
            assertEq(data.length, 128);
            (uint256 version, uint256 kind,, uint256 trigger) = abi.decode(data, (uint256, uint256, bytes32, uint256));
            assertEq(version, 1);
            assertEq(kind, LIMIT);
            assertEq(trigger, 0);
        } catch (bytes memory err) {
            bytes4 s = bytes4(err);
            assertTrue(
                s == MercuriOrderValidator.InvalidValidationData.selector
                    || s == MercuriOrderValidator.UnsupportedVersion.selector
                    || s == MercuriOrderValidator.UnknownKind.selector
                    || s == MercuriOrderValidator.InvalidTrigger.selector
                    || s == MercuriOrderValidator.PoolNotInitialized.selector,
                "untyped refusal"
            );
        }
    }

    function test_constructorAndGetters() public {
        assertEq(validator.filler(), FILLER);
        assertEq(address(validator.poolManager()), address(manager));
        assertEq(validator.VERSION(), 1);
        assertEq(validator.KIND_LIMIT(), 0);
        assertEq(validator.KIND_TAKE_PROFIT(), 1);
        assertEq(validator.KIND_STOP_LOSS(), 2);
        vm.expectRevert(MercuriOrderValidator.ZeroAddress.selector);
        new MercuriOrderValidator(address(0), manager);
        vm.expectRevert(MercuriOrderValidator.ZeroAddress.selector);
        new MercuriOrderValidator(FILLER, IPoolManager(address(0)));
    }

    function _slice(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
    }
}
