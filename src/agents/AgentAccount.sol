// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ILaunchFactory} from "@mercuri/launch/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {IGraduationManager} from "@mercuri/launch/interfaces/IGraduationManager.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {GraduationManager} from "@mercuri/launch/GraduationManager.sol";
import {CreateParams} from "@mercuri/launch/libraries/LaunchTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "./interfaces/IAgentPolicyRegistry.sol";
import {AgentPolicyLib} from "./AgentPolicyLib.sol";
import {
    LaunchRequest,
    Policy,
    Basis,
    P_BUY,
    P_SELL,
    P_LAUNCH,
    P_POOL_SWAP,
    P_CLAIM,
    P_SWEEP_TO_OWNER,
    ACTION_BUY,
    ACTION_SELL,
    ACTION_LAUNCH,
    ACTION_POOL_BUY,
    ACTION_POOL_SELL,
    ACTION_CLAIM,
    ACTION_SWEEP,
    SCALE,
    HIGH_WATER_SCALE
} from "./AgentTypes.sol";

/// @notice The one Universal Router entry point agent accounts call.
interface IUniversalRouterExecute {
    /// @notice Runs `commands` with their `inputs`, reverting after `deadline`.
    /// @param commands One byte per command.
    /// @param inputs ABI-encoded input of each command.
    /// @param deadline Latest Unix time (seconds).
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Universal Router command V4_SWAP (0x10) with the allow-revert bit (0x80) clear.
bytes constant V4_SWAP_COMMAND = hex"10";
/// @dev V4 actions SWAP_EXACT_IN_SINGLE (0x06), SETTLE_ALL (0x0c), TAKE_ALL (0x0f).
bytes constant V4_ACTIONS = hex"060c0f";

/// @notice A Mercurifi agent account: a per-user vault whose agent keys trade Launch tokens within owner-set caps and
///         can never withdraw. Withdrawals go only to the owner, and the owner has no trade path.
/// @dev The implementation behind EIP-1167 clones made by `FACTORY`. Every dependency is an immutable of this
///      implementation, so clones read it from the implementation's code. The account holds funds, the cost basis
///      and the typed trade functions; owner, policy, agents, queue and usage live in `REGISTRY`, which authorises
///      each agent call and charges each trade to the period caps. No proxy upgrade, delegatecall, generic execute or
///      selfdestruct. The implementation itself is locked in its constructor and has no owner.
contract AgentAccount is IAgentAccount, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @inheritdoc IAgentAccount
    address public immutable FACTORY;
    /// @inheritdoc IAgentAccount
    IAgentPolicyRegistry public immutable REGISTRY;
    /// @inheritdoc IAgentAccount
    ILaunchFactory public immutable LAUNCH_FACTORY;
    /// @inheritdoc IAgentAccount
    IFeeManager public immutable FEE_MANAGER;
    /// @inheritdoc IAgentAccount
    IGraduationManager public immutable GRADUATION_MANAGER;
    /// @inheritdoc IAgentAccount
    address public immutable LAUNCH_HOOK;
    /// @inheritdoc IAgentAccount
    IPoolManager public immutable POOL_MANAGER;
    /// @inheritdoc IAgentAccount
    address public immutable UNIVERSAL_ROUTER;
    /// @inheritdoc IAgentAccount
    address public immutable PERMIT2;
    /// @inheritdoc IAgentAccount
    address public immutable USDC;

    /// @dev Set once by `initialize`, and by the constructor on the implementation.
    bool private initialized;
    /// @inheritdoc IAgentAccount
    address public referrer;
    /// @dev Recorded cost basis per token; read through `basis()`.
    mapping(address => Basis) private _basis;

    /// @notice Deploys the implementation, bound to its factory, the factory's registry and the network's Launch and
    ///         Uniswap contracts.
    /// @dev Reverts `ZeroAddress` for any zero dependency. Locks itself: `initialize` on the implementation reverts.
    /// @param factory_ The AgentAccountFactory that will clone this implementation (predicted before deployment).
    /// @param registry_ The AgentPolicyRegistry that factory deploys (predicted: the factory's first CREATE).
    /// @param launchFactory_ LaunchFactory proxy.
    /// @param feeManager_ FeeManager proxy.
    /// @param graduationManager_ GraduationManager proxy.
    /// @param launchHook_ LaunchHook.
    /// @param poolManager_ Uniswap v4 PoolManager.
    /// @param universalRouter_ Universal Router.
    /// @param permit2_ Permit2.
    /// @param usdc_ Arc's native USDC (6-decimal ERC-20 view).
    constructor(
        address factory_,
        address registry_,
        address launchFactory_,
        address feeManager_,
        address graduationManager_,
        address launchHook_,
        address poolManager_,
        address universalRouter_,
        address permit2_,
        address usdc_
    ) {
        if (
            factory_ == address(0) || registry_ == address(0) || launchFactory_ == address(0)
                || feeManager_ == address(0) || graduationManager_ == address(0) || launchHook_ == address(0)
                || poolManager_ == address(0) || universalRouter_ == address(0) || permit2_ == address(0)
                || usdc_ == address(0)
        ) revert ZeroAddress();
        FACTORY = factory_;
        REGISTRY = IAgentPolicyRegistry(registry_);
        LAUNCH_FACTORY = ILaunchFactory(launchFactory_);
        FEE_MANAGER = IFeeManager(feeManager_);
        GRADUATION_MANAGER = IGraduationManager(graduationManager_);
        LAUNCH_HOOK = launchHook_;
        POOL_MANAGER = IPoolManager(poolManager_);
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
        USDC = usdc_;
        initialized = true;
    }

    /// @notice Accepts native USDC from anyone. No logic runs.
    receive() external payable {}

    /// @inheritdoc IAgentAccount
    function initialize(address referrer_) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        if (referrer_ != address(0)) {
            if (referrer_ == address(this)) revert SelfReferrer();
            referrer = referrer_;
            FEE_MANAGER.bindReferrer(referrer_);
        }
    }

    /// @inheritdoc IAgentAccount
    function owner() public view returns (address) {
        return REGISTRY.owner(address(this));
    }

    /// @inheritdoc IAgentAccount
    function basis(address token) external view returns (uint128 costUsdc, uint128 tokens, uint256 highWater) {
        Basis memory b = _basis[token];
        return (b.costUsdc, b.tokens, b.highWater);
    }

    // ------------------------------------------------------------------ agent trading

    /// @inheritdoc IAgentAccount
    function buy(address token, uint256 usdcIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        (Policy memory p, uint64 periodId) = REGISTRY.authorize(msg.sender, P_BUY, deadline);
        BondingCurve curve = _curve(token);
        if (curve.phase() != BondingCurve.Phase.Trading) revert NotTrading();
        if (p.allowlistOnly && !REGISTRY.tokenAllowed(address(this), token)) revert TokenNotAllowed();
        if (block.number - curve.launchBlock() < p.minTokenAgeBlocks) revert TokenTooNew();
        uint256 snipe = curve.currentSnipeBps();
        if (snipe > p.maxSnipeBps) revert SnipeTaxTooHigh(snipe);
        if (usdcIn == 0) revert ZeroAmount();
        if (usdcIn > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
        if (minTokensOut == 0) revert ZeroMinOut();
        uint256 value = _toWei(usdcIn);
        {
            (uint256 out, uint256 used, uint256 fee, uint256 tax) = curve.quoteBuy(value);
            if (out == 0) revert ZeroOutput();
            _checkImpact(AgentPolicyLib.buyImpactBps(used - fee - tax, out, curve.price()), p.maxPriceImpactBps);
        }

        uint256 balBefore = address(this).balance;
        uint256 heldBefore = IERC20(token).balanceOf(address(this));
        curve.buy{value: value}(minTokensOut, referrer, deadline);
        // Refunds (the final buy of a curve) are netted; round the spend up to usdc6.
        uint256 spent = Math.ceilDiv(balBefore - address(this).balance, SCALE);
        tokensOut = IERC20(token).balanceOf(address(this)) - heldBefore;

        if (spent > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
        REGISTRY.record(token, spent, 0, false);
        _addBasis(token, spent, tokensOut);
        emit AgentAction(msg.sender, ACTION_BUY, token, spent, 0, SafeCast.toInt256(tokensOut), spent, periodId);
    }

    /// @inheritdoc IAgentAccount
    function sell(address token, uint256 tokensIn, uint256 minUsdcOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        (Policy memory p, uint64 periodId) = REGISTRY.authorize(msg.sender, P_SELL, deadline);
        BondingCurve curve = _curve(token);
        if (curve.phase() == BondingCurve.Phase.Graduated) revert NotTrading();
        if (tokensIn == 0) revert ZeroAmount();
        if (minUsdcOut == 0) revert ZeroMinOut();
        uint256 minWei = _toWei(minUsdcOut);

        // Cost-basis value: the recorded share at cost (rounded up), tokens beyond it at their pre-trade quote.
        Basis memory b = _basis[token];
        uint256 recorded = tokensIn < b.tokens ? tokensIn : b.tokens;
        uint256 basisValue = _recordedValue(b, recorded);
        if (tokensIn > recorded) {
            (uint256 excessOut,) = curve.quoteSell(tokensIn - recorded);
            basisValue += Math.ceilDiv(excessOut, SCALE);
        }
        if (basisValue > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
        {
            (uint256 out, uint256 fee) = curve.quoteSell(tokensIn);
            if (out == 0) revert ZeroOutput();
            _checkImpact(AgentPolicyLib.sellImpactBps(out + fee, tokensIn, curve.price()), p.maxPriceImpactBps);
        }

        uint256 balBefore = address(this).balance;
        uint256 heldBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).forceApprove(address(curve), tokensIn);
        curve.sell(tokensIn, minWei, referrer, deadline);
        if (IERC20(token).allowance(address(this), address(curve)) != 0) revert AllowanceNotCleared();
        // Proceeds round down to usdc6 and never create headroom.
        usdcOut = (address(this).balance - balBefore) / SCALE;
        uint256 sent = heldBefore - IERC20(token).balanceOf(address(this));

        REGISTRY.record(token, 0, basisValue, false);
        if (recorded != 0) _cutBasis(token, b, recorded);
        emit AgentAction(msg.sender, ACTION_SELL, token, 0, usdcOut, -SafeCast.toInt256(sent), basisValue, periodId);
    }

    /// @inheritdoc IAgentAccount
    function swapExactIn(address token, bool buyToken, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        (Policy memory p, uint64 periodId) = REGISTRY.authorize(msg.sender, P_POOL_SWAP, deadline);
        if (_curve(token).phase() != BondingCurve.Phase.Graduated) revert NotGraduated();
        if (amountIn == 0) revert ZeroAmount();
        if (minAmountOut == 0) revert ZeroMinOut();
        if (amountIn > type(uint128).max || minAmountOut > type(uint128).max) revert AmountTooLarge();
        // The key is derived, never supplied: the GraduationManager's pool for the token, through the LaunchHook.
        PoolKey memory key = GraduationManager(address(GRADUATION_MANAGER)).poolKey(token);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (address(key.hooks) != LAUNCH_HOOK || !((c0 == USDC && c1 == token) || (c0 == token && c1 == USDC))) {
            revert UnexpectedPool();
        }

        uint256 balBefore = address(this).balance;
        uint256 heldBefore = IERC20(token).balanceOf(address(this));
        if (buyToken) {
            if (p.allowlistOnly && !REGISTRY.tokenAllowed(address(this), token)) revert TokenNotAllowed();
            if (amountIn > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
            _poolSwap(key, USDC, token, amountIn, minAmountOut, deadline, p.maxPriceImpactBps);
            // Arc's USDC ERC-20 view moves the native balance, so the router's pull shows in the native delta.
            uint256 spent = Math.ceilDiv(balBefore - address(this).balance, SCALE);
            amountOut = IERC20(token).balanceOf(address(this)) - heldBefore;
            if (spent > amountIn || amountOut < minAmountOut) revert UnexpectedSwapDelta();
            REGISTRY.record(token, spent, 0, false);
            _addBasis(token, spent, amountOut);
            emit AgentAction(
                msg.sender, ACTION_POOL_BUY, token, spent, 0, SafeCast.toInt256(amountOut), spent, periodId
            );
        } else {
            Basis memory b = _basis[token];
            uint256 recorded = amountIn < b.tokens ? amountIn : b.tokens;
            uint256 basisValue = _recordedValue(b, recorded);
            if (basisValue > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
            _poolSwap(key, token, USDC, amountIn, minAmountOut, deadline, p.maxPriceImpactBps);
            uint256 receivedWei = address(this).balance - balBefore;
            amountOut = receivedWei / SCALE;
            uint256 sent = heldBefore - IERC20(token).balanceOf(address(this));
            if (sent > amountIn || amountOut < minAmountOut) revert UnexpectedSwapDelta();
            if (amountIn > recorded) {
                // Unrecorded tokens at their pro-rata share of the measured proceeds, rounded up (weaker than cost:
                // a pool moved beforehand sets it).
                basisValue += Math.ceilDiv(
                    Math.mulDiv(receivedWei, amountIn - recorded, amountIn, Math.Rounding.Ceil), SCALE
                );
                if (basisValue > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
            }
            REGISTRY.record(token, 0, basisValue, false);
            if (recorded != 0) _cutBasis(token, b, recorded);
            emit AgentAction(
                msg.sender, ACTION_POOL_SELL, token, 0, amountOut, -SafeCast.toInt256(sent), basisValue, periodId
            );
        }
    }

    /// @inheritdoc IAgentAccount
    function launch(LaunchRequest calldata r) external nonReentrant returns (address token, address curve) {
        (Policy memory p, uint64 periodId) = REGISTRY.authorize(msg.sender, P_LAUNCH, r.deadline);
        uint256 fee = LaunchFactory(address(LAUNCH_FACTORY)).config().launchFee;
        uint256 feeUsdc = Math.ceilDiv(fee, SCALE);
        // Compared as "at most what is left", so no input can overflow.
        if (r.initialBuyUsdc > p.maxTradeUsdc || feeUsdc > p.maxTradeUsdc - r.initialBuyUsdc) {
            revert TradeTooLarge(p.maxTradeUsdc);
        }

        uint256 balBefore = address(this).balance;
        (token, curve) = LaunchFactory(address(LAUNCH_FACTORY)).createToken{value: fee + _toWei(r.initialBuyUsdc)}(
            CreateParams(r.name, r.symbol, r.metadataURI, address(this), referrer, r.salt),
            r.expectedConfigHash,
            r.minTokensOut
        );
        uint256 spent = Math.ceilDiv(balBefore - address(this).balance, SCALE);
        // The token is new, so the whole balance is the initial buy.
        uint256 tokensOut = IERC20(token).balanceOf(address(this));

        if (spent > p.maxTradeUsdc) revert TradeTooLarge(p.maxTradeUsdc);
        REGISTRY.record(token, spent, 0, true);
        uint256 cost;
        if (tokensOut != 0) {
            cost = spent > feeUsdc ? spent - feeUsdc : 0;
            _addBasis(token, cost, tokensOut);
        }
        emit AgentAction(msg.sender, ACTION_LAUNCH, token, spent, 0, SafeCast.toInt256(tokensOut), cost, periodId);
    }

    /// @inheritdoc IAgentAccount
    function claimFees() external nonReentrant returns (uint256 claimed) {
        (, uint64 periodId) = REGISTRY.authorize(msg.sender, P_CLAIM, block.timestamp);
        uint256 balBefore = address(this).balance;
        FEE_MANAGER.claim(address(this));
        claimed = (address(this).balance - balBefore) / SCALE;
        emit AgentAction(msg.sender, ACTION_CLAIM, address(0), 0, claimed, 0, 0, periodId);
    }

    /// @inheritdoc IAgentAccount
    function sweepToOwner(address token, uint256 amount) external nonReentrant {
        (, uint64 periodId) = REGISTRY.authorize(msg.sender, P_SWEEP_TO_OWNER, block.timestamp);
        if (amount == 0) revert ZeroAmount();
        if (token != address(0)) _curve(token);
        _send(owner(), token, amount);
        emit AgentAction(msg.sender, ACTION_SWEEP, token, 0, 0, -SafeCast.toInt256(amount), 0, periodId);
    }

    // ------------------------------------------------------------------ withdrawals

    /// @inheritdoc IAgentAccount
    function withdraw(address token, uint256 amount) external nonReentrant {
        _send(_checkOwner(), token, amount);
    }

    /// @inheritdoc IAgentAccount
    function withdrawMany(address[] calldata tokens) external nonReentrant {
        address to = _checkOwner();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
            if (amount != 0) _send(to, token, amount);
        }
    }

    /// @notice Never accepts a signature: agent accounts sign nothing in this version.
    /// @dev Always `0xffffffff`. Arc's USDC accepts contract signatures in the `bytes` forms of `permit` and
    ///      `transferWithAuthorization`, so returning the magic value would open a withdrawal path.
    /// @param hash Ignored.
    /// @param signature Ignored.
    /// @return magicValue Always `0xffffffff`.
    function isValidSignature(bytes32 hash, bytes memory signature) external pure returns (bytes4 magicValue) {
        hash;
        signature;
        return 0xffffffff;
    }

    // ------------------------------------------------------------------ internals

    /// @dev Adds a measured buy to `token`'s basis and raises its high-water average to the new average if higher.
    ///      Used by every path that records a purchase (curve buys, launch initial buys, pool buys).
    /// @param token The token.
    /// @param spent USDC spent, usdc6.
    /// @param tokensIn Tokens received, 18-decimal units; non-zero.
    function _addBasis(address token, uint256 spent, uint256 tokensIn) private {
        Basis storage b = _basis[token];
        uint256 cost = b.costUsdc + spent;
        uint256 tokens = b.tokens + tokensIn;
        b.costUsdc = SafeCast.toUint128(cost);
        b.tokens = SafeCast.toUint128(tokens);
        uint256 avg = Math.mulDiv(cost, HIGH_WATER_SCALE, tokens, Math.Rounding.Ceil);
        if (avg > b.highWater) b.highWater = avg;
    }

    /// @dev The cost-basis value of `recorded` recorded tokens (at most `b.tokens`): the higher of the pro-rata cost
    ///      (rounded up) and the high-water value (rounded down: the stored high-water is already rounded up), so a
    ///      cheap buy after a crash cannot dilute earlier holdings and a whole single-lot position is charged exactly
    ///      its cost. Shared by curve and pool sells.
    /// @param b The basis as loaded.
    /// @param recorded Recorded tokens sold, 18-decimal units.
    /// @return value usdc6.
    function _recordedValue(Basis memory b, uint256 recorded) private pure returns (uint256 value) {
        if (recorded == 0) return 0;
        value = Math.mulDiv(recorded, b.costUsdc, b.tokens, Math.Rounding.Ceil);
        uint256 hwValue = Math.mulDiv(recorded, b.highWater, HIGH_WATER_SCALE);
        if (hwValue > value) value = hwValue;
    }

    /// @dev Swaps exactly `amountIn` of `input` for `output` in the pool `key` through the Universal Router, then
    ///      asserts both transient allowances are zero and the pool price moved at most `maxImpactBps`.
    /// @param key The derived Launch pool key.
    /// @param input Input currency (USDC or the token).
    /// @param output Output currency.
    /// @param amountIn Exact input, in `input`'s ERC-20 units; at most `type(uint128).max`.
    /// @param minOut Minimum output, in `output`'s ERC-20 units; at most `type(uint128).max`.
    /// @param deadline The router's deadline, Unix seconds.
    /// @param maxImpactBps `maxPriceImpactBps`.
    function _poolSwap(
        PoolKey memory key,
        address input,
        address output,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        uint256 maxImpactBps
    ) private {
        PoolId id = key.toId();
        (uint160 sqrtBefore,,,) = POOL_MANAGER.getSlot0(id);
        IERC20(input).forceApprove(PERMIT2, amountIn);
        IAllowanceTransfer(PERMIT2).approve(input, UNIVERSAL_ROUTER, uint160(amountIn), uint48(block.timestamp));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams(
                key,
                input == Currency.unwrap(key.currency0),
                uint128(amountIn),
                uint128(minOut),
                0,
                abi.encode(address(this))
            )
        );
        params[1] = abi.encode(input, amountIn);
        params[2] = abi.encode(output, minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(V4_ACTIONS, params);
        IUniversalRouterExecute(UNIVERSAL_ROUTER).execute(V4_SWAP_COMMAND, inputs, deadline);

        if (IERC20(input).allowance(address(this), PERMIT2) != 0) revert AllowanceNotCleared();
        (uint160 left,,) = IAllowanceTransfer(PERMIT2).allowance(address(this), input, UNIVERSAL_ROUTER);
        if (left != 0) revert AllowanceNotCleared();
        (uint160 sqrtAfter,,,) = POOL_MANAGER.getSlot0(id);
        _checkImpact(AgentPolicyLib.poolImpactBps(sqrtBefore, sqrtAfter), maxImpactBps);
    }

    /// @dev Removes `cut` recorded tokens (at most `b.tokens`) and their pro-rata cost, rounded down so the
    ///      remaining average never falls. Closing the position clears cost and high-water.
    /// @param token The token.
    /// @param b The basis as loaded (memory copy).
    /// @param cut Recorded tokens to remove, 18-decimal units.
    function _cutBasis(address token, Basis memory b, uint256 cut) private {
        if (cut >= b.tokens) {
            delete _basis[token];
            return;
        }
        b.costUsdc -= uint128(Math.mulDiv(b.costUsdc, cut, b.tokens));
        b.tokens -= uint128(cut);
        _basis[token] = b;
    }

    /// @dev Reverts `NotOwner` unless the caller is the account's owner in the registry.
    /// @return The owner.
    function _checkOwner() private view returns (address) {
        address o = owner();
        if (msg.sender != o) revert NotOwner();
        return o;
    }

    /// @dev The registered curve of `token`; reverts `TokenNotRegistered` when the Launch factory has none.
    /// @param token The token.
    /// @return The curve.
    function _curve(address token) private view returns (BondingCurve) {
        address c = LAUNCH_FACTORY.curveOf(token);
        if (c == address(0)) revert TokenNotRegistered();
        return BondingCurve(c);
    }

    /// @dev A usdc6 amount as native wei; reverts `AmountTooLarge` instead of overflowing.
    /// @param usdc6 Amount, usdc6.
    /// @return Native wei (18 decimals).
    function _toWei(uint256 usdc6) private pure returns (uint256) {
        if (usdc6 > type(uint256).max / SCALE) revert AmountTooLarge();
        return usdc6 * SCALE;
    }

    /// @dev Reverts `PriceImpactTooHigh(bps)` when `bps > max`.
    /// @param bps The trade's impact, basis points.
    /// @param max `maxPriceImpactBps`.
    function _checkImpact(uint256 bps, uint256 max) private pure {
        if (bps > max) revert PriceImpactTooHigh(bps);
    }

    /// @dev Sends `amount` of `token` (zero: native wei) to `to`, the owner, and emits `AccountWithdrawn`.
    /// @param to The owner.
    /// @param token The token, or zero for native USDC.
    /// @param amount Native wei (18 decimals) for zero, else the token's own units.
    function _send(address to, address token, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            Basis memory b = _basis[token];
            if (b.tokens != 0) {
                // Cut the recording pro rata to the share of the balance withdrawn (tokens rounded up). An amount
                // above the balance makes the cut whole and the transfer below revert.
                uint256 bal = IERC20(token).balanceOf(address(this));
                _cutBasis(token, b, bal == 0 ? b.tokens : Math.mulDiv(b.tokens, amount, bal, Math.Rounding.Ceil));
            }
            IERC20(token).safeTransfer(to, amount);
        }
        emit AccountWithdrawn(token, amount);
    }
}
