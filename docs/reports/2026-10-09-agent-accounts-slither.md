# Agent accounts: Slither triage

Code candidate `6a559b3db594fe34b2a10a4ca8ec196bba4905f1` (branch `feat/agent-accounts`); `src/` is identical at every
later commit of the branch up to this report. Slither **0.11.3**, 100 detectors, run per target file by
[`script/run-slither.sh`](../../script/run-slither.sh) (results in `lib/` filtered out). Whole-repository mode is not
usable here: several vendored dependencies declare a contract named `ERC20` and Slither stops with
`Type not found contract ERC20`.

| Target | Contracts analysed | Results |
| --- | --- | --- |
| `src/agents/AgentAccount.sol` | 84 | 50 |
| `src/agents/AgentAccountFactory.sol` (compiles `AgentPolicyRegistry`, which its constructor deploys) | 29 | 37 |
| **Total** | | **87** |

**Verdict: 87 results, 0 true positives.** No result calls for a code change. The script fails when the per-target,
per-detector counts differ from this triage, so a new result must be triaged here before the evidence is updated.
Matches the independent final review's ad hoc run of the same version at `c8c6485` (same 87 results, line for line).

Classes used below: **FP** false positive (the pattern is not present or cannot be reached as described);
**By design** the pattern is present and intended, with the reason; **Style** naming or complexity only.

## AgentAccount.sol (50)

| # | Detector | Location | Class | Reason |
| --- | --- | --- | --- | --- |
| 1 | arbitrary-send-eth | `buy`: `curve.buy{value}` | FP | `curve` is `LaunchFactory.curveOf(token)`, a registered Launch curve, never an agent-supplied address; the value is the capped trade amount, measured afterwards and charged to the period caps. |
| 2 | arbitrary-send-eth | `launch`: `createToken{value}` | FP | The recipient is the immutable `LAUNCH_FACTORY`; the value is the launch fee plus the capped initial buy, both checked against `maxTradeUsdc` first. |
| 3 | arbitrary-send-eth | `_send`: `to.call{value}` | FP | `to` is always the account's owner (`_checkOwner()` for `withdraw`/`withdrawMany`, `owner()` for `sweepToOwner`). |
| 4 | incorrect-equality | `_recordedValue`: `recorded == 0` | FP | An early return for zero recorded tokens; no balance an attacker can move is compared. |
| 5 | incorrect-equality | `_send`: `bal == 0` | By design | Only chooses a whole cut of the recorded basis when the account holds none of the token; the transfer then reverts for any non-zero amount. A donation can only make `bal` larger, which shrinks the cut pro rata and is the intended valuation of tokens from outside (section 2). |
| 6 | reentrancy-no-eth | `sell`: `_cutBasis` after `curve.sell` and `REGISTRY.record` | FP | Every agent and owner function of the account is `nonReentrant` (one lock); the curve is a registered Launch curve; the registry is the immutable singleton. Only the `basis(address)` view could observe the pre-sell basis mid-call, and nothing on chain consumes it. |
| 7 | reentrancy-no-eth | `swapExactIn` (sell side): `_cutBasis` after the router call and `record` | FP | As 6; the router and Permit2 are immutables, with account-built calldata and allowances asserted zero afterwards. |
| 8 | uninitialized-local | `launch`: `cost` | By design | Zero by default on purpose: a launch with no initial buy records no basis and emits `cost = 0`. |
| 9 | unused-return | `buy`: `curve.buy(...)` | By design | Tokens received are measured as the balance delta, the source of truth for the basis, not the curve's return value. |
| 10 | unused-return | `sell`: `curve.quoteSell(excess)` second value | By design | Only the proceeds are needed to value tokens from outside; the fee is not. |
| 11 | unused-return | `sell`: `curve.sell(...)` | By design | Proceeds are measured as the native balance delta. |
| 12 | unused-return | `claimFees`: `authorize` policy | By design | A claim needs only the authorisation and the period id; no policy field applies. |
| 13 | unused-return | `claimFees`: `FEE_MANAGER.claim` | By design | The amount claimed is measured as the balance delta. |
| 14 | unused-return | `sweepToOwner`: `authorize` policy | By design | As 12. |
| 15 | unused-return | `_poolSwap`: `getSlot0` (before) other fields | By design | Only `sqrtPriceX96` is used for the impact measure. |
| 16 | unused-return | `_poolSwap`: Permit2 `allowance` other fields | By design | Only the amount is asserted zero; expiry and nonce are irrelevant. |
| 17 | unused-return | `_poolSwap`: `getSlot0` (after) other fields | By design | As 15. |
| 18 | shadowing-local | `IAgentPolicyRegistry.authorize` parameter `agent` shadows `agent(address,address)` | Style | Interface parameter name only; no code reads it. |
| 19 | calls-loop | `_send`: `to.call{value}` in `withdrawMany` | By design | Owner-only exit; one native send per call at most worth sending (the owner), so a failing call only reverts the owner's own transaction. Chunked at 100 tokens by the SDK (section 6). |
| 20 | calls-loop | `_send`: `balanceOf` in `withdrawMany` | By design | As 19; the token list is the owner's, no on-chain list a stolen key could grow. |
| 21 | calls-loop | `withdrawMany`: `balanceOf` | By design | As 20. |
| 22 | reentrancy-benign | `buy`: `_addBasis` after the curve and `record` | FP | As 6; the basis must be written after the measured delta. |
| 23 | reentrancy-benign | `launch`: `_addBasis` after `createToken` and `record` | FP | As 6; the token address is only known after the call. |
| 24 | reentrancy-benign | `swapExactIn` (buy side): `_addBasis` after the router and `record` | FP | As 7. |
| 25 | costly-loop | `_cutBasis`: `delete _basis[token]` in `withdrawMany` | By design | One slot cleared per fully withdrawn token, bounded by the owner's own list; gas measured (200 tokens 7,245,580). |
| 26 | cyclomatic-complexity | `swapExactIn` (16) | Style | Both directions in one typed function on purpose (one permission, one entry); covered by `AgentPool.t.sol` and the fork test. |
| 27 | low-level-calls | `_send`: `to.call{value}` | By design | Native USDC transfer to the owner; the result is checked (`NativeTransferFailed`). |
| 28–37 | naming-convention | Immutables `FACTORY`, `REGISTRY`, `LAUNCH_FACTORY`, `FEE_MANAGER`, `GRADUATION_MANAGER`, `LAUNCH_HOOK`, `POOL_MANAGER`, `UNIVERSAL_ROUTER`, `PERMIT2`, `USDC` | Style | Upper case for immutables is this repository's convention. |
| 38–47 | naming-convention | `IAgentAccount` getters of the same ten immutables | Style | As 28–37. |
| 48 | naming-convention | `IAgentPolicyRegistry.FACTORY()` | Style | As 28–37. |
| 49 | redundant-statements | `isValidSignature`: `hash;` | By design | Silences the unused-parameter warning; the function always returns `0xffffffff`. |
| 50 | redundant-statements | `isValidSignature`: `signature;` | By design | As 49. |

## AgentAccountFactory.sol and AgentPolicyRegistry.sol (37)

| # | Detector | Location | Class | Reason |
| --- | --- | --- | --- | --- |
| 1 | unused-return | `createAccount`: `Clones.cloneDeterministic` | FP | The clone address is predicted first and the return value is the same address; the call reverts on failure and `AccountExists` is checked beforehand. |
| 2 | shadowing-local | `IAgentPolicyRegistry.authorize` parameter `agent` | Style | As account 18. |
| 3 | calls-loop | `AgentPolicyRegistry._applyPolicy`: `factory.ceilings()` from `executeQueued` | FP | The loop in `executeQueued` breaks after the first apply, so the call runs at most once; the factory is the registry's immutable creator. |
| 4 | reentrancy-benign | `createAccount`: `isAccount[account] = true` after `register` and `initialize` | FP | Both calls go to code the factory itself deployed (its registry and the fresh clone of the immutable implementation), each accepting only the factory as caller; the clone's `initialize` also binds the referrer at Launch's FeeManager. Nothing on that path calls back into the factory, and `register` checks the caller is the factory, not `isAccount`. |
| 5 | reentrancy-events | `createAccount`: `AccountCreated` after the calls | FP | As 4. |
| 6 | timestamp | `AgentAccountFactory.isPaused` | By design | Pause deadlines are wall-clock by spec; a block producer's few seconds of skew cannot matter against 72 h pauses. |
| 7 | timestamp | `guardianPause` (cooldown, never shorten) | By design | As 6. |
| 8 | timestamp | `adminSetPausedUntil` (30-day limit) | By design | As 6. |
| 9 | timestamp | `AgentPolicyRegistry.authorize` (agent expiry, deadline window, action and launch counts in the period) | By design | Expiry, deadlines and periods are wall-clock by spec; seconds of skew are immaterial against periods of 1 h to 7 days and a 600 s maximum deadline. |
| 10 | timestamp | `record` (cap comparisons in the period) | By design | As 9. |
| 11 | timestamp | `_currentUsage` (period roll) | By design | As 9. |
| 12 | timestamp | `_left` | FP | Compares cap and usage only; flagged because it runs in a period context. |
| 13 | timestamp | `_checkWindow` (queue ETA and 7-day expiry) | By design | As 9; the widening delay is at least 1 h. |
| 14 | timestamp | `_checkAgentTerms` (expiry within 180 days) | By design | As 9. |
| 15–24 | naming-convention | Factory immutables `C_MAX_TRADE_USDC` ... `C_MAX_DEADLINE_SECONDS` (the ten beta ceilings) | Style | As account 28–37. |
| 25 | naming-convention | `AgentPolicyRegistry.FACTORY` | Style | As account 28–37. |
| 26–35 | naming-convention | `IAgentAccount` getters (the ten immutables) | Style | As account 28–37. |
| 36 | naming-convention | `IAgentAccountFactory.VERSION()` | Style | As account 28–37. |
| 37 | naming-convention | `IAgentPolicyRegistry.FACTORY()` | Style | As account 28–37. |

## Re-running

```
pip install slither-analyzer==0.11.3   # or set SLITHER to an existing 0.11.3 binary
bash script/run-slither.sh [output-dir]
```

It copies the working tree to a temporary directory (crytic-compile runs `forge clean`), runs both targets offline in
about 15 s, writes text and JSON per target, and exits non-zero when Slither's version or the result counts per
detector differ from the baseline above. `check-contracts.sh` runs it when Slither 0.11.3 is installed and prints a
notice otherwise.
