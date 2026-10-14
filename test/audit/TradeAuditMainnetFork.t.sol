// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Audit of 13 Oct 2026 (uncommitted). Exercises the DEPLOYED Arc mainnet reactor, filler and validator on a read-only
// Foundry fork: no transaction is sent. Skips unless ARC_AUDIT_FORK_RPC is set. Arc's USDC precompile is modelled by
// the repository's NativeUsdcShim, as in the other fork suites; everything else is fork code.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {OrderInfo, SignedOrder, ResolvedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {
    V3DutchOrder,
    V3DutchOrderLib,
    V3DutchInput,
    V3DutchOutput,
    NonlinearDutchDecay,
    CosignerData
} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {MercuriOrderValidator} from "../../src/MercuriOrderValidator.sol";
import {NativeUsdcShim} from "../utils/NativeUsdcShim.sol";

contract AuditToken is ERC20 {
    constructor(address a, address b) ERC20("Audit token", "AUD") {
        _mint(a, 1e30);
        _mint(b, 1e30);
    }
}

contract TradeAuditMainnetForkTest is Test {
    using V3DutchOrderLib for V3DutchOrder;

    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    MercuriOrderFiller internal constant FILLER = MercuriOrderFiller(payable(0x947b55E2865787dBe4c3230FF2c927dfBeDFE40D));
    address internal constant VALIDATOR = 0x5921BaE3dCA7e89FC2004374030FC5e04cA074B4;
    address internal constant REACTOR = 0x4EDF1E62ebD1237122677D35F0d4868023FbeEb1;
    address internal constant KEEPER = 0x224d6A194CD27e1a9e84ebe2A35Ad6eC81361eF0;
    address internal constant APP = 0x34E3321e97BBa4F5c7A0aCc6b09C50bE9173912D;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    uint256 internal constant TRADER_KEY = 0xA11CE;
    uint256 internal constant COSIGNER_KEY = 0xC051;

    address internal trader;
    AuditToken internal token;
    PoolKey internal key;
    bool internal usdcIs0;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_AUDIT_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, vm.envOr("ARC_AUDIT_FORK_BLOCK", uint256(25781881)));
        assertEq(block.chainid, 5042);
        vm.etch(USDC, address(new NativeUsdcShim()).code);
        vm.allowCheatcodes(USDC);
        trader = vm.addr(TRADER_KEY);
        token = new AuditToken(address(this), trader);
        usdcIs0 = USDC < address(token);
        key = PoolKey(
            Currency.wrap(usdcIs0 ? USDC : address(token)),
            Currency.wrap(usdcIs0 ? address(token) : USDC),
            3000,
            60,
            IHooks(address(0))
        );
        PM.initialize(key, uint160(1 << 96));
        vm.deal(address(this), 1_000_000e18);
        vm.deal(trader, 1_000_000e18);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        token.approve(address(lp), type(uint256).max);
        IERC20(USDC).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 1e11, bytes32(0)), "");
        vm.startPrank(trader);
        token.approve(address(PERMIT2), type(uint256).max);
        IERC20(USDC).approve(address(PERMIT2), type(uint256).max);
        vm.stopPrank();
    }

    function _net(bool buy, uint256 amount) internal returns (uint256) {
        uint256 fee = FILLER.executionFee();
        uint256 swapIn = buy ? amount - amount * 50 / 10000 - fee : amount;
        (uint256 gross,) =
            QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, buy == usdcIs0, uint128(swapIn), ""));
        if (buy) return gross;
        return gross - gross * 50 / 10000 - fee;
    }

    function _order(address input, address output, uint256 amount, uint256 minimum, uint256 nonce)
        internal
        view
        returns (SignedOrder memory)
    {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(output, minimum, flat, trader, minimum, 0);
        V3DutchOrder memory order;
        order.info = OrderInfo(
            IReactor(REACTOR),
            trader,
            nonce,
            block.timestamp + 1 hours,
            IValidationCallback(VALIDATOR),
            abi.encode(uint8(1), uint8(0), keccak256(abi.encode(key)), uint160(0))
        );
        order.cosigner = vm.addr(COSIGNER_KEY);
        order.startingBaseFee = block.basefee;
        order.baseInput = V3DutchInput(XERC20(input), amount, flat, amount, 0);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(block.number, FILLER_ADDR(), 0, 0, new uint256[](1));
        bytes32 h = order.hash();
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_KEY, order.cosignerDigest(h));
        order.cosignature = abi.encodePacked(cr, cs, cv);
        return SignedOrder(abi.encode(order), _traderSig(input, amount, nonce, order.info.deadline, h));
    }

    function FILLER_ADDR() internal pure returns (address) {
        return address(FILLER);
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
                PERMIT2.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typeHash, permissions, REACTOR, nonce, deadline, h))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRADER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The deployed pair fills a listed-pool buy and sell exactly as the build does: trader gets at least the signed
    /// net, the keeper exactly 0.05 USDC, the treasury the app fee, and the filler keeps nothing and no approval.
    function test_auditFork_deployedFillerBuyAndSell() public {
        uint256 fillerUsdc = IERC20(USDC).balanceOf(address(FILLER));
        for (uint256 side; side < 2; ++side) {
            bool buy = side == 0;
            address input = buy ? USDC : address(token);
            address output = buy ? address(token) : USDC;
            uint256 amount = 100e6;
            uint256 net = _net(buy, amount);
            SignedOrder memory signed = _order(input, output, amount, net, 77 + side);
            uint256 outBefore = IERC20(output).balanceOf(trader);
            uint256 keeperBefore = IERC20(USDC).balanceOf(KEEPER);
            uint256 appBefore = IERC20(USDC).balanceOf(APP);
            vm.prank(KEEPER);
            FILLER.fill(signed, key);
            assertGe(IERC20(output).balanceOf(trader) - outBefore, net, "trader net");
            assertEq(IERC20(USDC).balanceOf(KEEPER) - keeperBefore, 50_000, "execution fee");
            assertGt(IERC20(USDC).balanceOf(APP) - appBefore, 0, "app fee");
            assertEq(IERC20(USDC).balanceOf(address(FILLER)), fillerUsdc, "filler USDC changed");
            assertEq(token.balanceOf(address(FILLER)), 0, "filler token");
            assertEq(IERC20(input).allowance(address(FILLER), address(PERMIT2)), 0);
            assertEq(IERC20(output).allowance(address(FILLER), REACTOR), 0);
            vm.prank(KEEPER);
            vm.expectRevert(MercuriOrderFiller.NonceUsed.selector);
            FILLER.fill(signed, key);
        }
    }

    /// Access on the deployed bytecode: a stranger cannot fill, the callback refuses everyone outside a fill, and a
    /// pool other than the signed one is refused after the validator ran.
    function test_auditFork_deployedFillerAccess() public {
        SignedOrder memory signed = _order(USDC, address(token), 100e6, _net(true, 100e6), 90);
        vm.expectRevert(MercuriOrderFiller.NotKeeper.selector);
        FILLER.fill(signed, key);
        vm.prank(REACTOR);
        vm.expectRevert(MercuriOrderFiller.ForbiddenCallback.selector);
        FILLER.reactorCallback(new ResolvedOrder[](1), "");
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10;
        PM.initialize(other, uint160(1 << 96));
        vm.prank(KEEPER);
        vm.expectRevert(MercuriOrderFiller.PoolNotSigned.selector);
        FILLER.fill(signed, other);
        assertEq(MercuriOrderValidator(VALIDATOR).filler(), address(FILLER));
    }
}
