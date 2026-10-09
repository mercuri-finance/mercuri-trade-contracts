// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILaunchFactory} from "@mercuri/launch/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {IGraduationManager} from "@mercuri/launch/interfaces/IGraduationManager.sol";
import {IAgentPolicyRegistry} from "./IAgentPolicyRegistry.sol";

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
    /// @param token The Launch token traded.
    /// @param usdcSpent USDC that left the account, usdc6: the native balance delta rounded up (refunds netted).
    /// @param usdcReceived USDC that entered the account, usdc6: the native balance delta rounded down.
    /// @param tokenDelta Change in the account's balance of `token`, 18-decimal units (positive on a buy).
    /// @param basisValue usdc6. A buy: the cost added to the basis (equals `usdcSpent`). A sell: the cost-basis value
    ///        charged to `maxTradeUsdc` and `periodSellCap`.
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
    /// @notice The account's recorded cost basis in `token`.
    /// @param token The token.
    /// @return costUsdc USDC paid for the recorded tokens, usdc6.
    /// @return tokens Recorded tokens, 18-decimal units.
    function basis(address token) external view returns (uint128 costUsdc, uint128 tokens);

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
    ///      `ceil(min(tokensIn, basis.tokens) * cost / tokens)` plus, for tokens beyond the recorded amount, their
    ///      pre-trade `quoteSell` proceeds rounded up to usdc6. It is checked against `maxTradeUsdc` here and
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

    /// @notice Sends `amount` of a token, or native USDC, to the owner.
    /// @dev Owner only (read from the registry); works while agents are paused, by the owner or the factory.
    /// @param token The token, or zero for native USDC.
    /// @param amount Native wei (18 decimals) for zero, else the token's own units.
    function withdraw(address token, uint256 amount) external;
    /// @notice Sends the full balance of each listed token, or of native USDC for zero, to the owner.
    /// @dev Owner only. Zero balances are skipped, so repeats are harmless.
    /// @param tokens Tokens to empty; zero means native USDC.
    function withdrawMany(address[] calldata tokens) external;
}
