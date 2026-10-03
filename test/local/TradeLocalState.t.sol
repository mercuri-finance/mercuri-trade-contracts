// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {UniswapXFillerHarness} from "../integration/UniswapXFiller.t.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SignedOrder, OrderInfo} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {
    V3DutchOrder,
    V3DutchOrderLib,
    V3DutchInput,
    V3DutchOutput,
    NonlinearDutchDecay,
    CosignerData
} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Offline state export for the Go/Anvil late-cosigning test. Never broadcast. Four trader-signed, uncosigned
///      limit orders (buy and sell on a Launch pool and on a listed, hookless pool) carry the single-point expiry curve
///      and name the filler's validator with the signed condition (spec D22: version 1, limit, the order's pool, no
///      trigger), exactly as the web app submits them. The backend keeper cosigns them at fill time with Anvil's second
///      development key. The export holds the reactor, the filler and the validator the filler deployed.
///      For the pool stop capacity (spec §10 amendments, D30) it also names the Launch system the capacity reader
///      reads: the LiquidityLocker holding the Launch market's graduation position, the GraduationManager proxy
///      and its implementation, the PositionManager and the FeeManager. A decoy pool for the same Launch token
///      (the Launch hook, another tick spacing, initialised as the GraduationManager, with liquidity of its own)
///      is the pool an order could be pinned to while the locked position is another pool's: the reader must
///      refuse it (key mismatch). Its pool id sorts below the real pool's.
contract TradeLocalStateTest is UniswapXFillerHarness {
    using V3DutchOrderLib for V3DutchOrder;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// Anvil development account 1; the Go test signs with its public dev key.
    address internal constant LOCAL_COSIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    string internal constant KEY = "anvil";

    function setUp() public override {
        if (!vm.envOr("TRADE_EXPORT_STATE", false)) vm.skip(true);
    }

    function test_exportState() external {
        // dumpState exports accounts touched in this invocation. Deploy here
        // so constructor storage and untouched reactor/router code are included.
        super.setUp();
        vm.warp(1800000000);
        // Markets are built while USDC is the native shim, as on Arc.
        Market memory launch = _market(true, true);
        Market memory listed = _market(false, false);
        _serializeMarket("launch", launch);
        _serializeMarket("listed", listed);
        // A fresh Launch pool locks about 18,000 USDC, so its stop capacity (κ · f · Y_lock) is about 36 USDC. A
        // wallet's share is max(25% of it, the 10 USDC order minimum), so the fresh pool admits one minimum-size
        // stop-loss per wallet as it is: no trade is needed first.
        PoolKey memory decoy = _decoyPool(launch);
        vm.serializeUint(KEY, "decoyFee", decoy.fee);
        vm.serializeInt(KEY, "decoyTickSpacing", decoy.tickSpacing);
        _exportOrder("launchBuy", launch, true, 1);
        _exportOrder("launchSell", launch, false, 2);
        _exportOrder("listedBuy", listed, true, 3);
        _exportOrder("listedSell", listed, false, 4);
        // Anvil has neither Arc's native USDC precompile nor cheatcodes, so the
        // shim cannot run there. Replace it with a plain ERC-20 holding the same
        // balances for every account that moves USDC in these fills.
        address[3] memory holders = [address(poolManager), trader, appRecipient];
        uint256[3] memory balances;
        for (uint256 i; i < holders.length; ++i) {
            balances[i] = holders[i].balance / 1e12;
        }
        vm.etch(USDC, address(new MockERC20("USDC", "USDC", 6)).code);
        for (uint256 i; i < holders.length; ++i) {
            MockERC20(USDC).mint(holders[i], balances[i]);
        }
        vm.prank(trader);
        MockERC20(USDC).approve(address(permit2), type(uint256).max);
        // FeeManager checks its native balance backs every hook fee; ERC-20 USDC
        // moved by the pool no longer touches native balance, so pre-fund it.
        vm.deal(address(feeManager), address(feeManager).balance + 1_000_000e18);
        vm.serializeAddress(KEY, "reactor", address(reactor));
        vm.serializeAddress(KEY, "permit2", address(permit2));
        vm.serializeAddress(KEY, "filler", address(filler));
        vm.serializeAddress(KEY, "validator", address(filler.validator()));
        vm.serializeAddress(KEY, "quoter", address(quoter));
        vm.serializeAddress(KEY, "poolManager", address(poolManager));
        vm.serializeAddress(KEY, "launchHook", address(hook));
        vm.serializeAddress(KEY, "liquidityLocker", address(locker));
        vm.serializeAddress(KEY, "graduationManager", address(gm));
        vm.serializeAddress(
            KEY, "graduationManagerImpl", address(uint160(uint256(vm.load(address(gm), IMPLEMENTATION_SLOT))))
        );
        vm.serializeAddress(KEY, "positionManager", address(posm));
        vm.serializeAddress(KEY, "feeManager", address(feeManager));
        vm.serializeAddress(KEY, "cosigner", LOCAL_COSIGNER);
        vm.serializeAddress(KEY, "trader", trader);
        vm.serializeAddress(KEY, "feeRecipient", feeRecipient);
        vm.serializeUint(KEY, "executionFee", filler.executionFee());
        string memory output = vm.serializeAddress(KEY, "usdc", USDC);
        vm.createDir("test-export/trade-orders", true);
        vm.writeJson(output, "test-export/trade-orders/anvil-order.json");
        vm.dumpState("test-export/trade-orders/anvil-state.json");
    }

    /// A second pool for the Launch market's token under the Launch hook, at the market's price: only the
    /// GraduationManager may initialise a Launch-hook pool, so it is initialised as the GraduationManager (as an
    /// upgraded one could), and holds about 1,000 USDC of full-range liquidity that no locker holds. The tick
    /// spacing is the first whose pool id sorts below the real pool's, so an order for the token is pinned to it
    /// once the index lists it.
    function _decoyPool(Market memory m) internal returns (PoolKey memory k) {
        bytes32 real = PoolId.unwrap(m.key.toId());
        // A copy, not an alias of m.key.
        k = PoolKey(m.key.currency0, m.key.currency1, m.key.fee, m.key.tickSpacing, m.key.hooks);
        for (int24 ts = 1; ts < 200; ++ts) {
            k.tickSpacing = ts;
            if (ts != m.key.tickSpacing && PoolId.unwrap(k.toId()) < real) break;
        }
        require(PoolId.unwrap(k.toId()) < real, "no decoy spacing");
        (uint160 sqrtP,,,) = poolManager.getSlot0(m.key.toId());
        vm.prank(address(gm));
        poolManager.initialize(k, sqrtP);
        uint256 q96 = 1 << 96;
        uint256 usdcAmount = 1_000e6;
        uint128 liquidity =
            uint128(m.usdcIs0 ? FullMath.mulDiv(usdcAmount, sqrtP, q96) : FullMath.mulDiv(usdcAmount, q96, sqrtP));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
        uint256 held = m.token.balanceOf(bob); // read before the prank, which the next external call consumes
        vm.prank(bob);
        m.token.transfer(address(this), held);
        m.token.approve(address(lp), type(uint256).max);
        IERC20(USDC).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            k,
            ModifyLiquidityParams(
                TickMath.minUsableTick(k.tickSpacing),
                TickMath.maxUsableTick(k.tickSpacing),
                int256(uint256(liquidity)),
                0
            ),
            ""
        );
    }

    function _serializeMarket(string memory name, Market memory m) internal {
        vm.serializeAddress(KEY, string.concat(name, "Token"), address(m.token));
        vm.serializeAddress(KEY, string.concat(name, "Currency0"), Currency.unwrap(m.key.currency0));
        vm.serializeAddress(KEY, string.concat(name, "Currency1"), Currency.unwrap(m.key.currency1));
        vm.serializeAddress(KEY, string.concat(name, "Hooks"), address(m.key.hooks));
        vm.serializeUint(KEY, string.concat(name, "Fee"), m.key.fee);
        vm.serializeInt(KEY, string.concat(name, "TickSpacing"), m.key.tickSpacing);
    }

    /// The signed minimum is half of today's net quote, so the keeper's raised
    /// output (the live net quote less 1%) is visibly above it.
    function _exportOrder(string memory name, Market memory m, bool buy, uint256 nonce) internal {
        bool mercuri = address(m.key.hooks) == address(hook);
        uint128 amount = buy || !mercuri ? 100e6 : 1000000e18;
        uint128 netInput = !mercuri && buy ? amount - amount * 50 / 10000 : amount;
        bytes memory data = mercuri ? abi.encode(uint256(uint160(trader))) : bytes("");
        uint256 gross = _quote(m, buy, netInput, data);
        uint256 net = !mercuri && !buy ? gross - gross * 50 / 10000 : gross;
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        SignedOrder memory signed = _uncosigned(input, output, amount, net / 2, nonce);
        vm.serializeBytes(KEY, string.concat(name, "Order"), signed.order);
        vm.serializeBytes(KEY, string.concat(name, "Signature"), signed.sig);
    }

    function _uncosigned(address input, address output, uint256 amount, uint256 minimum, uint256 nonce)
        internal
        view
        returns (SignedOrder memory)
    {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(output, minimum, _expiryCurve(), trader, minimum, 0);
        V3DutchOrder memory order;
        order.info = OrderInfo(
            IReactor(address(reactor)),
            trader,
            nonce,
            block.timestamp + 1 days,
            filler.validator(),
            _limitData(input, output) // the signed condition: a limit order on this market's pool
        );
        order.cosigner = LOCAL_COSIGNER;
        order.startingBaseFee = 0;
        order.baseInput = V3DutchInput(XERC20(input), amount, flat, amount, 0);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(0, address(0), 0, 0, new uint256[](1));
        bytes32 h = order.hash();
        return SignedOrder(abi.encode(order), _traderSig(input, amount, nonce, order.info.deadline, h));
    }
}
