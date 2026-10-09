// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILaunchFactory} from "@mercuri/launch/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {IGraduationManager} from "@mercuri/launch/interfaces/IGraduationManager.sol";
import {IAgentPolicyRegistry} from "./IAgentPolicyRegistry.sol";
import {LaunchRequest} from "../AgentTypes.sol";

/// @notice A Mercurifi agent account: a per-user vault whose agent keys trade Launch tokens within owner-set caps and
///         can never withdraw. Each account is an EIP-1167 clone of one immutable implementation. It holds the funds,
///         the cost basis and the typed trade functions; its owner, policy, agents, queue and usage live in the
///         factory's `AgentPolicyRegistry`, where the owner manages it.
interface IAgentAccount is IERC1271 {
    /// @notice Assets left the account to the owner.
    /// @param token The token, or zero for native USDC.
    /// @param amount Amount sent: native wei (18 decimals) for zero, else the token's own units.
    event AccountWithdrawn(address indexed token, uint256 amount);
    /// @notice An agent acted through the account. The authoritative attribution record: the log's address is the
    ///         account.
    /// @param agent The agent key that sent the transaction.
    /// @param action `ACTION_*` id.
    /// @param token The Launch token traded, launched or swept; zero for a claim or a native sweep.
    /// @param usdcSpent USDC that left the account, usdc6: the native balance delta rounded up (refunds netted;
    ///        a launch includes its fee). Zero for a claim or sweep.
    /// @param usdcReceived USDC that entered the account, usdc6: the native balance delta rounded down.
    /// @param tokenDelta Change in the account's balance of `token`, 18-decimal units (positive on a buy). A sweep:
    ///        minus the amount sent; a native sweep is encoded as `token = 0` and `tokenDelta = -wei` (native wei,
    ///        18 decimals).
    /// @param basisValue usdc6. A buy (curve or pool): the cost added to the basis (equals `usdcSpent`). A launch:
    ///        the cost added to the basis (`usdcSpent` minus the fee, zero without an initial buy). A sell (curve or
    ///        pool): the value charged to `maxTradeUsdc` and `periodSellCap`. Zero for a claim or sweep.
    /// @param periodId `block.timestamp / periodSeconds` of the period charged.
    event AgentAction(
        address indexed agent,
        uint8 action,
        address indexed token,
        uint256 usdcSpent,
        uint256 usdcReceived,
        int256 tokenDelta,
        uint256 basisValue,
        uint64 periodId
    );

    /// @notice A constructor dependency is the zero address.
    error ZeroAddress();
    /// @notice Only the factory may initialise an account.
    error NotFactory();
    /// @notice The account, or the implementation itself, is already initialised.
    error AlreadyInitialized();
    /// @notice The referrer is the account itself, which the FeeManager would refuse.
    error SelfReferrer();
    /// @notice Only the owner may call this.
    error NotOwner();
    /// @notice Sending native USDC to the owner failed.
    error NativeTransferFailed();
    /// @notice The token has no curve in the Launch factory's registry.
    error TokenNotRegistered();
    /// @notice `allowlistOnly` is set and the token is not allowlisted (buys only).
    error TokenNotAllowed();
    /// @notice The curve is younger than `minTokenAgeBlocks`.
    error TokenTooNew();
    /// @notice The curve's snipe tax is above `maxSnipeBps`.
    /// @param current The current snipe tax, basis points.
    error SnipeTaxTooHigh(uint256 current);
    /// @notice The trade's own price impact is above `maxPriceImpactBps`.
    /// @param bps The quoted impact, basis points, rounded up.
    error PriceImpactTooHigh(uint256 bps);
    /// @notice The agent's minimum output is zero.
    error ZeroMinOut();
    /// @notice The trade's input amount is zero.
    error ZeroAmount();
    /// @notice A usdc6 amount is too large to convert to native wei (times 1e12) without overflow.
    error AmountTooLarge();
    /// @notice The trade's value is above `maxTradeUsdc`.
    /// @param max `maxTradeUsdc`, usdc6.
    error TradeTooLarge(uint256 max);
    /// @notice The curve is not in a phase that allows this trade (graduated, or pending for a buy).
    error NotTrading();
    /// @notice The quote gives zero output.
    error ZeroOutput();
    /// @notice An allowance the account granted for the trade survived it.
    error AllowanceNotCleared();
    /// @notice The token's curve has not graduated, so it has no Launch pool to swap in.
    error NotGraduated();
    /// @notice The GraduationManager's pool key for the token does not use the LaunchHook or does not pair the token
    ///         with USDC.
    error UnexpectedPool();
    /// @notice A pool swap took more than `amountIn` or paid less than `minAmountOut`, measured from balance deltas.
    error UnexpectedSwapDelta();

    /// @notice Binds the referrer of a fresh clone. The registry already holds its owner, policy and agents.
    /// @dev Callable only by `FACTORY`, once, inside `createAccount`. Binds a non-zero referrer in the FeeManager.
    /// @param referrer_ The referrer, or zero for none; never the account itself.
    function initialize(address referrer_) external;

    /// @notice Factory that alone may initialise accounts of this implementation.
    /// @return The AgentAccountFactory address.
    function FACTORY() external view returns (address);
    /// @notice Registry holding this account's owner, policy, agents, queue and usage.
    /// @return The AgentPolicyRegistry of `FACTORY`.
    function REGISTRY() external view returns (IAgentPolicyRegistry);
    /// @notice Launch factory whose `curveOf` registry decides which curves are genuine.
    /// @return The LaunchFactory proxy.
    function LAUNCH_FACTORY() external view returns (ILaunchFactory);
    /// @notice Launch FeeManager that holds the referrer binding and the account's creator fees.
    /// @return The FeeManager proxy.
    function FEE_MANAGER() external view returns (IFeeManager);
    /// @notice Launch GraduationManager that names each graduated token's pool.
    /// @return The GraduationManager proxy.
    function GRADUATION_MANAGER() external view returns (IGraduationManager);
    /// @notice The only hook a pool swap may go through.
    /// @return The LaunchHook address.
    function LAUNCH_HOOK() external view returns (address);
    /// @notice Uniswap v4 PoolManager of graduated pools.
    /// @return The PoolManager address.
    function POOL_MANAGER() external view returns (IPoolManager);
    /// @notice Universal Router used for pool swaps.
    /// @return The router address.
    function UNIVERSAL_ROUTER() external view returns (address);
    /// @notice Permit2 used to approve the router for one swap at a time.
    /// @return The Permit2 address.
    function PERMIT2() external view returns (address);
    /// @notice Arc's native USDC, whose ERC-20 view has 6 decimals.
    /// @return The USDC address.
    function USDC() external view returns (address);

    /// @notice The account's owner, read from the registry; the only recipient of withdrawals.
    /// @return The owner address; zero on the implementation.
    function owner() external view returns (address);
    /// @notice The referrer bound in the FeeManager at creation, fixed for life.
    /// @return The referrer, or zero for none.
    function referrer() external view returns (address);
    /// @notice The account's recorded cost basis in `token`. Only tokens the account bought are recorded; an owner
    ///         withdrawal cuts the recording pro rata, so tokens that come back later are unrecorded.
    /// @param token The token.
    /// @return costUsdc USDC paid for the recorded tokens, usdc6.
    /// @return tokens Recorded tokens, 18-decimal units.
    /// @return highWater Highest average cost of the open position after any buy, usdc6 per token unit times 1e36;
    ///         zero once the position is closed.
    function basis(address token) external view returns (uint128 costUsdc, uint128 tokens, uint256 highWater);

    /// @notice Buys `token` on its Launch curve with native USDC, within the policy's caps. Agent only (`P_BUY`).
    /// @dev Lock, then the registry's `authorize` (pauses, agent, deadline, period, action count); then
    ///      registration, phase `Trading`, allowlist, token age, snipe tax, `0 < usdcIn <= maxTradeUsdc`,
    ///      `minTokensOut > 0` and the price impact of the quote. Sends `usdcIn * 1e12` wei with the account's
    ///      referrer. The spend is the measured native balance delta rounded up to usdc6 (a refund from the final buy
    ///      is netted), checked after the call against `maxTradeUsdc` here and the period and per-token caps in the
    ///      registry's `record`, so any breach reverts the whole call. A buy that sells the curve out graduates it
    ///      inline and needs about 2.5M gas.
    /// @param token The Launch token.
    /// @param usdcIn USDC to offer, usdc6.
    /// @param minTokensOut Minimum tokens, 18-decimal units; not zero.
    /// @param deadline Latest Unix time (seconds), within `maxDeadlineSeconds` of now.
    /// @return tokensOut Tokens received, 18-decimal units, measured as the balance delta.
    function buy(address token, uint256 usdcIn, uint256 minTokensOut, uint256 deadline)
        external
        returns (uint256 tokensOut);
    /// @notice Sells `token` back to its Launch curve, within the policy's caps. Agent only (`P_SELL`).
    /// @dev Phase `Trading` or `GraduationPending`. The trade's value is its cost basis: the recorded share
    ///      `recorded = min(tokensIn, basis.tokens)` valued at `max(ceil(recorded * cost / tokens),
    ///      floor(recorded * highWater / 1e36))`, so buying cheaply after a crash cannot dilute the value of earlier
    ///      holdings and a whole single-lot position is charged exactly its cost; plus,
    ///      for tokens beyond the recorded amount, their pre-trade `quoteSell` proceeds rounded up to usdc6. Tokens
    ///      the account did not buy (transfers in, or tokens back after an owner withdrawal) are valued only by that
    ///      quote, which an attacker can move, so they are not protected by the sell cap. A recorded dust remainder
    ///      that quotes below 1 usdc6 cannot be sold alone and keeps the position's high-water until the owner
    ///      withdraws it or a final sell includes the dust. It is checked against `maxTradeUsdc` here and
    ///      `periodSellCap` in the registry. Proceeds (native delta rounded down to usdc6) never create headroom.
    ///      The allowance granted to the curve must be zero afterwards. The allowlist does not apply to sells.
    ///      `minUsdcOut` above `type(uint256).max / 1e12` reverts `AmountTooLarge`.
    /// @param token The Launch token.
    /// @param tokensIn Tokens to sell, 18-decimal units.
    /// @param minUsdcOut Minimum proceeds, usdc6; not zero.
    /// @param deadline Latest Unix time (seconds), within `maxDeadlineSeconds` of now.
    /// @return usdcOut Proceeds, usdc6, rounded down.
    function sell(address token, uint256 tokensIn, uint256 minUsdcOut, uint256 deadline)
        external
        returns (uint256 usdcOut);

    /// @notice Swaps exactly `amountIn` through the token's graduated Launch pool on the Universal Router, within the
    ///         policy's caps. Agent only (`P_POOL_SWAP`).
    /// @dev Lock, then `authorize`; then registration, phase `Graduated` (`NotGraduated`), `amountIn > 0`
    ///      (`ZeroAmount`), `minAmountOut > 0` (`ZeroMinOut`) and both at most `type(uint128).max`
    ///      (`AmountTooLarge`). The pool key is always `GraduationManager.poolKey(token)`, asserted to use `LAUNCH_HOOK`
    ///      and to pair the token with USDC (`UnexpectedPool`); the agent cannot name a pool. The account approves
    ///      Permit2 for exactly `amountIn` of the input and Permit2 the router for `uint160(amountIn)` expiring this
    ///      block, then calls `execute(0x10, [actions 0x06 0x0c 0x0f], deadline)` (V4_SWAP with the allow-revert bit
    ///      clear: SWAP_EXACT_IN_SINGLE with `minHopPriceX36 = 0` and `hookData = abi.encode(address(this))` so the
    ///      LaunchHook attributes the fee to the account, SETTLE_ALL capped at `amountIn`, TAKE_ALL at least
    ///      `minAmountOut`). Afterwards both allowances must be zero (`AllowanceNotCleared`), the input taken must be
    ///      at most `amountIn` and the output at least `minAmountOut` (`UnexpectedSwapDelta`), and the move of the
    ///      pool price from `sqrtPriceX96` before and after, `|(after / before)^2 - 1|` in basis points rounded down,
    ///      at most `maxPriceImpactBps`. That limits the size of this swap only, not a price moved earlier.
    ///      Buy (`buyToken`): `amountIn` is usdc6, the allowlist applies and `amountIn <= maxTradeUsdc`. The spend is
    ///      the native balance delta rounded up to usdc6 (Arc's USDC ERC-20 view moves the native balance), charged to
    ///      the period and per-token caps and added to the basis with the measured token delta.
    ///      Sell: `amountIn` is 18-decimal tokens and `minAmountOut` usdc6. The value charged to `maxTradeUsdc` and
    ///      `periodSellCap` is the cost basis exactly as for curve sells for the recorded share; tokens beyond the
    ///      recorded amount are valued at their pro-rata share of the measured proceeds, rounded up. That share is a
    ///      weaker bound than a quote taken before the swap: it is what a moved pool actually paid. Proceeds (native
    ///      delta rounded down) never create headroom. Never sized from `minAmountOut`.
    /// @param token The Launch token of the pool.
    /// @param buyToken True to buy the token with USDC, false to sell it for USDC.
    /// @param amountIn Exact input: usdc6 on a buy, 18-decimal tokens on a sell.
    /// @param minAmountOut Minimum output: 18-decimal tokens on a buy, usdc6 on a sell; not zero.
    /// @param deadline Latest Unix time (seconds), within `maxDeadlineSeconds` of now; also the router's deadline.
    /// @return amountOut Output received: 18-decimal tokens on a buy, usdc6 (rounded down) on a sell.
    function swapExactIn(address token, bool buyToken, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 amountOut);

    /// @notice Launches a new Launch token with the account as creator and, optionally, an initial buy into the
    ///         account, within the policy's caps. Agent only (`P_LAUNCH`).
    /// @dev Lock, then the registry's `authorize` with `r.deadline`, which must lie in `[now, now +
    ///      maxDeadlineSeconds]` like a trade's, so a held or replayed launch expires. Calls `LaunchFactory.createToken`
    ///      with `creator = address(this)`, `referrer` = the account's stored referrer and `value = launchFee +
    ///      initialBuyUsdc * 1e12`, `launchFee` read from `LaunchFactory.config()`. The factory reverts
    ///      `ConfigChanged` unless `expectedConfigHash` matches, so the fee paid is the fee quoted. The spend is the
    ///      measured native balance delta rounded up to usdc6 (fee included); `ceil(launchFee / 1e12) +
    ///      initialBuyUsdc` and the measured spend must be at most `maxTradeUsdc`, and the spend counts toward the
    ///      period spend cap, the new token's per-token cap and `launchesPerPeriod` in the registry's `record`. The
    ///      initial-buy tokens are recorded in the basis at cost `spent - ceil(launchFee / 1e12)` (never negative)
    ///      and raise the high-water like a buy. `allowlistOnly` governs buys of existing tokens and does not apply here,
    ///      nor do the token age and snipe limits; an owner who wants no agent launches withholds `P_LAUNCH`.
    /// @param r The launch request; amounts usdc6 and 18-decimal tokens.
    /// @return token The new token.
    /// @return curve Its bonding curve.
    function launch(LaunchRequest calldata r) external returns (address token, address curve);
    /// @notice Claims the account's creator and referral fees from the FeeManager into the account. Agent only
    ///         (`P_CLAIM`).
    /// @dev Lock, then `authorize` (counts one action). Calls `FeeManager.claim(address(this))` only, so fees can
    ///      reach nowhere but the account; reverts `NothingToClaim` from the FeeManager when nothing is owed. No
    ///      spend or sell cap is charged.
    /// @return claimed Native USDC received, usdc6, the balance delta rounded down (every wei stays in the account).
    function claimFees() external returns (uint256 claimed);
    /// @notice Sends `amount` of native USDC or of a registered Launch token to the owner. Agent only
    ///         (`P_SWEEP_TO_OWNER`).
    /// @dev Lock, then `authorize` (counts one action). The recipient is always the owner read from the registry.
    ///      A non-zero `token` must have a Launch curve (`TokenNotRegistered`), and its recorded basis is cut pro rata
    ///      exactly as an owner `withdraw`. Emits `AccountWithdrawn` and `AgentAction` with `tokenDelta = -amount`
    ///      (native wei when `token` is zero). No spend or sell cap is charged. Reverts `ZeroAmount` for zero.
    /// @param token A registered Launch token, or zero for native USDC.
    /// @param amount Native wei (18 decimals) for zero, else 18-decimal token units.
    function sweepToOwner(address token, uint256 amount) external;

    /// @notice Sends `amount` of a token, or native USDC, to the owner.
    /// @dev Owner only (read from the registry); works while agents are paused, by the owner or the factory. For a
    ///      token with a recorded basis, the recording is cut pro rata to `amount / balance` (tokens rounded up,
    ///      cost rounded down; the high-water stays unless the position closes), so tokens sent back later are
    ///      unrecorded.
    /// @param token The token, or zero for native USDC.
    /// @param amount Native wei (18 decimals) for zero, else the token's own units.
    function withdraw(address token, uint256 amount) external;
    /// @notice Sends the full balance of each listed token, or of native USDC for zero, to the owner.
    /// @dev Owner only. Zero balances are skipped, so repeats are harmless. Emptying a token clears its basis.
    /// @param tokens Tokens to empty; zero means native USDC.
    function withdrawMany(address[] calldata tokens) external;
}
