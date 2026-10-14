// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Audit of 13 Oct 2026 (uncommitted PoC suite). Each test is written to FAIL if the property it names is broken in
// production code; they pass on the deployed source, so they are refutations of the scanner classes, not findings.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {SignedOrder, ResolvedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {MercuriOrderFiller} from "../../src/MercuriOrderFiller.sol";
import {UniswapXFillerHarness} from "../integration/UniswapXFiller.t.sol";
import {HookMiner} from "../utils/launch/HookMiner.sol";

interface IRouterExecute {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev A v4 hook with only BEFORE_SWAP. When armed it runs inside the filler's router call, after the filler has set
///      its ERC-20 approval to Permit2 and its Permit2 allowance to the router and before the router settles: the
///      widest window in which hostile code can run while the filler's approvals are live. It records those live
///      allowances, then tries every way it has to spend them or to re-enter.
contract HostileHook {
    MercuriOrderFiller public immutable filler;
    IAllowanceTransfer public immutable permit2;
    address public immutable router;
    address public immutable usdc;

    address public input;
    bool public armed;
    bool public donateDust;
    uint256 public liveErc20Allowance;
    uint160 public livePermit2Allowance;
    uint256 public attempts;
    uint256 public successes;

    constructor(MercuriOrderFiller filler_, IAllowanceTransfer permit2_, address router_, address usdc_) {
        filler = filler_;
        permit2 = permit2_;
        router = router_;
        usdc = usdc_;
    }

    function arm(address input_, bool donateDust_) external {
        input = input_;
        armed = true;
        donateDust = donateDust_;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (armed) {
            armed = false;
            liveErc20Allowance = IERC20(input).allowance(address(filler), address(permit2));
            (livePermit2Allowance,,) = permit2.allowance(address(filler), input, router);
            uint256 live = livePermit2Allowance;
            // 1. Spend the filler's Permit2 allowance directly (it is granted to the router, not to us).
            _try(
                address(permit2),
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint160,address)", address(filler), address(this), uint160(live), input
                )
            );
            // 2. Spend the filler's ERC-20 approval directly (it is granted to Permit2, not to us).
            _try(input, abi.encodeCall(IERC20.transferFrom, (address(filler), address(this), live)));
            // 3. Drive the router: PERMIT2_TRANSFER_FROM pays from the router's caller, and the router is locked.
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(input, address(this), uint160(live));
            _try(router, abi.encodeCall(IRouterExecute.execute, (hex"02", inputs, block.timestamp)));
            // 4. Sweep whatever the router holds.
            inputs[0] = abi.encode(input, address(this), uint256(0));
            _try(router, abi.encodeCall(IRouterExecute.execute, (hex"04", inputs, block.timestamp)));
            // 5. Call the filler's callback as if it were the reactor.
            _try(address(filler), abi.encodeCall(MercuriOrderFiller.reactorCallback, (new ResolvedOrder[](0), "")));
            // 6. Re-enter the reactor (it is mid-executeWithCallback and nonReentrant).
            _try(
                address(filler.reactor()),
                abi.encodeCall(IReactor.executeWithCallback, (SignedOrder(new bytes(0), new bytes(0)), ""))
            );
            if (donateDust) IERC20(usdc).transfer(address(filler), 1);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _try(address target, bytes memory data) private {
        attempts++;
        (bool ok,) = target.call(data);
        if (ok) successes++;
    }
}

contract TradeAuditLocalTest is UniswapXFillerHarness {
    function _hostileMarket(bool below) internal returns (Market memory m, HostileHook hook_) {
        BondingCurve curve;
        (m.token, curve) = _createOrdered(below);
        _graduate(curve);
        bytes memory args = abi.encode(filler, permit2, address(router), USDC);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), uint160(1 << 7), abi.encodePacked(type(HostileHook).creationCode, args));
        hook_ = new HostileHook{salt: salt}(filler, permit2, address(router), USDC);
        assertEq(address(hook_), predicted);
        m.usdcIs0 = USDC < address(m.token);
        m.key = PoolKey(
            Currency.wrap(m.usdcIs0 ? USDC : address(m.token)),
            Currency.wrap(m.usdcIs0 ? address(m.token) : USDC),
            3000,
            60,
            IHooks(address(hook_))
        );
        poolManager.initialize(m.key, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
        vm.prank(bob);
        m.token.transfer(address(this), 1e18);
        m.token.approve(address(lp), type(uint256).max);
        IERC20(USDC).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(m.key, ModifyLiquidityParams(-887220, 887220, 1e9, bytes32(0)), "");
        vm.prank(bob);
        m.token.transfer(trader, 10_000_000e18);
        vm.startPrank(trader);
        m.token.approve(address(permit2), type(uint256).max);
        IERC20(USDC).approve(address(permit2), type(uint256).max);
        vm.stopPrank();
        marketKey[address(m.token)] = m.key;
    }

    /// SolidityScan "external call risk in critical functions" and "ERC-20 approve race": hostile code running
    /// inside the fill while the filler's approvals are live cannot spend them or re-enter, on a buy and a sell.
    function test_audit_hostileHookCannotSpendLiveApprovals() public {
        for (uint256 side; side < 2; ++side) {
            uint256 snap = vm.snapshotState();
            bool buy = side == 0;
            (Market memory m, HostileHook h) = _hostileMarket(buy);
            address input = buy ? USDC : address(m.token);
            address output = buy ? address(m.token) : USDC;
            uint256 amount = 100e6;
            uint256 net = _netQuote(m, buy, amount, _executionFee());
            SignedOrder memory signed = _order(input, output, amount, net, 900 + side);
            uint256 beforeOut = IERC20(output).balanceOf(trader);
            h.arm(input, false);
            _fill(filler, signed, m.key);
            assertGt(h.livePermit2Allowance(), 0, "window not reached: Permit2 allowance not live");
            assertEq(h.attempts(), 6);
            assertEq(h.successes(), 0, "hostile code spent an approval or re-entered");
            assertGe(IERC20(output).balanceOf(trader) - beforeOut, net, "trader short");
            assertEq(IERC20(input).balanceOf(address(h)), 0);
            assertEq(IERC20(output).balanceOf(address(h)), 0);
            assertEq(IERC20(input).allowance(address(filler), address(permit2)), 0);
            (uint160 left,,) = permit2.allowance(address(filler), input, address(router));
            assertEq(left, 0);
            assertTrue(vm.revertToState(snap));
        }
    }

    /// Info: hostile pool code (hook or token) can send USDC to the filler mid-swap. On a buy that trips the exact
    /// input check and the order reverts with nothing moved: the grief is limited to orders on that hostile pool.
    function test_audit_hostileDustDuringBuyRevertsOnlyThatOrder() public {
        (Market memory m, HostileHook h) = _hostileMarket(true);
        vm.deal(address(h), 1e18);
        uint256 net = _netQuote(m, true, 100e6, _executionFee());
        SignedOrder memory signed = _order(USDC, address(m.token), 100e6, net, 910);
        h.arm(USDC, true);
        uint256 beforeIn = IERC20(USDC).balanceOf(trader);
        vm.expectRevert(MercuriOrderFiller.InputNotConsumed.selector);
        _fill(filler, signed, m.key);
        assertEq(IERC20(USDC).balanceOf(trader), beforeIn, "trader input moved");
        // A clean pool still fills through the same filler.
        Market memory clean = _market(true, false);
        uint256 net2 = _netQuote(clean, true, 100e6, _executionFee());
        _fill(filler, _order(USDC, address(clean.token), 100e6, net2, 911), clean.key);
    }

    /// forge-lint "incorrect-shift" at MercuriOrderFiller.sol:327 is a false positive: the guard reads the same
    /// Permit2 word and bit as Permit2 at the first and last bit of a word and at the ends of the nonce range.
    function test_audit_nonceGuardMatchesPermit2AtEdges() public {
        Market memory m = _market(true, false);
        uint256[6] memory nonces = [uint256(0), 255, 256, 511, uint256(1) << 255, type(uint256).max];
        for (uint256 i; i < nonces.length; ++i) {
            uint256 nonce = nonces[i];
            uint256 net = _netQuote(m, true, 10e6, _executionFee());
            SignedOrder memory signed = _order(USDC, address(m.token), 10e6, net, nonce);
            uint256 snap = vm.snapshotState();
            vm.prank(trader);
            XPermit2(address(permit2)).invalidateUnorderedNonces(nonce >> 8, uint256(1) << (nonce & 255));
            vm.expectRevert(MercuriOrderFiller.NonceUsed.selector);
            _fill(filler, signed, m.key);
            assertTrue(vm.revertToState(snap));
            // Unused, the same nonce fills, and its replay is refused by the guard.
            _fill(filler, signed, m.key);
            vm.expectRevert(MercuriOrderFiller.NonceUsed.selector);
            _fill(filler, signed, m.key);
        }
    }

    /// "Other addresses with special access": the three privileged checks admit exactly the reactor and the keeper.
    function test_audit_specialAccessIsExactlyKeeperAndReactor() public {
        Market memory m = _market(true, false);
        uint256 net = _netQuote(m, true, 10e6, _executionFee());
        SignedOrder memory signed = _order(USDC, address(m.token), 10e6, net, 920);
        address[4] memory others = [trader, appRecipient, address(reactor), address(router)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(MercuriOrderFiller.NotKeeper.selector);
            filler.fill(signed, m.key);
        }
        // The reactor itself, outside a fill, is refused by the callback.
        vm.prank(address(reactor));
        vm.expectRevert(MercuriOrderFiller.ForbiddenCallback.selector);
        filler.reactorCallback(new ResolvedOrder[](1), "");
        // Native value from the keeper is refused; only the reactor's refund is accepted.
        vm.deal(feeRecipient, 1 ether);
        vm.prank(feeRecipient);
        (bool ok,) = address(filler).call{value: 1}("");
        assertFalse(ok);
    }

    /// Static analysis (13 Oct): Slither `reentrancy-balance` at MercuriOrderFiller.sol:297-303 and Aderyn H-5. Hostile
    /// pool code donates OUTPUT (USDC, on a sell) to the filler while `router.execute` runs, after `outputBefore` was
    /// read. The "stale" balance only lets the donation count as swap surplus, which goes to the trader; the filler's
    /// pre-existing balance is never paid out and the keeper gets exactly the fee.
    function test_audit_midSwapOutputDonationOnlyReachesTrader() public {
        (Market memory m, HostileHook h) = _hostileMarket(false);
        vm.deal(address(h), 1e18);
        address donor = makeAddr("donor");
        vm.deal(donor, 100e18);
        vm.prank(donor);
        IERC20(USDC).transfer(address(filler), 5e6);
        uint256 fillerBefore = IERC20(USDC).balanceOf(address(filler));
        uint256 keeperBefore = IERC20(USDC).balanceOf(feeRecipient);
        uint256 net = _netQuote(m, false, 100e18, _executionFee());
        SignedOrder memory signed = _order(address(m.token), USDC, 100e18, net, 930);
        uint256 traderBefore = IERC20(USDC).balanceOf(trader);
        h.arm(address(m.token), true);
        _fill(filler, signed, m.key);
        assertEq(h.attempts(), 6, "window not reached: hook did not run mid-swap");
        assertEq(h.successes(), 0, "hostile code spent an approval or re-entered");
        assertGe(IERC20(USDC).balanceOf(trader) - traderBefore, net, "trader short");
        assertEq(IERC20(USDC).balanceOf(address(filler)), fillerBefore, "filler's own balance moved");
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - keeperBefore, _executionFee(), "keeper paid other than fee");
    }
}
