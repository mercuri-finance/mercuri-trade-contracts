# Mercurifi Agent Accounts: contracts

Status: candidate, **not deployed** on either network. Authoritative design: the agent accounts spec of 9 October 2026
(sections 4, 5, 10 to 12). This page covers what the contracts in [`src/agents/`](../../src/agents) do, what they trust,
what a stolen agent key can lose, what can never change, how users migrate, gas, and the release evidence.

## 1. Architecture

An agent account is a per-user vault from which the user's own bot or AI agent trades Launch tokens within caps the
owner sets. Agent keys can trade; they can never withdraw. The owner can withdraw (only to itself) and manage the
account; the owner has no trade path through the account.

| Contract | Kind | Runtime size | Holds | Role |
| --- | --- | --- | --- | --- |
| `AgentAccount` | Immutable implementation behind EIP-1167 clones (one clone per account) | 15,387 B | Native USDC, Launch tokens, per-token cost basis, the bound referrer | Typed agent trades (`buy`, `sell`, `swapExactIn`, `launch`, `claimFees`, `sweepToOwner`) and owner withdrawals. Builds every external call itself. No generic execute, no delegatecall, no proxy upgrade, no selfdestruct; `isValidSignature` always returns `0xffffffff`; `receive()` is empty. |
| `AgentPolicyRegistry` | Immutable singleton, one per factory, deployed by the factory's constructor | 17,838 B | Every account's owner, policy, agents, widening queue, allowlist, delay, owner pause and period usage | Owner functions (`addAgent`, `setPolicy`, `pauseAgents`, `transferOwnership`, ...), the agent preamble `authorize` and the cap accounting `record`. Only a registered account may call `authorize` or `record`, and only for itself. Emits every configuration event with `account` indexed. No admin, no owner of its own. |
| `AgentAccountFactory` | Immutable | 3,855 B | `isAccount`, the beta ceilings (immutables), the guardian and the pause deadline | `createAccount` (CREATE2 clone with salt `keccak256(abi.encode(owner, salt))`, registry `register`, account `initialize`), `predictAccount`, `ceilings`, the guardian pause. Holds no funds. |

`AgentPolicyLib` (internal library) and `AgentTypes` (structs and constants) are compiled into the contracts above.

Every Launch and Uniswap dependency (LaunchFactory, FeeManager, GraduationManager, LaunchHook, PoolManager, Universal
Router, Permit2, USDC) is a constructor immutable of the implementation, so every clone reads it from the
implementation's code. The implementation's constructor also takes the factory's address and the registry's (the
factory's first CREATE), predicted before either exists; the factory's constructor refuses an implementation that does
not name it and its registry.

Each agent action runs: account lock, registry `authorize` (owner pause, factory pause, active unexpired agent with the
permission, deadline in `[now, now + maxDeadlineSeconds]`, period roll, action count), the account's own checks (genuine
curve from `LaunchFactory.curveOf`, or the GraduationManager's pool key through the LaunchHook, allowlist, snipe and age
limits, per-trade cap, price impact), the trade, the measured native-balance delta (spent rounded up to usdc6,
received rounded down), then registry `record` against the period caps.

## 2. Trust model

- **No admin over accounts.** Nobody but the account's owner can move its funds, and only to the owner. The factory's
  admin cannot touch accounts, policies or funds. There is no upgrade path for the account, the registry or the factory.
- **The registry is immutable** and has no owner; it trusts only its factory (for `register`) and registered accounts
  (for their own `authorize` and `record`).
- **Owner phishing** is slowed, not stopped: every widening (adding an agent, raising a cap, adding an allowlist token,
  lowering the delay, transferring ownership) waits `increaseDelay` (default 1 h, at most 7 days) in a queue that the
  owner can cancel, that a pause cancels, and that expires 7 days after its ETA. Narrowing is immediate.
- **Trusted upgradeable Launch components.** The account trusts Launch's `LaunchFactory.curveOf` registry, FeeManager
  and GraduationManager, which are UUPS proxies behind Launch's TimelockController (48 h delay on mainnet, 60 s on
  testnet). A malicious upgrade there could make an account treat a fake curve or pool as genuine (threat T12). This is
  the same trust every Launch trader already has, and it is the reason the account derives every curve and pool key
  from those contracts at execution time rather than accepting addresses from the agent.
- **Universal Router and Permit2** are used only with account-built calldata, exact transient approvals that must be
  zero after the call, and a post-trade balance check.
- **Tokens received from outside** (airdrops, transfers in, tokens beyond the recorded amount) have no cost basis and
  are valued by their pre-trade curve quote, or by the measured proceeds on a pool. An attacker can move that value, so
  holdings received from outside are not protected by the sell cap and should be withdrawn.

## 3. Loss bound, stated honestly

For a stolen agent key, per period (`periodSeconds`, fixed at creation, 1 h to 7 days):

- at most `periodSpendCap` of USDC spent on bad buys (curve buys, launch fees and initial buys, pool buys), and at
  most `perTokenPeriodCap` of it on any one token;
- plus holdings worth at most `periodSellCap` **valued at what the account paid** (the per-token average cost, or its
  high-water average if higher), sold badly;
- every single action is also capped at `maxTradeUsdc`.

Periods are fixed windows, so a key can spend **2x every period cap across a boundary** (the end of one period and the
start of the next). The total **keeps accruing period after period until the key is revoked, expires, or agents are
paused** by the owner or the guardian. Sell proceeds and fee claims never create headroom. With the spec defaults
(100 / 500 / 100 / 500 USDC, one-day period) a stolen key costs at most 500 USDC of bad buys plus 500 USDC of holdings
at cost per day, 1,000 + 1,000 across a day boundary. With the beta ceilings (1,000 / 10,000 / 2,000 / 10,000) the
corresponding bound is 10,000 + 10,000 per period, 20,000 + 20,000 across a boundary.

The price-impact limit measures the account's own trade from the already-moved price; it is not a sandwich defence.
Against a stolen key the caps are the control.

## 4. What is immutable

| Item | Where | Can change? |
| --- | --- | --- |
| Account, registry and factory code | all three | Never. No proxy, no upgrade, no code rollback. |
| Launch, Uniswap, Permit2 and USDC addresses | implementation immutables | Never (a new implementation and factory). |
| Beta ceilings (spec 4.5: 1,000 / 10,000 / 2,000 / 10,000 USDC; 5,000 actions; 20 launches; 2,000 bps impact; 9,900 bps snipe; 600 s deadline; `minTokenAgeBlocks` floor 0) | factory immutables | Never. Lifting them is a new factory (rollout phase 5). |
| Factory admin (the network's Launch timelock) | factory immutable | Never. |
| Guardian disabled (deployed with guardian zero) | factory immutable | Never; a factory with a guardian can never become guardian-less, and one without can never gain a pause. |
| An account's `periodSeconds` and FeeManager referrer | registry, FeeManager | Never for that account. |
| A retired (revoked) agent address | registry | Never re-addable to that account. |
| Constants: 8 agents, 180-day agent expiry, 7-day queue expiry, 7-day maximum delay, 600 s maximum deadline, 72 h guardian pause and cooldown, 30-day maximum admin extension | `AgentTypes.sol` | Never. |
| The guardian address | factory storage | Only the admin (timelock), never to zero. |
| An account's owner, policy, agents, allowlist and delay | registry storage | Only the owner: narrowing immediately, widening through the delayed queue. |

## 5. Guardian and admin pause powers

- The **guardian** (the Guardian Safe on mainnet, the Launch guardian key on testnet) can call `guardianPause()`: agent
  functions of every account of the factory stop for 72 hours. After a guardian pause ends the guardian must wait 72
  hours before pausing again, counted from the pause's original end even if the admin lifted it early.
- The **admin** (Launch's TimelockController) can lift or shorten any pause at any time, extend an *active* pause to at
  most 30 days from now, and replace the guardian (never with zero). It cannot start a pause.
- The 30 days run from each extension, not from the pause's start. While a pause is active the admin can extend it
  again before it ends, each time to at most 30 days from that moment, so a **rolling extension can keep agents
  paused indefinitely**. Each extension is its own timelock operation (48 h delay on mainnet), publicly queued, and
  owner exits keep working throughout.
- A pause **blocks agent functions only**. Owner withdrawals, `withdrawMany`, revocations, policy tightening and owner
  pause always work.
- A factory deployed with guardian zero has no pause at all, permanently: `guardianPause`, `setGuardian` and
  `adminSetPausedUntil` revert. The shipped manifests set a guardian on both networks (decision D2).

## 6. Migration

Accounts and factory are immutable, so a new version is a new implementation and a new factory (rollout phases 3 to 5).
Users migrate by:

1. pausing agents or revoking every agent key on the old account (immediate);
2. `withdrawMany(tokens)` on the old account, which sends native USDC (token `address(0)`) and every listed token to the
   owner. There is no on-chain token list, so a stolen key cannot make the exit run out of gas; the SDK and indexer
   supply the list. On Arc, chunk it: the SDK sends **100 tokens per transaction**; 200 is the largest proven fit
   (section 7);
3. `createAccount` on the new factory and depositing again.

The old factory keeps working; the web app marks it deprecated. There is no code rollback for any of the three
contracts.

## 7. Arc per-transaction gas cap

Arc enforces a per-transaction gas cap of **16,777,216** (2^24, EIP-7825 style) below the 30,000,000 block gas limit.
Verified read-only on 9 October 2026 against the public testnet RPC `https://rpc.testnet.arc.io` (client `arc/v1`,
chain 5042002, block 66,330,102, hash `0x2f1b9ed710dc92c88396668b8d5acf14b62db306ba27dc91ae2920f8b5363dd0`, gas limit
30,000,000): `eth_estimateGas` with a 50,331,648 gas allowance on a creation call that burns a fixed amount of gas
returned 16,577,103 for a 16.4M-gas loop and refused a 17.1M-gas and a 19.0M-gas loop with `-32003 out of gas: gas
required exceeds: 16777216`. The mainnet value has not been probed (no public mainnet RPC was reachable read-only);
treat it as the same until verified.

Consequences:

- `withdrawMany` of 500 cold tokens costs 18,200,591 gas and does **not** fit in one transaction; 200 tokens cost
  7,245,580 and fit with room to spare. `test_WithdrawManyAfter500DustBuysFitsInABlock` in
  [`AgentAttacks.t.sol`](../../test/agents/AgentAttacks.t.sol) asserts a 200-entry `withdrawMany` runs under a
  16,777,216 gas limit after 500 dust buys by a stolen key. The SDK chunks at 100 tokens per transaction, half the
  proven 200-token fit.
- The deployment is two transactions (implementation, then factory with its registry); together they use about 7.6M
  gas, so each is well under the cap.

## 8. Gas

From the agent gas snapshot ([`.gas-snapshot-agents`](../../.gas-snapshot-agents), checked by the gate) and the gas
logs of the agent tests, local fixture unless stated:

| Operation | Gas |
| --- | --- |
| Direct EOA curve buy (warm token), for comparison | 88,570 |
| Agent curve buy, same size | 131,103 (42,533 overhead) |
| Agent curve sell | 86,360 |
| Agent pool buy through the deployed testnet Universal Router and LaunchHook (fork, first action, cold; measured at `c3771e7`, about 40 gas more since the launch pre-check) | 420,180 |
| Agent pool sell, same pool (fork; measured at `c3771e7`) | 235,013 |
| `createAccount` with referrer binding and a first agent | 353,719 |
| Graduating agent buy, minimum call gas (cold) | 1,254,882 |
| `revokeAgent` | 45,879 |
| `withdrawMany` of 200 tokens / 501 tokens | 7,245,580 / 18,200,591 |
| Deploy implementation and factory (with registry), including the script's checks | 7,614,095 |

`createAccount` is above the spec's 200 to 250k planning figure: since the 9 Oct registry split it writes the full
policy, the first agent and the usage slots into the registry. At Arc gas prices this is a fraction of a cent.

## 9. Deployment

Inputs only, per network: [`deployments/agent-accounts-manifest-5042002.json`](../../deployments/agent-accounts-manifest-5042002.json)
and [`deployments/agent-accounts-manifest-5042.json`](../../deployments/agent-accounts-manifest-5042.json). Launch
addresses come from Launch's deployment record for the chain, the Universal Router and its pinned runtime hash from the
Trade manifest, `admin` is the network's Launch timelock, `guardian` is the record's guardian (the Guardian Safe on
mainnet, the testnet guardian key on testnet), and the ceilings are exactly spec 4.5. No deployed address is in them.

[`script/DeployAgentAccounts.s.sol`](../../script/DeployAgentAccounts.s.sol) checks the manifest against those records
and the beta ceilings, requires code at every dependency and the pinned router runtime (and, on mainnet, a guardian
contract), predicts the implementation, factory and registry addresses from the deployer's nonce, deploys the
implementation and then the factory, and refuses to finish unless all three land where predicted and every immutable
and getter matches the manifest (`EXPECTED_AGENT_FACTORY` optionally pins the factory address). A deployment needs its
own owner go per network (decision D9); no task runs it with `--broadcast`.

After a broadcast, [`script/write-agent-accounts-record.py`](../../script/write-agent-accounts-record.py) writes
`deployments/agent-accounts-<chainId>.json` from forge's completed broadcast file, and only from that: no pending
transaction, exactly the implementation then the factory, both CREATEs from one sender at consecutive nonces with
status-1 receipts, the broadcast's chain and commit matching, the constructor arguments equal to the manifest (the
implementation naming the factory and the factory's first CREATE as registry), each input the built creation code with
those arguments, and the registry created by the factory at its predicted address from the built registry code; the
manifest must first pass the verifier's preflight. It refuses anything else and never overwrites a record: the record is
written to a temporary file and hard-linked into place, which fails if the name exists, so a record written by a
racing run is never replaced. Its `--self-test` (39 cases, in the gate) covers each refusal. No record exists: nothing
has been deployed.

Then `python3 script/verify-agent-accounts.py --rpc <Arc RPC> --block <n> --record deployments/agent-accounts-<chainId>.json`
reads only that record (the writer's file name, key set and version, every input equal to the manifest), refuses a
block before the record's `factoryDeployBlock` (where every runtime is empty), rebuilds the
three runtimes from `out/` with the manifest and record values in every immutable and compares them byte for byte with
`eth_getCode`, checks the registry is the factory's first CREATE, the router's code hash and the factory's guardian;
`--account <addr>` also checks one clone.

## 10. Release evidence

Candidate: branch `feat/agent-accounts` at `6a559b3db594fe34b2a10a4ca8ec196bba4905f1` (contracts, scripts and tests; later commits touching only this page do not change the candidate). Baseline: Launch as pinned in
`lib/mercuri-launch-contracts` at `99d7c28` and its deployment records for 5042002 and 5042; the deployed testnet
Universal Router `0x4fcA…9Fb1` at its pinned runtime hash. Toolchain: forge 1.4.3, solc 0.8.26, Cancun, via-IR, 200
optimizer runs for `src/**`, no metadata hash. Missing evidence is pending, not pass.

| Requirement | Baseline | Candidate | Command or artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Source manifest | `source-manifest.json` listed only the three order sources; at `f292c52` `check-local-source.py` failed because `src/agents/` was unlisted (pre-existing gate failure from Tasks 1 to 6) | All eight `src/agents/` sources listed with sha256 | `python3 script/check-local-source.py` (in gate) | Pass | None |
| NatSpec | Order contracts only (54 entries) | Adds `AgentAccount`, `AgentAccountFactory`, `AgentPolicyRegistry` and their three interfaces; two gaps found and fixed (registry `authorize` `@param agent_`; `isValidSignature` declared in vendored IERC1271 treated as inherited, the account's override still checked). Comment-only: registry runtime byte-identical before and after | `python3 script/check-natspec.py` | Pass, 284 ABI entries, 0 failures | Semantic review of NatSpec is part of the independent review |
| Runtime identity | Filler, validator and reactor only | Every immutable of the implementation (10), factory (14) and registry (1) reconstructed; a flipped byte in each is rejected by name; extra or missing immutables refused; EIP-1167 clone check | `python3 script/verify-agent-accounts.py --self-test`, ten `--self-test-flipped` pairs (in gate) | Pass | Live comparison against a real deployment is pending until a testnet deployment exists |
| Substitution correctness | n/a | Constructor simulations (`eth_call`, no transaction) of the built creation code with the testnet manifest inputs equal the reconstructed runtimes | `python3 script/verify-agent-accounts.py --simulate --block 66330102` against `https://rpc.testnet.arc.io` | MATCH at the previous candidate `c3771e7`: account 15,387 B, factory 3,855 B, registry 17,798 B. Since then the registry gained the launch pre-check (17,838 B); account and factory runtimes are unchanged | Re-run at `6a559b3` (no network was used in the final wave); mainnet simulation pending (no public mainnet RPC reachable) |
| Manifests | n/a | Inputs only (extra keys refused by the script and the preflight; the Trade manifest's chain checked); Launch addresses = Launch records, admin = timelock, guardian = record guardian, router and hash = Trade manifest, ceilings = spec 4.5 | `verify-agent-accounts.py --preflight` for both, a raised-ceiling copy refused (in gate); `DeployAgentAccounts.t.sol` | Pass | Mainnet guardian code check runs only at deploy time (script requires code on 5042) |
| Deploy script | n/a | Predicts implementation, factory and registry from the deployer nonce; full wiring check; wrong chain and missing code refused; tampered manifests refused by field | `test/agents/DeployAgentAccounts.t.sol` (6 tests, in process against the fixture, never broadcast); the fork test runs `run()` against deployed testnet Launch | Pass | Testnet deployment needs an owner go (D9) |
| Deployment record writer | `write-trade-record.py` for the order contracts | `write-agent-accounts-record.py`: writes `agent-accounts-<chainId>.json` only from a completed broadcast and only for a manifest that passes the preflight; links the record into place so an existing or racing record is never overwritten; the verifier's live mode reads only that record and refuses a block before `factoryDeployBlock` | `python3 script/write-agent-accounts-record.py --self-test` (in gate) and the verifier's record self-test | Pass, 39/39 cases | Run against the real broadcast at the testnet deployment. The forge ceilings tuple format of the struct argument was confirmed on a local anvil fork broadcast |
| Behaviour, attack, fuzz, invariant tests | Tasks 1 to 6 suites | 213 agent tests, incl. the final wave's launch pre-check and pause tests | `bash script/check-contracts.sh` (seed `0x5042`); agent suites with seeds `0xe93d4ec5`, `0x0ea0facb`, `0xb711d0ad` | Gate exit 0 in 10 min 8 s: 391 passed, 7 skipped (fork suites without RPC). Each seed: 212 passed, 1 skipped (fork), 0 failed | None |
| Stress | Order suites | Same gate with `--stress`; agent invariants moved out of the 10,000-run step into their own deep campaign (own counterexample directory) | `ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io TRADE_FORK_CHAIN_ID=5042002 bash script/check-contracts.sh --stress` (with `AGENT_INVARIANT_STATS=true` for the ratios) | Exit 0 in 37 min 4 s: fork-suite run 409 passed, 2 skipped; 10,000-run fuzz 397 passed, 2 skipped; order invariants 1,024 x 256; agent invariants 6 passed at 1,024 x 256 (262,144 calls each, 0 reverts, fail-on-revert). Measured at depth 256 over 6,150 runs: successful-step ratio 87.7% (minimum 81.6%), successful account-call ratio 83.3% (minimum 77.3%), against the 60% floor (all at `c3771e7`). At `6a559b3`: the agent invariant campaign alone, 1,024 x 256, seed `0x5042002`, 6 passed (262,144 calls each, 0 reverts, fail-on-revert) in 19 min 44 s; the full `--stress` was not re-run | Full `--stress` at the final candidate before testnet |
| Pinned fork | n/a | Agent pool buy and sell (ERC-20 and Permit2 allowances back to zero; Alchemy URLs refused) through the deployed testnet Universal Router and LaunchHook on graduated token `0x97B4…eE84` at block 65,301,435, account deployed by the production script | `test/agents/AgentPoolFork.t.sol` (skipped without `ARC_LOCAL_FORK_RPC`) | Pass at `c3771e7` (also under each random seed and in stress); not re-run at `6a559b3` (no network) | Re-run at the final candidate. Spec 10's other fork cases (graduating buy, sell during GraduationPending, launch with initial buy, fee claim, blocklisted-owner withdraw) and a mainnet fork are pending for the testnet smoke |
| Gas | n/a | Agent snapshot `.gas-snapshot-agents` (194 entries) | `forge snapshot --check .gas-snapshot-agents ...` (in gate) | Pass | None |
| Size | EIP-170 24,576 B | 15,387 / 3,855 / 17,838 B | `forge build --sizes` | Pass | None |
| Arc per-tx gas cap | Unverified (ruling: likely 16,777,216) | Verified on testnet (section 7) | `eth_estimateGas` probe, block 66,330,102 | 16,777,216 | Mainnet probe pending |
| Upgradeability and storage | n/a | No proxies; nothing to upgrade, no storage layout to preserve | Code review | Not applicable | Documented: no code rollback |
| Static analysis | n/a | Slither named in spec 10 | Not installed in this environment | Pending | Run Slither |
| Independent review and external audit | n/a | Required by spec 10 before testnet and mainnet respectively | n/a | Pending | Both |

## 11. Open gaps (pending before contract readiness)

- Independent internal multi-auditor review of the whole agent contract set, then an external audit before mainnet
  (spec 10). No mainnet deployment with an open finding.
- Live runtime comparison after the testnet deployment (`verify-agent-accounts.py --rpc ... --block ... --record`).
- The remaining spec 10 pinned-fork cases and a mainnet fork; the testnet smoke covers them otherwise.
- Slither.
- Mainnet per-tx gas cap probe and mainnet constructor simulation (no public mainnet RPC reachable read-only on
  9 October 2026).
- Owner decisions D1 to D8 were taken at the spec's recommendations; a different choice costs a contract change before
  testnet.
