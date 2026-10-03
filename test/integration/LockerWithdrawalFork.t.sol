// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {GraduationManager} from "@mercuri/launch/GraduationManager.sol";
import {LiquidityLocker} from "@mercuri/launch/LiquidityLocker.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchConfig, CreateParams} from "@mercuri/launch/libraries/LaunchTypes.sol";
import {NativeUsdcShim} from "../utils/NativeUsdcShim.sol";

interface IERC721Surface {
    function ownerOf(uint256 id) external view returns (address);
    function getApproved(uint256 id) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev Payloads shared by the test (pranked privileged accounts) and the hostile implementation (upgraded proxies),
///      so both try exactly the same withdrawal paths.
library LockerAttack {
    uint256 internal constant ATTEMPTS = 12;

    function decreasePayload(PoolKey memory key, uint256 id, uint256 liquidity, address to)
        internal
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        params = new bytes[](2);
        params[0] = abi.encode(id, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
    }

    function burnPayload(PoolKey memory key, uint256 id, address to)
        internal
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        params = new bytes[](2);
        params[0] = abi.encode(id, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
    }

    /// @dev Every PositionManager call that could move the NFT, grant control of it, or reduce its liquidity.
    function posmCalls(PoolKey memory key, uint256 id, uint128 liquidity, address locker, address me)
        internal
        view
        returns (bytes[] memory calls, string[] memory names)
    {
        calls = new bytes[](ATTEMPTS);
        names = new string[](ATTEMPTS);
        bytes memory sig = new bytes(65);
        sig[64] = 0x1b;
        uint256 deadline = block.timestamp + 1 days;
        (bytes memory a, bytes[] memory p) = decreasePayload(key, id, liquidity, me);
        (bytes memory a1, bytes[] memory p1) = decreasePayload(key, id, 1, me);
        (bytes memory a0, bytes[] memory p0) = decreasePayload(key, id, 0, me);
        (bytes memory b, bytes[] memory q) = burnPayload(key, id, me);
        bytes[] memory multi = new bytes[](1);
        multi[0] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(a, p), deadline));

        (calls[0], names[0]) =
            (abi.encodeWithSignature("transferFrom(address,address,uint256)", locker, me, id), "posm.transferFrom");
        (calls[1], names[1]) = (
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", locker, me, id),
            "posm.safeTransferFrom"
        );
        (calls[2], names[2]) = (
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", locker, me, id, bytes("")),
            "posm.safeTransferFrom(data)"
        );
        (calls[3], names[3]) = (abi.encodeWithSignature("approve(address,uint256)", me, id), "posm.approve");
        (calls[4], names[4]) = (
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(a, p), deadline)),
            "posm.modifyLiquidities(DECREASE all)"
        );
        (calls[5], names[5]) = (
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(a1, p1), deadline)),
            "posm.modifyLiquidities(DECREASE 1)"
        );
        (calls[6], names[6]) = (
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(a0, p0), deadline)),
            "posm.modifyLiquidities(DECREASE 0 / collect)"
        );
        (calls[7], names[7]) = (
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(b, q), deadline)),
            "posm.modifyLiquidities(BURN)"
        );
        (calls[8], names[8]) = (abi.encodeWithSignature("multicall(bytes[])", multi), "posm.multicall(DECREASE)");
        (calls[9], names[9]) =
            (abi.encodeWithSignature("subscribe(uint256,address,bytes)", id, me, bytes("")), "posm.subscribe");
        (calls[10], names[10]) = (
            abi.encodeWithSignature("permit(address,uint256,uint256,uint256,bytes)", me, id, deadline, uint256(7), sig),
            "posm.permit (locker as ERC-1271 signer)"
        );
        (calls[11], names[11]) = (
            abi.encodeWithSignature(
                "permitForAll(address,address,bool,uint256,uint256,bytes)", locker, me, true, deadline, uint256(8), sig
            ),
            "posm.permitForAll (locker as ERC-1271 signer)"
        );
    }
}

/// @dev Implementation a fully compromised governance could install behind any of the three Launch UUPS proxies.
///      Its upgrade check is open, it acts as FeeManager (hook callbacks), LaunchFactory (`curveOf`) and an arbitrary
///      caller, and every withdrawal path runs with `msg.sender` = the proxy. A set bit in a returned mask is a
///      path that SUCCEEDED, which the test reports as a critical precondition failure.
contract HostileLaunchImpl is UUPSUpgradeable, IUnlockCallback {
    using PositionInfoLibrary for PositionInfo;

    IPositionManager public immutable posm;
    IPoolManager public immutable pm;
    address public immutable locker;

    struct HostileState {
        uint256 armedTokenId;
        address curve;
        uint256 inSwapMask;
        uint256 inSwapRuns;
    }

    bytes32 private constant SLOT = keccak256("mercuri.trade.test.hostile-launch-impl");

    constructor(IPositionManager posm_, IPoolManager pm_, address locker_) {
        (posm, pm, locker) = (posm_, pm_, locker_);
    }

    function _h() private pure returns (HostileState storage $) {
        bytes32 s = SLOT;
        assembly {
            $.slot := s
        }
    }

    function _authorizeUpgrade(address) internal override {}

    /// @dev Returns the mask of succeeded paths: bits 0..11 PositionManager calls, 12 re-record in the locker,
    ///      13 raw PoolManager removal under the PositionManager salt, 14 modifyLiquiditiesWithoutUnlock in an
    ///      unlock this proxy opened.
    function attack(address token, uint256 id) external returns (uint256 mask) {
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(id);
        uint128 liquidity = posm.getPositionLiquidity(id);
        (bytes[] memory calls,) = LockerAttack.posmCalls(key, id, liquidity, locker, address(this));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(posm).call(calls[i]);
            if (ok) mask |= 1 << i;
        }
        (bool ok2,) = locker.call(abi.encodeCall(LiquidityLocker.record, (token, id)));
        if (ok2) mask |= 1 << 12;
        (ok2,) = address(pm).call(abi.encodeCall(IPoolManager.unlock, (abi.encode(uint8(1), id))));
        if (ok2) mask |= 1 << 13;
        (ok2,) = address(pm).call(abi.encodeCall(IPoolManager.unlock, (abi.encode(uint8(2), id))));
        if (ok2) mask |= 1 << 14;
    }

    /// @dev Labels any LOCKED position under a token that has no record yet. Not a withdrawal: used to show the
    ///      depth reader must check the position's pool key, not trust `positionOf` alone.
    function mislabel(address unrecordedToken, uint256 id) external {
        LiquidityLocker(locker).record(unrecordedToken, id);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint8 mode, uint256 id) = abi.decode(data, (uint8, uint256));
        if (mode == 1) {
            removeRaw(id);
        } else {
            (PoolKey memory key,) = posm.getPoolAndPositionInfo(id);
            (bytes memory a, bytes[] memory p) =
                LockerAttack.decreasePayload(key, id, posm.getPositionLiquidity(id), address(this));
            posm.modifyLiquiditiesWithoutUnlock(a, p);
        }
        return "";
    }

    /// @dev Removes the locked position's liquidity directly at the PoolManager, using the PositionManager's
    ///      position salt (`bytes32(tokenId)`); the PoolManager keys positions by caller, so this targets
    ///      the caller's own (empty) position. Takes any proceeds so that a success would settle.
    function removeRaw(uint256 id) public {
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(id);
        uint128 liquidity = posm.getPositionLiquidity(id);
        (BalanceDelta d,) = pm.modifyLiquidity(
            key, ModifyLiquidityParams(info.tickLower(), info.tickUpper(), -int256(uint256(liquidity)), bytes32(id)), ""
        );
        if (d.amount0() > 0) pm.take(key.currency0, address(this), uint128(d.amount0()));
        if (d.amount1() > 0) pm.take(key.currency1, address(this), uint128(d.amount1()));
    }

    // ---- FeeManager role: the immutable hook calls these during every swap, inside an open unlock.

    function arm(uint256 id) external {
        _h().armedTokenId = id;
    }

    function inSwap() external view returns (uint256 mask, uint256 runs) {
        return (_h().inSwapMask, _h().inSwapRuns);
    }

    function tradeFeeBps(address) external pure returns (uint16) {
        return type(uint16).max; // the hook clamps to 500 bps
    }

    function notifyHookFee(address, address, uint256) external {
        HostileState storage $ = _h();
        uint256 id = $.armedTokenId;
        if (id == 0) return;
        $.inSwapRuns++;
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(id);
        (bytes memory a, bytes[] memory p) =
            LockerAttack.decreasePayload(key, id, posm.getPositionLiquidity(id), address(this));
        bool ok;
        (ok,) = address(this).call(abi.encodeCall(this.removeRaw, (id)));
        if (ok) $.inSwapMask |= 1;
        (ok,) = address(posm).call(abi.encodeCall(IPositionManager.modifyLiquiditiesWithoutUnlock, (a, p)));
        if (ok) $.inSwapMask |= 2;
        (ok,) = address(posm).call(abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(a, p), 1e12)));
        if (ok) $.inSwapMask |= 4;
        (ok,) = address(posm)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", locker, address(this), id));
        if (ok) $.inSwapMask |= 8;
    }

    // ---- LaunchFactory role: GraduationManager trusts `curveOf(token)` as the only caller of `graduate`.

    function setCurve(address curve) external {
        _h().curve = curve;
    }

    function curveOf(address) external view returns (address) {
        return _h().curve;
    }
}

/// @dev Stands in for a bonding curve a hostile factory names, to re-run `graduate` on a graduated token.
contract FakeCurve {
    uint256 public immutable poolSupply;

    constructor(uint256 poolSupply_) {
        poolSupply = poolSupply_;
    }

    function go(GraduationManager gm, address token) external {
        gm.graduate{value: address(this).balance}(token);
    }
}

/// @dev Raw PoolManager caller: removal under another owner's salt, and an exact-input USDC swap.
contract RawPoolCaller is IUnlockCallback {
    using PositionInfoLibrary for PositionInfo;

    IPoolManager internal immutable pm;
    IPositionManager internal immutable posm;
    address internal constant USDC = 0x3600000000000000000000000000000000000000;

    constructor(IPoolManager pm_, IPositionManager posm_) {
        (pm, posm) = (pm_, posm_);
    }

    function remove(uint256 id, bytes32 salt) external {
        pm.unlock(abi.encode(uint8(1), id, salt, uint256(0)));
    }

    function swapUsdcIn(uint256 id, uint256 usdcIn) external {
        pm.unlock(abi.encode(uint8(2), id, bytes32(0), usdcIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint8 mode, uint256 id, bytes32 salt, uint256 usdcIn) = abi.decode(data, (uint8, uint256, bytes32, uint256));
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(id);
        BalanceDelta d;
        if (mode == 1) {
            uint128 liquidity = posm.getPositionLiquidity(id);
            (d,) = pm.modifyLiquidity(
                key, ModifyLiquidityParams(info.tickLower(), info.tickUpper(), -int256(uint256(liquidity)), salt), ""
            );
        } else {
            bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
            d = pm.swap(
                key,
                SwapParams(
                    usdcIs0, -int256(usdcIn), usdcIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
        }
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount > 0) {
            pm.take(c, address(this), uint128(amount));
        } else if (amount < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-amount));
            pm.settle();
        }
    }
}

/// @notice Precondition of spec D30: no one, governance included, can withdraw or reduce a graduated token's
///         LiquidityLocker position. Read-only RPC fork (a loopback Anvil fork of Arc); nothing is broadcast.
/// @dev Run once per network: ARC_LOCAL_FORK_RPC=<anvil> TRADE_FORK_CHAIN_ID=5042|5042002 [TRADE_FORK_BLOCK=n].
///      Arc's native USDC ERC-20 precompile is modelled by the same rollback-safe shim as the other fork suites.
///      Every privileged account is impersonated, including contracts (timelock, proxies, hook, PoolManager) that
///      could never originate such a call: that is strictly stronger than any real attacker.
contract LockerWithdrawalForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant MAINNET_BLOCK = 24_065_788;
    uint256 internal constant TESTNET_BLOCK = 65_301_435;

    struct Locked {
        address token;
        uint256 tokenId;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    uint256 internal chain;
    IPositionManager internal posm;
    IPoolManager internal pm;
    LiquidityLocker internal locker;
    LaunchFactory internal factory;
    GraduationManager internal gm;
    address internal feeManager;
    address internal hook;
    TimelockController internal timelock;
    address internal proposer;
    address internal executor;
    address internal canceller;
    address internal guardian;
    address internal treasury;
    address internal deployer;
    address internal attacker = makeAddr("attacker");
    uint256 internal attempts;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_LOCAL_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        chain = vm.envOr("TRADE_FORK_CHAIN_ID", uint256(5042002));
        require(chain == 5042002 || chain == 5042, "unsupported fork chain");
        vm.createSelectFork(rpc, vm.envOr("TRADE_FORK_BLOCK", chain == 5042 ? MAINNET_BLOCK : TESTNET_BLOCK));
        assertEq(block.chainid, chain);

        string memory json =
            vm.readFile(string.concat("lib/mercuri-launch-contracts/deployments/", vm.toString(chain), ".json"));
        posm = IPositionManager(vm.parseJsonAddress(json, ".positionManager"));
        pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        locker = LiquidityLocker(vm.parseJsonAddress(json, ".liquidityLocker"));
        factory = LaunchFactory(vm.parseJsonAddress(json, ".factory"));
        gm = GraduationManager(vm.parseJsonAddress(json, ".graduationManager"));
        feeManager = vm.parseJsonAddress(json, ".feeManager");
        hook = vm.parseJsonAddress(json, ".launchHook");
        timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        proposer = vm.parseJsonAddress(json, ".proposer");
        executor = vm.parseJsonAddress(json, ".executor");
        canceller = vm.parseJsonAddress(json, ".canceller");
        guardian = vm.parseJsonAddress(json, ".guardian");
        treasury = vm.parseJsonAddress(json, ".treasury");
        deployer = vm.parseJsonAddress(json, ".deployer");

        vm.etch(USDC, address(new NativeUsdcShim()).code);
        vm.allowCheatcodes(USDC);
    }

    // ------------------------------------------------------------------ structure

    /// @dev Covers every selector at once: the deployed locker runtime contains no CALL, CALLCODE, DELEGATECALL,
    ///      CREATE, CREATE2 or SELFDESTRUCT, so it can never approve, transfer, modify or burn anything, and it
    ///      is not a proxy. Its only external calls are STATICCALLs (`ownerOf`).
    function test_lockerRuntimeCannotIssueAStateChangingCall() public view {
        bytes memory code = address(locker).code;
        assertGt(code.length, 0, "locker has no code");
        uint256 end = code.length;
        uint256 metaLen = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
        require(metaLen + 2 < end && (uint8(code[end - metaLen - 2]) & 0xe0) == 0xa0, "no CBOR trailer");
        end -= metaLen + 2;
        uint256 staticCalls;
        uint256 stores;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xf0 && op != 0xf5, "locker can CREATE");
            require(op != 0xf1 && op != 0xf2, "locker can CALL");
            require(op != 0xf4, "locker can DELEGATECALL");
            require(op != 0xff, "locker can SELFDESTRUCT");
            if (op == 0xfa) ++staticCalls;
            if (op == 0x55) ++stores;
        }
        assertGt(staticCalls, 0);
        assertEq(stores, 1, "only positionOf is ever written");
        assertEq(vm.load(address(locker), IMPL_SLOT), bytes32(0), "locker is not an ERC-1967 proxy");
        assertEq(address(locker.positionManager()), address(posm));
        assertEq(locker.graduationManager(), address(gm));
        assertEq(vm.load(address(posm), IMPL_SLOT), bytes32(0), "PositionManager is not a proxy");
        assertEq(vm.load(address(pm), IMPL_SLOT), bytes32(0), "PoolManager is not a proxy");
        // The hook enables no liquidity callback (and none can withdraw another owner's position anyway).
        uint160 flags = uint160(hook) & Hooks.ALL_HOOK_MASK;
        assertEq(flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG, 0);
        assertEq(flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG, 0);
        assertEq(flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG, 0);
        assertEq(flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG, 0);
    }

    // ------------------------------------------------------------------ privileged accounts, directly

    /// @dev Every privileged account (and an outsider) tries every NFT and liquidity path against every real
    ///      graduated position on the fork plus one graduated here through the deployed contracts.
    function test_noAccountCanMoveOrReduceALockedPosition() public {
        Locked[] memory ps = _positions();
        address[] memory actors = _actors();
        for (uint256 k; k < ps.length; ++k) {
            Locked memory p = ps[k];
            for (uint256 j; j < actors.length; ++j) {
                address actor = actors[j];
                (bytes[] memory calls, string[] memory names) =
                    LockerAttack.posmCalls(p.key, p.tokenId, p.liquidity, address(locker), actor);
                for (uint256 i; i < calls.length; ++i) {
                    _mustFail(actor, address(posm), calls[i], names[i]);
                }
                _lockerAbi(actor, p);
                assertFalse(IERC721Surface(address(posm)).isApprovedForAll(address(locker), actor));
            }
            _assertIntact(p);
        }
        emit log_named_uint("withdrawal attempts, all reverted", attempts);
    }

    /// @dev Guardian and Safe/EOA roles cannot upgrade a proxy directly; only the timelock owns them. Pausing the
    ///      factory touches no position.
    function test_noDirectUpgradeAndPauseLeavesPositionsIntact() public {
        Locked[] memory ps = _positions();
        HostileLaunchImpl bad = new HostileLaunchImpl(posm, pm, address(locker));
        address[3] memory proxies = [address(factory), feeManager, address(gm)];
        address[6] memory who = [proposer, executor, canceller, guardian, deployer, attacker];
        for (uint256 i; i < proxies.length; ++i) {
            assertEq(Ownable(proxies[i]).owner(), address(timelock), "proxy owner is the timelock");
            for (uint256 j; j < who.length; ++j) {
                _mustFail(
                    who[j],
                    proxies[i],
                    abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(bad), "")),
                    "direct upgradeToAndCall"
                );
            }
        }
        // Executing an unscheduled operation is refused.
        _mustFail(
            executor,
            address(timelock),
            abi.encodeCall(
                TimelockController.execute,
                (address(gm), 0, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(bad), "")), 0, 0)
            ),
            "timelock.execute unscheduled"
        );
        vm.prank(guardian);
        factory.pause();
        for (uint256 k; k < ps.length; ++k) {
            _assertIntact(ps[k]);
        }
    }

    // ------------------------------------------------------------------ fully compromised governance

    /// @dev The Safe proposes and executes, through the real timelock and its real delay, an upgrade of each UUPS
    ///      proxy to a hostile implementation, then each proxy tries every path, including from inside a live swap
    ///      (the hook calls the FeeManager while the PoolManager is unlocked) and a hostile factory re-running
    ///      graduation of a graduated token.
    function test_governanceUpgradesCannotReachLockedPositions() public {
        Locked[] memory ps = _positions();
        HostileLaunchImpl bad = new HostileLaunchImpl(posm, pm, address(locker));

        // 1. LaunchFactory: name a fake curve and re-run graduation through the real GraduationManager.
        _timelockUpgrade(address(factory), address(bad));
        for (uint256 k; k < ps.length; ++k) {
            Locked memory p = ps[k];
            FakeCurve fake = new FakeCurve(1e24);
            HostileLaunchImpl(address(factory)).setCurve(address(fake));
            deal(p.token, address(gm), 1e24);
            vm.deal(address(fake), 1e18);
            _mustFail(
                address(this),
                address(fake),
                abi.encodeCall(FakeCurve.go, (gm, p.token)),
                "hostile factory re-graduates a graduated token"
            );
            _assertNoPath(HostileLaunchImpl(address(factory)).attack(p.token, p.tokenId), "factory");
            _assertIntact(p);
        }

        // 2. FeeManager: attack directly, then from inside a swap on the pool (hook -> notifyHookFee).
        _timelockUpgrade(feeManager, address(bad));
        RawPoolCaller swapper = new RawPoolCaller(pm, posm);
        vm.deal(address(swapper), 1_000e18);
        for (uint256 k; k < ps.length; ++k) {
            Locked memory p = ps[k];
            _assertNoPath(HostileLaunchImpl(feeManager).attack(p.token, p.tokenId), "feeManager");
            HostileLaunchImpl(feeManager).arm(p.tokenId);
            swapper.swapUsdcIn(p.tokenId, 10e6);
            (uint256 mask, uint256 runs) = HostileLaunchImpl(feeManager).inSwap();
            assertGt(runs, 0, "hook called the hostile FeeManager mid-swap");
            if (mask != 0) {
                emit log_named_uint("CRITICAL precondition failure: in-swap path mask", mask);
                fail();
            }
            HostileLaunchImpl(feeManager).arm(0);
            _assertIntact(p);
        }

        // 3. GraduationManager: the locker's only trusted caller.
        _timelockUpgrade(address(gm), address(bad));
        for (uint256 k; k < ps.length; ++k) {
            _assertNoPath(HostileLaunchImpl(address(gm)).attack(ps[k].token, ps[k].tokenId), "graduationManager");
            _assertIntact(ps[k]);
        }

        // 4. With all three hostile at once, every account still fails every direct path.
        address[] memory actors = _actors();
        for (uint256 k; k < ps.length; ++k) {
            for (uint256 j; j < actors.length; ++j) {
                (bytes[] memory calls, string[] memory names) =
                    LockerAttack.posmCalls(ps[k].key, ps[k].tokenId, ps[k].liquidity, address(locker), actors[j]);
                for (uint256 i; i < calls.length; ++i) {
                    _mustFail(actors[j], address(posm), calls[i], names[i]);
                }
            }
            _assertIntact(ps[k]);
        }
        emit log_named_uint("withdrawal attempts after hostile upgrades, all reverted", attempts);
    }

    /// @dev Not a withdrawal, but it bounds how D30 may read the lock: an upgraded GraduationManager can label a
    ///      locked position under a token that has no record yet. It can never relabel a recorded token.
    function test_upgradedGraduationManagerCanOnlyLabelUnrecordedTokens() public {
        Locked[] memory ps = _positions();
        HostileLaunchImpl bad = new HostileLaunchImpl(posm, pm, address(locker));
        _timelockUpgrade(address(gm), address(bad));
        Locked memory p = ps[0];
        Locked memory other = ps[ps.length - 1];
        vm.expectRevert(LiquidityLocker.AlreadyRecorded.selector);
        HostileLaunchImpl(address(gm)).mislabel(p.token, other.tokenId);
        address unrecorded = makeAddr("unrecorded-token");
        HostileLaunchImpl(address(gm)).mislabel(unrecorded, p.tokenId);
        assertEq(locker.positionOf(unrecorded), p.tokenId);
        assertEq(locker.positionOf(p.token), p.tokenId, "a recorded token keeps its position");
        for (uint256 k; k < ps.length; ++k) {
            _assertIntact(ps[k]);
        }
    }

    // ------------------------------------------------------------------ Uniswap v4 mechanics

    /// @dev PoolManager positions are keyed by caller: no one but the PositionManager can touch its salts. The
    ///      PoolManager owner's only powers are protocol-fee settings, which never reach principal. The hook only
    ///      answers the PoolManager.
    function test_poolManagerAndHookCannotReduceALockedPosition() public {
        Locked[] memory ps = _positions();
        RawPoolCaller raw = new RawPoolCaller(pm, posm);
        address pmOwner = Ownable(address(pm)).owner();
        for (uint256 k; k < ps.length; ++k) {
            Locked memory p = ps[k];
            _mustFail(
                attacker, address(raw), abi.encodeCall(RawPoolCaller.remove, (p.tokenId, bytes32(p.tokenId))), "pm salt"
            );
            _mustFail(attacker, address(raw), abi.encodeCall(RawPoolCaller.remove, (p.tokenId, 0)), "pm zero salt");
            _mustFail(
                attacker,
                hook,
                abi.encodeWithSelector(IHooks.beforeSwap.selector, attacker, p.key, SwapParams(true, -1, 0), ""),
                "direct hook.beforeSwap"
            );

            vm.prank(pmOwner);
            pm.setProtocolFeeController(attacker);
            vm.prank(attacker);
            pm.setProtocolFee(p.key, 1000 | (1000 << 12));
            _mustFail(
                attacker,
                address(pm),
                abi.encodeWithSignature("collectProtocolFees(address,address,uint256)", attacker, USDC, uint256(1)),
                "pm.collectProtocolFees beyond accrued"
            );
            _assertIntact(p);
        }
    }

    /// @dev Positive control: if the locker could ever call the PositionManager, the same payload WOULD reduce the
    ///      position. Pranking the locker is not a real path (its runtime has no CALL); it proves the harness
    ///      detects a successful withdrawal.
    function test_control_harnessDetectsAWithdrawal() public {
        Locked memory p = _positions()[0];
        (bytes memory a, bytes[] memory q) = LockerAttack.decreasePayload(p.key, p.tokenId, p.liquidity / 2, attacker);
        vm.prank(address(locker));
        posm.modifyLiquidities(abi.encode(a, q), block.timestamp + 1);
        assertEq(posm.getPositionLiquidity(p.tokenId), p.liquidity - p.liquidity / 2);
    }

    // ------------------------------------------------------------------ helpers

    function _positions() internal returns (Locked[] memory ps) {
        address[] memory real = _realGraduated();
        ps = new Locked[](real.length + 1);
        for (uint256 i; i < real.length; ++i) {
            ps[i] = _load(real[i]);
        }
        ps[real.length] = _load(_simulateGraduation());
        emit log_named_uint("positions under test (real graduated + one simulated)", ps.length);
    }

    /// @dev Graduated launches at the pinned blocks, found by scanning the locker's PositionManager balance
    ///      (mainnet: none; testnet: NFT ids 52, 53 and 54).
    function _realGraduated() internal view returns (address[] memory tokens) {
        uint256 held = IERC721Surface(address(posm)).balanceOf(address(locker));
        if (chain == 5042) {
            require(block.number != MAINNET_BLOCK || held == 0, "mainnet graduations appeared; list them");
            return new address[](0);
        }
        tokens = new address[](3);
        tokens[0] = 0x97B4f9cc5d78bBf47569425D298dcb5Ff392eE84;
        tokens[1] = 0x0Cdf93564d7E50676C8BC0839699478c2c973819;
        tokens[2] = 0x207431f771ee7Ce689C2d7E76f9c84A9f0b932A8;
        assertEq(held, tokens.length, "testnet locker holdings");
    }

    function _load(address token) internal view returns (Locked memory p) {
        p.token = token;
        p.tokenId = locker.positionOf(token);
        assertGt(p.tokenId, 0, "recorded");
        assertTrue(locker.isLocked(token));
        PositionInfo info;
        (p.key, info) = posm.getPoolAndPositionInfo(p.tokenId);
        (p.tickLower, p.tickUpper) = (info.tickLower(), info.tickUpper());
        p.liquidity = posm.getPositionLiquidity(p.tokenId);
        assertGt(p.liquidity, 0);
        assertEq(PoolId.unwrap(p.key.toId()), PoolId.unwrap(gm.poolKey(token).toId()), "position is the token's pool");
        assertEq(address(p.key.hooks), hook);
    }

    /// @dev Creates a launch through the deployed factory and buys out its curve, so the deployed GraduationManager
    ///      mints a fresh position into the deployed locker on this fork.
    function _simulateGraduation() internal returns (address token) {
        LaunchConfig memory c = factory.config();
        bytes32 pinned = factory.configHash();
        address creator = makeAddr("fork-creator");
        vm.deal(creator, c.launchFee + 200_000e18);
        vm.prank(creator);
        (address t, address curve) = factory.createToken{value: c.launchFee}(
            CreateParams(
                "Lock probe", "PROBE", "https://example.invalid/p.json", creator, address(0), keccak256("lock-probe")
            ),
            pinned,
            0
        );
        vm.roll(vm.getBlockNumber() + c.snipeBlocks + 1);
        vm.prank(creator);
        BondingCurve(payable(curve)).buy{value: 200_000e18}(0, address(0), type(uint256).max);
        require(BondingCurve(payable(curve)).phase() == BondingCurve.Phase.Graduated, "simulated launch graduated");
        return t;
    }

    function _actors() internal view returns (address[] memory a) {
        a = new address[](14);
        a[0] = address(timelock);
        a[1] = proposer;
        a[2] = executor;
        a[3] = canceller;
        a[4] = guardian;
        a[5] = treasury;
        a[6] = deployer;
        a[7] = address(factory);
        a[8] = feeManager;
        a[9] = address(gm);
        a[10] = hook;
        a[11] = Ownable(address(pm)).owner();
        a[12] = address(pm);
        a[13] = attacker;
    }

    /// @dev The locker's whole ABI (positionManager, graduationManager, positionOf, record, isLocked) plus common
    ///      custody selectors it does not have; only `record` writes and it cannot be repeated.
    function _lockerAbi(address actor, Locked memory p) internal {
        _mustFail(actor, address(locker), abi.encodeCall(LiquidityLocker.record, (p.token, p.tokenId)), "record");
        bytes[8] memory foreign = [
            abi.encodeWithSignature("approve(address,uint256)", actor, p.tokenId),
            abi.encodeWithSignature("setApprovalForAll(address,bool)", actor, true),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(locker), actor, p.tokenId),
            abi.encodeWithSignature("execute(address,uint256,bytes)", address(posm), 0, ""),
            abi.encodeWithSignature("multicall(bytes[])", new bytes[](0)),
            abi.encodeWithSignature("withdraw(address)", p.token),
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", actor, "")
        ];
        for (uint256 i; i < foreign.length; ++i) {
            _mustFail(actor, address(locker), foreign[i], "locker foreign selector");
        }
        _mustFail(actor, address(locker), "", "locker empty calldata");
    }

    function _timelockUpgrade(address proxy, address impl) internal {
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, ""));
        uint256 delay = timelock.getMinDelay();
        bytes32 salt = keccak256(abi.encode(proxy, impl));
        vm.prank(proposer);
        timelock.schedule(proxy, 0, data, 0, salt, delay);
        vm.expectRevert();
        vm.prank(executor);
        timelock.execute(proxy, 0, data, 0, salt);
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(executor);
        timelock.execute(proxy, 0, data, 0, salt);
        assertEq(address(uint160(uint256(vm.load(proxy, IMPL_SLOT)))), impl, "upgraded");
    }

    function _mustFail(address actor, address target, bytes memory data, string memory what) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(actor);
        (bool ok,) = target.call(data);
        // Roll back first: the failure flag and the counter must survive the rollback.
        vm.revertToStateAndDelete(snap);
        ++attempts;
        if (ok) {
            emit log_named_address("CRITICAL precondition failure, caller", actor);
            emit log_named_string("path", what);
            fail();
        }
    }

    function _assertNoPath(uint256 mask, string memory role) internal {
        attempts += LockerAttack.ATTEMPTS + 3;
        if (mask != 0) {
            emit log_named_string("CRITICAL precondition failure, upgraded proxy", role);
            emit log_named_uint("succeeded-path mask", mask);
            fail();
        }
    }

    function _assertIntact(Locked memory p) internal view {
        IERC721Surface nft = IERC721Surface(address(posm));
        assertEq(nft.ownerOf(p.tokenId), address(locker), "locker still owns the NFT");
        assertEq(nft.getApproved(p.tokenId), address(0), "no per-token approval");
        assertEq(address(posm.subscriber(p.tokenId)), address(0), "no subscriber");
        assertEq(posm.getPositionLiquidity(p.tokenId), p.liquidity, "PositionManager liquidity unchanged");
        bytes32 positionKey = Position.calculatePositionKey(address(posm), p.tickLower, p.tickUpper, bytes32(p.tokenId));
        assertEq(pm.getPositionLiquidity(p.key.toId(), positionKey), p.liquidity, "PoolManager liquidity unchanged");
        assertEq(locker.positionOf(p.token), p.tokenId);
        assertTrue(locker.isLocked(p.token));
    }
}

interface Ownable {
    function owner() external view returns (address);
}
