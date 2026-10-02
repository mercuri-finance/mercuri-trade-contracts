# MercuriOrderFiller release evidence and independent-review packet, 2 Oct 2026

Status: candidate for independent review. This is a report only. No review has been commissioned, no one has been contacted, nothing was broadcast, and no `deployments/5042002.json` exists. Anything not evidenced below is marked PENDING; nothing is marked pass on inference.

The 29 Sep report `docs/reports/2026-09-29-filler-assurance.md` predates the rename of `LocalOrderFiller` to `MercuriOrderFiller` and the changes below; read its findings as describing the former contract, not this candidate.

## 1. Source revision and build identity

| Requirement | Baseline | Candidate | Command / artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Source revision | `d84519d3e451146ef3b53fe32358db226c588ac3` (29 Sep candidate; `LocalOrderFiller`) | branch `orders/late-cosign`, HEAD `25beac0c06967d3fea486147e1d6f1c13ea2c5ca`, clean tree at the gate run, local only (not pushed). This report row was updated in the commit after `25beac0`; no code changed in that commit | `git rev-parse HEAD`, `git status --short` (empty), `git log --oneline d84519d..HEAD` | Commits through `4be3452` as reviewed in this packet (bc4047b rename, d43c0b5 output-token fees, c3371ea invariant reachability, ea78ad8 expiry curve, b794a9c deploy package, 4be3452 deploy guards), then `74cfb76` (local keeper test export, test-only), `c52acb4` (NatSpec on the four custom errors; runtime and creation bytecode unchanged with `bytecode_hash = none`, gas snapshot unchanged) and `25beac0` (verifier reactor function-pointer self-test, script-only) | The final tag/SHA to deploy is PENDING; any further commit invalidates this packet. Revision update (self-funding round): `01d4edb` adds the execution fee (section 15); `48bbf65` is a NatSpec-only fix; later E2 commits are tests, verifier and report only. Final review fix (R39, section 16): `81cd88c` restricts `fill` to the keeper; this report was updated in the commit after `81cd88c` (docs only). Final code HEAD for review: `81cd88c`. Style conformance (section 17): `a59eabb` (filler NatSpec and layout, bytecode byte-identical), `19f5bf4` (scripts), `fcf70c0` (test headers), `cea3257` (docs), then fix round 1 `dfbbf30` (filler NatSpec, bytecode byte-identical), `61d033a` (scripts), `0a95f2a` (docs); this report was updated in the commit after `0a95f2a`. The filler `src/` sha256 is now `f728729cf69616ca3f8ad0c054434fed159f959b7377a3259efa90bc36ddf0ad` (`1b7aa366…4514` at `a59eabb`, `9ce08495…3820` at `81cd88c`) |
| Compiler and settings | solc 0.8.26, cancun, via-IR, optimizer, `bytecode_hash=none`; `src/**` compiled at optimizer_runs 200 | Unchanged except `fs_permissions` gained `read ./deployments` | `foundry.toml`; forge 1.4.3-Homebrew | Same compiler, EVM and optimizer settings as baseline; the only `foundry.toml` diff is the `./deployments` read permission (needed by deploy-script tests) | None |
| Filler runtime size | 7,542 bytes (29 Sep report) | 10,569 bytes (below EIP-170 limit of 24,576) | `script/verify-trade-filler.py --self-test` | 10,602 bytes, keccak `0x0c151c4de9dab6d48929bba85283709a4c26ce01611edb301dc788caace454a5` in the self-test (`81cd88c`, with the keeper-only check); 10,569 bytes at `48dd683` and 9,838 bytes before the execution fee. The fork-rehearsal keccak in section 9 predates the fee and is stale | Growth from 7,542 bytes (+3,027) is not individually attributed; PENDING |
| Filler source hash | recorded for `LocalOrderFiller.sol` | `src/MercuriOrderFiller.sol` sha256 `f728729cf69616ca3f8ad0c054434fed159f959b7377a3259efa90bc36ddf0ad` at `dfbbf30` (the current `source-manifest.json` value; comment and layout only, section 17; `1b7aa366…4514` at `a59eabb`; `9ce084954969d3a876385e7ec278eeb1204bb7dfc5ceeb7d15208577a3b63820` at `81cd88c`; `c0d2ff5e…2116` at `48dd683`; earlier `459538fa742b3d4f1569ea3546a8f6eb9f02220b09d309703cdb9b52f4af24f1` at `c52acb4`, before the execution fee) | `source-manifest.json`, `python3 script/check-local-source.py` | Pass inside gate | None |
| Dependency pins | Launch submodule and vendored closures as of d84519d | Unchanged by this work: `lib/mercuri-launch-contracts` at `99d7c28a19e254e5c1cf0444819ddabae3e9c469`; `lib/uniswapx` = Uniswap/UniswapX `eb7ce077036258b9510b42ad37aa920cf3aaf308` (34-file closure, unchanged sources); `lib/universal-router` = Uniswap/universal-router `999d561c3ad58fb5cab91b602911f3c75591a9c7` (110-file closure); Permit2, v4 and OpenZeppelin as pinned by the Launch submodule | `lib-versions.md`, `git submodule status`, `python3 script/check-trade-sources.py` (inside gate) | Pass inside gate; `git diff d84519d..HEAD --stat` shows no `lib/` change | The `lib-versions.md` sentence calling the reactor and filler "local test deployments" is stale once deployed (deferred minor) |

## 2. Diff since the 29 Sep candidate

`git diff d84519d..HEAD --stat`: 22 files, 1,306 insertions, 52 deletions. Production source is one file: `src/LocalOrderFiller.sol` renamed (78% similarity) to `src/MercuriOrderFiller.sol`, 36 insertions and 13 deletions. The exact diff is reproduced by `git diff d84519d..HEAD -- src` (and `git diff -M d84519d..HEAD -- src` for the rename form); it is not pasted here so the reviewer reads it from the repository at the SHA above.

| Source change | Where | Reason | Evidence |
| --- | --- | --- | --- |
| Rename `LocalOrderFiller` to `MercuriOrderFiller` (also in AGENTS.md, CLAUDE.md, README.md, lib-versions.md, check-local-source.py, check-natspec.py, source-manifest.json) | `src/MercuriOrderFiller.sol` | Spec D8 | `check-local-source.py`, `check-natspec.py` in gate |
| New `event OrderFilled(bytes32 indexed orderHash, address indexed swapper, bytes32 indexed poolId)`, emitted after the net-minimum check; uses `V3DutchOrderLib.hash` | `fill` | Spec D8 | `test_fillEmitsOrderFilled` |
| `require(...)` constructor replaced by `error ZeroAddress()` | constructor | Spec D8 | `test_constructorRejectsZeroAddress` |
| `_owed(order, output)`: sum of all outputs, all must be the output token with non-zero recipient, else `InvalidOrder`; replaces `outputs.length != 1` and `outputs[0].amount` | `reactorCallback` | Reactor fee controller outputs in the output token (spec D8, R4) | Section 7 |
| NatSpec: immutability, orders bound to reactor and cosigner not filler, donations never spent | contract and callback docs | Spec D8, E11 | `check-natspec.py` |

Decided (plan review ruling 10): `OrderFilled(orderHash, swapper, poolId)` deliberately has no `appFee` field. A balance-delta fee could be inflated by a hooked pool calling `FeeManager.claimPlatform()` during the fill, so app-fee revenue stays with the indexer's transfer-log attribution. The controller has corrected spec D8 to match. Not an open item.

Non-source changes: tests (`test/integration/UniswapXFiller.t.sol`, `UniswapXLocal.t.sol`, `test/invariant/TradeInvariants.t.sol`, `test/local/DeployScripts.t.sol`, `test/utils/MockFeeController.sol`), `script/` deploy package and verifier, `script/check-contracts.sh`, `.gas-snapshot`, `deployments/manifest-5042002.json`.

## 3. Test inventory, seeds, run counts, durations

The final gate run (this packet, section 12) ran with `forge test --fuzz-seed 0x5042`.

| Suite | Tests | Result in final gate run | Notes |
| --- | --- | --- | --- |
| `UniswapXFillerTest` | 30 (27 snapshot-covered, 3 fuzz excluded from snapshot) | 30 passed (655.91 ms, from the A5 gate run in section 12; not recorded by implementers) | Fuzz default 512 runs; includes `testFuzz_protocolFeeOutput` (513 runs reported by A2), `testFuzz_expiryBoundary` (since renamed `testFuzz_exclusiveExpiryBoundary`; see section 14) |
| `UniswapXLocalTest` | 5 | 5 passed | Includes `test_exportExpiringOrderVector` |
| `UniversalRouterSwapTest` and `.small` | 10 + 10 | 20 passed | Unchanged from baseline |
| `DeployScriptsTest` | 11 | 11 passed | Sentinel, anvil guard, wrong chain, reactor mismatch (`codehash`, `permit2`, `owner`), no-code |
| `TradeInvariantsTest` | 1 (5 handlers, see section 4) | passed (2.41 s, A5 gate run) | 64 runs x 64 depth, `fail_on_revert=true`; 4,096 calls, 0 reverts, 0 discards |
| `UniversalRouterForkTest`, `TradeForkInvariantsTest`, `TradeLocalStateTest` | 1 each | 3 skipped (fork variables unset in the plain gate; state export off) | Fork results are in section 5 |
| Total, plain gate | 70 | 67 passed, 0 failed, 3 skipped; exit 0 | Final run in section 12 |

Stress runs (`--stress`) as reported by implementers, not re-run in this task:

| Run | Reported result | Source |
| --- | --- | --- |
| Fuzz at 10,000 runs, seed `0x5042` | pass (A2: 58 + 56 tests; A3: pass) | A2, A3 reports |
| Invariant 1,024 runs x 256 depth, seed `0x5042002`, two campaigns (local and fork invariant suites) | 262,144 calls, 0 reverts, 0 discards in each; after A2 fix round feeFill about 65,399 and 65,221; inputFeeAttempt 65,968 and 65,936; step 65,395 and 65,720; toggleOutputFee 65,382 and 65,267 | A2 fix round |
| Stress with expiring handler | `expiring` 52,439 and 52,593 calls per campaign, 0 reverts | A3 report |
| Stress durations | A2: 139 s (first), 222 s (after fix round); A3: not recorded; A4: not recorded | A2, A3, A4 reports |
| Stress at the final HEAD 4be3452 | Reported by A4 only against a fresh loopback fork (exit 0). A stress run at the final HEAD against the approved read-only testnet RPC is PENDING | A4 report |

Not evidenced: the 29 Sep report states stress invariants of 262,144 calls but no baseline test count; a per-test baseline comparison is PENDING. Timings of the non-stress gate for A3 and A4 are not recorded in their reports.

## 4. Invariant reachability evidence

| Claim | Evidence | Limit |
| --- | --- | --- |
| Handlers reach fee, input-fee, and expiring paths | Handler set in `TradeInvariants.t.sol`: `step`, `toggleOutputFee`, `inputFeeAttempt`, `feeFill`, `expiring`. `afterInvariant` asserts `feeFills > feeFillsBase`, `inputFeeRejections > inputFeeRejectionsBase`, `expiredRejections > expiredRejectionsBase` | Bases are snapshotted at the end of setUp, so the asserts are campaign-only |
| The reachability assert is not vacuous | Mutation check (A2 fix round): removing `feeFill` from the selector set fails with `campaign never ran an output-fee fill: 2 <= 2` | Mutation run for `feeFill` only; equivalent mutation checks for `inputFeeAttempt` and `expiring` are PENDING |
| `inputFeeAttempt` counts only the expected failure | Catches `bytes memory err` and asserts selector `InvalidOrder` | Pre-existing bare `catch { expectedFailures++ }` on other actions (deferred minor) |
| Call distribution | Everyday run 4,096 calls: feeFill 1,027, inputFeeAttempt 1,013, step 1,030, toggleOutputFee 1,026; stress figures above | Forge does not print ghost counter values; exact counts per run are not available |

## 5. Fork blocks and shims

| Item | Value | Source |
| --- | --- | --- |
| Pinned fork suites | `UniversalRouterFork` 10 passed; `TradeForkInvariants` 1,024 runs, 262,144 calls, 0 reverts, on a fresh loopback fork of Arc testnet at block 65100759, chain 5042002 | A4 report |
| Rehearsal fork | anvil at block 65100759 (first rehearsal) and 65102574 (fix-round rehearsal); anvil needs `--fork-header 'User-Agent: curl/8.7.1'` | A4 report |
| Shims | `unchecked_cheatcode_artifacts = true` in `foundry.toml` (forge 1.4.3 artifact restriction, foundry-rs/foundry#12231); `fs_permissions` read for `./out`, `./deployments`, read-write `./test-export`; test fixtures under `test/utils/` and `test/utils/launch/` copied from the Launch working tree on 29 Sep 2026 | `foundry.toml`, `lib-versions.md` |
| Stress gate RPC | `ARC_LOCAL_FORK_RPC` set to the read-only testnet RPC (A2, A3: `https://rpc.testnet.arc.io`; the A4 anvil fork used `https://rpc.testnet.arc.network`; both hostnames were used, read-only) or a loopback fork (A4) with `TRADE_FORK_CHAIN_ID=5042002` | A2, A3, A4 reports |
| Mainnet fork | Not run in this work. The 29 Sep report recorded mainnet-fork evidence for the old candidate. Mainnet fork evidence for this candidate is PENDING (mainnet is a separate plan) | none |
| Fork-suite caveat | Anvil stopped answering after receiving the rehearsal deployments and then being forked by forge; a fresh fork at the same block passes. Tooling limitation, not a contract result | A4 report |
| Fixture limits | Fork shims and test fixtures must never enter a deployment graph; the deploy scripts import only `TradeManifest.sol` and production sources | A4 scripts |

## 6. Gas deltas

Gas deltas are from `forge snapshot --diff` as reported by each task (seed `0x5042`). The three diffs overlap on the same snapshot, so they do not sum cleanly.

| Step | Overall delta | Notable | Source |
| --- | --- | --- | --- |
| A1 rename, event, hash | +194,368 (+0.123%) | About +15.5k per successful fill (`order.hash()` plus the event): orderMercuriBuy +15,591, orderMercuriSell +15,571, orderOtherBuy +15,555, orderOtherSell +15,550 | A1 report |
| A2 fee outputs | +9,651 (+0.006%), reported against a snapshot that A1 left slightly stale | Order tests +11 to +1,200 | A2 report |
| A3 harness refactor | +5,676 (+0.003%) | 8 new entries; largest percentage 0.318% on a trivial constructor test | A3 report |
| Net, current `.gas-snapshot` vs d84519d | Per-test values in `git diff d84519d..HEAD -- .gas-snapshot`; e.g. `orderMercuriBuy` 3,618,071 to 3,634,795 (+16,724), `orderMercuriSell` 3,632,710 to 3,649,034 (+16,324), `orderOtherBuy` 4,882,099 to 4,898,677 (+16,578), `orderOtherSell` 4,943,203 to 4,959,506 (+16,303) | Computed from the committed snapshots; the snapshot was updated, not weakened, and `forge snapshot --check` passes in the gate |
| Real-chain gas | PENDING. Snapshot numbers are local-EVM; Arc testnet gas measurements for a fill are not evidenced | |

## 7. Fee-output change and the input-token-fee liveness limit

| Requirement | Baseline | Candidate | Command / artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Reactor protocol fee in the output token | `outputs.length != 1` reverted `InvalidOrder` whenever a fee controller added a fee output | Any number of outputs is accepted if every one is in the output token with a non-zero recipient; the swap targets their sum, the trader keeps everything above their own minimum | `test_protocolFeeOutputMercuriBuy/Sell`, `...OtherBuy/Sell`, `testFuzz_protocolFeeOutput` (bps 0..5, asserts trader at least the minimum, fee recipient delta equals minimum x bps / 10000, filler balances and allowances zero), `test_feeControllerExpiringRaisedOutputStillFills` | RED then GREEN recorded by A2; 6 tests passed; fuzz 513 runs; gate green | Only buy-direction input fee is tested; sell-direction input fee PENDING (deferred minor). No test pins fee recipient equal to filler or swapper, or multiple fee outputs (correct by inspection) |
| Input-token fee | Reverts | Still reverts `InvalidOrder`, order stays open, no funds move. A fee in the input token cannot be paid because the whole input is spent on the swap | `test_protocolFeeOnInputFailsWithoutLoss`; invariant `inputFeeAttempt` asserts the selector | Pass locally | This is a liveness limit, not a safety defect: if a reactor owner enables an input-token fee controller, every order on that reactor stops filling until a replacement filler is deployed (spec R4, E11). On the Uniswap-owned mainnet reactor this is outside our control |
| Controller owner for tests | | `MockFeeController` set by the reactor owner (`setProtocolFeeController` is `onlyOwner`) | A2 report | Confirmed | Whether Uniswap would ever enable a controller on a reactor we do not own is an assumption (R4) |
| Zero-amount fee output | | Accepted (bps = 0 covered by fuzz) | A2 report | Pass | None |

## 8. Expiry-curve semantics

| Requirement | Baseline | Candidate | Command / artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Curve (spec D2) | no expiry curve test | Trader-signed relative blocks `[20, 21]`, relative amounts `[0, -2^128]`. Keeper cosigns with `decayStartBlock` equal to the finalized head. At offset up to +20 the required output is the cosigned value; at +21 the required output exceeds `uint128` and the fill reverts `InvalidOrder`, nonce unused | `test_expiringOrderFillsInsideWindow`, `test_expiringOrderDeadAfterWindow`, `test_expiryBoundarySweep` (0..40 with snapshots), `testFuzz_expiryBoundary` (512 runs default, 10,000 under stress, fills iff offset <= 20; since renamed `testFuzz_exclusiveExpiryBoundary`, see section 14) | Pass. No filler change was needed: the filler already rejects outputs above `uint128` | `test_expiringOrderFillsInsideWindow` alone asserts only no-revert (the fuzz is the stronger check; deferred minor) |
| Cosigner cannot lower output | | `InvalidCosignerOutput` | `test_cosignerCannotLowerOutput` | Pass | None |
| Raised output above market | | Router reverts `V4TooLittleReceived(gross+1, gross)`, trader balance and nonce unchanged; raised = gross fills | `test_raisedOutputAboveMarketReverts` | Pass | A raised output at gross is the largest fillable; anything higher fails, which is the intended D4 limit |
| Condition data in signed order | | `additionalValidationData` set, validation contract zero, still fills | `test_orderWithConditionDataStillFills` | Pass | Reactor ignores the data; the keeper enforces the trigger (D11) |
| Invariant | | `expiring` handler: even seeds at +0..+20 must fill, odd seeds at +21..+40 must revert `InvalidOrder` with input and nonce unchanged | `TradeInvariants.t.sol` | Pass, 52k calls per stress campaign | None |
| Cross-language vector | | `test-export/trade-orders/order_expiring.json` consumed by backend and web app; SHA-256 `cd325ce75f4091cdc0bed4e0328c6f3937731fe8885adc81d9b805c6d404c631` identical in all three copies at A3 time | `check-contracts.sh` SHA gate with `TRADE_VECTOR_BACKEND` and `TRADE_VECTOR_WEBUI` set | Pass at A3 | The SHA gate was not exercised in the final gate run of this packet (variables unset, it printed the skip notice). Backend and web copies are not committed in their repos yet (B2 and C1). Gate silently skips when only one variable is set (deferred minor) |

Block time and wall-clock figures in the spec ("about 10 s") are not evidenced by this report; they depend on Arc block time (PENDING).

## 9. Immutability and replacement path (E11)

| Requirement | Baseline | Candidate | Command / artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Classification | Immutable local fixture | `MercuriOrderFiller`: immutable contract. No owner, pause, allowlist, upgrade, rescue or trigger logic. Reactor: pinned upstream `V3DutchOrderReactor`, owned by `reactorFeeOwner`, which controls only the protocol fee controller | Source; `contracts.md` classification requirement | Documented in NatSpec | `reactorFeeOwner` is not yet chosen (R10, section 11) |
| Orders bound to reactor and cosigner, not filler | NatSpec said a replacement requires new orders | The signed order contains reactor, cosigner and `OrderInfo`; the filler address is not in signed data, so a replacement filler can settle existing orders; the keeper switches by configuration | Spec E11; `UniswapXLocalTest` vector (order hash independent of cosigner data); NatSpec | Pass for the signed-data claim by inspection and vector test | No test deploys a second filler and fills one order through the first and another through the second. PENDING |
| Code rollback | None possible | None. A defective filler is abandoned and replaced | | Documented | Open orders stay bound to the reactor and the cosigner. Rotating the cosigner strands open orders (spec R2) |
| Funds at rest | Donations cannot subsidize fills | Tokens sent to the filler outside a fill are never spent for another order and are unrecoverable (no rescue path) | `test_orderDonationsCannotBlockOrSubsidizeFills`, `test_orderTaxCannotSpendDonations` | Pass | Donated funds are lost by design; reviewer to confirm acceptable |
| Storage and proxy | N/A | No proxy, no storage layout concern beyond `active` and `inputBaseline` (reset to zero after each fill) | | Applicability recorded: storage and upgrade checks do not apply | None |

## 10. Known deferred minors (from `progress.md`, lines marked "minor (deferred)")

| Task | Deferred minor |
| --- | --- |
| A1 | `docs/reports/2026-09-29-filler-assurance.md` still names `LocalOrderFiller` (historical; the rename note is in this report) |
| A1 | README status row and `lib-versions.md` "local test deployment" wording goes stale at deployment |
| A1 | `error ZeroAddress()` lacks NatSpec. **Resolved in `c52acb4`**: all four custom errors carry a `@notice`, and `check-natspec.py` now requires one on the contract's own errors and events |
| A1 | `test_constructorRejectsZeroAddress` zeroes only the reactor argument; the other five are covered only by bare `expectRevert`; fill gas +15.5k from `order.hash()` in `OrderFilled` |
| A2 | `inputFeeAttempt` only exercises buys (USDC input); add a sell-direction input fee |
| A2 | Fee-on invariant uses `assertGe` for trader net; could assert the exact expected delta |
| A2 | No tests pin fee recipient equal to filler or swapper, or multiple fee outputs (correct by inspection) |
| A2 | Pre-existing bare `catch { expectedFailures++; }` (action >= 2, replay) counts any revert; same class as the fixed finding |
| A2 | Comment the `seed / 7 * 7 + seed % 2` action-forcing trick in `feeFill` |
| A3 | SHA gate silently skips if only one of `TRADE_VECTOR_BACKEND` or `TRADE_VECTOR_WEBUI` is set; missing-file message comes from `shasum` |
| A3 | `test_expiringOrderFillsInsideWindow` only asserts no-revert (fuzz covers stronger) |
| A4 | Add a reactor function-pointer self-test case; optionally derive the pointer on a non-forked local `anvil --chain-id 5042002`. **Self-test resolved in `25beac0`** (known id 0x2a, each profile: MATCH, flipped pointer byte MISMATCH, id above 0xff refused; run by `check-contracts.sh`). Deriving the id on a local anvil is still open |
| A4 | Test that manifest `usdc` and `launchHook` equal the Launch testnet record |
| A4 | Verifier `required_owner` `int(owner,16)` gives a traceback on bad hex; `_isAddressString` accepts a `0X` prefix; stale comment at `DeployScripts.t.sol:43` |

Additional gaps found while preparing this packet (not in the ledger): the A4 verifier reads the reactor's `_getBlockNumberish` function id from an `eth_call` constructor simulation rather than from source (it is bounded to at most 0xFF); the evidence for this exact candidate on the real testnet RPC at final HEAD is PENDING.

## 11. Deployment package and guards (A4)

See the appendix below for full details; section 12 supersedes it for the gate result. Summary table:

| Guard | Evidence | Result |
| --- | --- | --- |
| Chain guard: both scripts revert unless `block.chainid == 5042002` | `DeployScripts.t.sol` `WrongChain(5042)` | Pass |
| Sentinel: `reactorFeeOwner` literal `REQUIRED_AT_D2_OWNER_GO` or any non-address reverts `ReactorFeeOwnerNotChosen` | tests plus real `forge script` run (fix round) | Pass |
| Rehearsal override only on anvil and only with anvil's ten default accounts | `RehearsalNeedsAnvil`, `RehearsalOwnerNotAnvilAccount(addr)`; run against a non-anvil RPC with a non-default owner produced the error | Pass |
| Code presence at permit2, router, usdc, launchHook, reactor | `NoCode` | Pass |
| Reactor identity before filler deploy: `TRADE_REACTOR_CODEHASH`, `permit2()` equals manifest, `owner()` equals fee owner | `ReactorMismatch` with reason `codehash`, `permit2` or `owner`; fork run with wrong hash refused | Pass |
| No key in scripts; `--account` or `--ledger` required at the go step | inspection | Pass; PENDING owner step |
| Runtime verifier: byte-for-byte compare, fixed immutable allowlist per contract in both directions, `reactorFeeOwner` mandatory, equals record and on-chain owner | `--self-test`, `--self-test-flipped` (expects MISMATCH), unknown and missing immutable cases, `python3 -O` run | Pass in gate |
| Manifest values equal the Launch testnet record | by hand in A4 | No automated test (deferred minor) |
| `reactorFeeOwner` | Owner choice, literal `REQUIRED_AT_D2_OWNER_GO` in the manifest | PENDING at D2 owner go |
| `deployments/5042002.json` | Does not exist | PENDING |
| Real testnet verification at a deployed block | not possible before broadcast | PENDING |

## 12. Final gate run for this packet

Command: `bash script/check-contracts.sh` in `the contracts checkout` at HEAD `4be3452` before this report was committed. Exit code 0. Forge test (source of the 9-suite and per-suite duration figures in section 3): 9 suites, 67 passed, 0 failed, 3 skipped (70 total), seed `0x5042`. Snapshot check: 4 suites, 50 passed, 0 failed, 0 skipped. The `order_expiring.json` copy check printed its skip notice because `TRADE_VECTOR_BACKEND` and `TRADE_VECTOR_WEBUI` were not set in this shell. The `--stress` variant was not re-run for this packet.

## 13. Scope for the independent reviewer

In scope (read at SHA `4be34522396dee1c3ac5966ee9ed1fdeaaf19f11`):

| File | Why |
| --- | --- |
| `src/MercuriOrderFiller.sol` (about 190 lines; the only production contract) | Full review; diff against `src/LocalOrderFiller.sol` at d84519d |
| `script/DeployTestnetReactor.s.sol`, `script/DeployOrderFiller.s.sol`, `script/TradeManifest.sol`, `deployments/manifest-5042002.json` | Deployment guards |
| `script/verify-trade-filler.py` | Runtime identity method and the function-pointer immutable path |
| `script/check-contracts.sh`, `script/check-local-source.py`, `script/check-natspec.py`, `source-manifest.json` | Gate soundness |
| `test/integration/UniswapXFiller.t.sol`, `test/integration/UniswapXLocal.t.sol`, `test/invariant/TradeInvariants.t.sol`, `test/local/DeployScripts.t.sol`, `test/utils/MockFeeController.sol` | Whether the tests prove what the report claims |
| `.gas-snapshot`, `foundry.toml`, `lib-versions.md` | Reproducibility |

Out of scope as vendored, unchanged code (reviewed only as integration assumptions): `lib/uniswapx` (V3DutchOrderReactor and base, pinned `eb7ce07`), `lib/universal-router` (pinned `999d561`), `lib/mercuri-launch-contracts` and its Uniswap v4, Permit2 and OpenZeppelin trees, and the Launch test fixtures under `test/utils/`. Launch contracts are read-only for this work and unchanged.

Not part of this packet: backend keeper, API, web app (tasks B and C), the mainnet plan.

Questions we want answered:

1. Does any ordering of `fill`, reactor callback and router call let an attacker, a donated balance or a taxed token make the filler spend funds that are not the order's? Is `active` plus `inputBaseline` sufficient against reentrancy through the output token or the hook?
2. Is `_owed` correct and sufficient: all outputs in the output token with non-zero recipients, sum below `uint128`? Can an output-token fee make the trader's minimum unreachable in a way that loses funds rather than reverting?
3. Is the input-token fee limit acceptable as a liveness-only failure? Is there a way for a third party who owns a reactor controller to cause loss rather than a stall?
4. Does the expiry curve behave as described at the boundaries (offsets 20 and 21), including `uint128` overflow in the reactor's decay arithmetic, for every cosigner-supplied `decayStartBlock`, including values in the future and far in the past?
5. Is the claim that a replacement filler can settle existing orders correct against the order struct and the reactor, and is the keeper's switch-by-configuration safe against settling one order through two fillers?
6. Is the `OrderFilled` event sufficient for off-chain accounting, given it has no fee field (ruling 10; fees are attributed from transfer logs)?
7. Does the runtime verifier's treatment of the `_getBlockNumberish` function-pointer immutable (from an `eth_call` constructor simulation, at most 0xFF, other bytes compared) leave room for a hidden difference? Is any tolerance too wide?
8. Do the deployment guards (sentinel, anvil-only override, reactor code-hash, permit2 and owner checks) prevent a wrong-network or wrong-owner broadcast, and is `TRADE_REACTOR_CODEHASH` a sound trust anchor?
9. Is the invariant campaign meaningful given the setUp warm-up and per-run state reset? Would a missing handler be caught for every selector, not just `feeFill`?
10. Are the 29 Sep conclusions about the old contract still valid for each change in section 2, or does any change need re-review beyond the diff?

Findings from the reviewer must be resolved, and affected gates rerun, before Task D3. This report does not claim contract readiness: the independent review, the mainnet fork evidence and the final-HEAD stress run are PENDING.

---

# Appendix: A4 rehearsal record (verbatim)

Section 12 supersedes this appendix for the gate result. The record below was written by A4 and describes a rehearsal on a loopback Arc testnet fork only. Nothing was broadcast to Arc testnet or mainnet, no `deployments/5042002.json` exists, and the owner has not chosen `reactorFeeOwner`.



### Package

| File | Purpose |
| --- | --- |
| `deployments/manifest-5042002.json` | Testnet constructor inputs. `reactorFeeOwner` is the literal `REQUIRED_AT_D2_OWNER_GO`. |
| `script/DeployTestnetReactor.s.sol` | Deploys the pinned `V3DutchOrderReactor(permit2, reactorFeeOwner)`. |
| `script/DeployOrderFiller.s.sol` | Deploys `MercuriOrderFiller` against `TRADE_REACTOR`. |
| `script/TradeManifest.sol` | Shared manifest reader, chain guard, code-presence guard. |
| `script/verify-trade-filler.py` | Byte-for-byte runtime verifier with `--self-test`. |
| `test/local/DeployScripts.t.sol` | Proves the sentinel and any other chain stop both scripts. |

Both scripts refuse `block.chainid != 5042002`, require code at permit2, router, usdc, launchHook and reactor, contain no key, and need `--account` or `--ledger` at the go step. Both refuse to run unless `reactorFeeOwner` parses as an address. `TRADE_LOCAL_REHEARSAL=true` with `REACTOR_FEE_OWNER_OVERRIDE=<address>` replaces it for a loopback rehearsal and prints a warning, but only when the RPC's `web3_clientVersion` contains `anvil` and the override is one of anvil's ten public default accounts; otherwise the script reverts (`RehearsalNeedsAnvil`, `RehearsalOwnerNotAnvilAccount`). The sentinel or any non-address reverts with `ReactorFeeOwnerNotChosen`. `DeployOrderFiller` also requires `TRADE_REACTOR_CODEHASH` (the reactor runtime keccak printed by `verify-trade-filler.py` at the reactor step) and checks that `TRADE_REACTOR` has that code hash, `permit2()` equal to the manifest and `owner()` equal to the fee owner.

### Manifest values and read-only code lengths (`eth_getCode`, testnet RPC, latest at 2 Oct 2026)

| Field | Address | Code bytes |
| --- | --- | --- |
| permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | 9152 |
| router | `0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1` | 24546 |
| usdc (Launch record `.usdc`) | `0x3600000000000000000000000000000000000000` | 1798 |
| launchHook (Launch record `.launchHook`) | `0x87e6BaBAc4598F99f4A0717ad294934455Fe60cc` | 3431 |
| appRecipient | `0xc914763d1652931dc3874B75387B3886aBAcF891` | 0 (an externally owned account) |

### Fork rehearsal

Anvil forked `https://rpc.testnet.arc.network` at block 65100759 on port 18545, chain id 5042002, using anvil's unlocked dev account 0 as sender and dev account 1 as the rehearsal fee owner. Anvil needs `--fork-header "User-Agent: curl/8.7.1"` because the RPC returns 403 otherwise.

| Item | Value |
| --- | --- |
| Reactor (fork) | `0x6CD6AeD7978839BBE6D64aff16FD1fA17fFb71BF`, block 65100760 |
| Filler (fork) | `0x2d4A9ebb2C5D8cD84627E79F0Aa64Bb8F15FC3D9`, block 65100761 |
| Verified at | block 65100761, hash `0x0c871554602625f936458f9c3d30e74802bcb42b7ba4e63dfa96de3151c5ad9c` |
| Reactor runtime keccak | `0xd7a5867bd6bea358f040527c10ba7ab2e76ce071e7b7be6181b26a0c1e7e7dcb` (11525 bytes, profile `small`, runs 200) |
| Filler runtime keccak | `0xa2568eef7d6ad8dc62060ec3a171997c0c43974d4212df72607a5d911802598d` (9838 bytes) |

The addresses are fork-only and deterministic for dev account 0; they are not testnet addresses.

```
reactor (V3DutchOrderReactor.small.json): MATCH 11525 runtime bytes, keccak 0xd7a5...0dcb
filler: MATCH 9838 runtime bytes, keccak 0xa256...598d
reactor owner 0x70997970c51812dc3a010c7d01b50e0d17dc79c8
```

Pointing the filler slot at the reactor address printed `filler: MISMATCH at offsets ['length 11525 != expected 9838']` and a non-zero exit.

Verifier notes. Immutables are substituted from the manifest and deployment (filler: reactor, router, permit2, usdc, launchHook, appRecipient; reactor: permit2). The reactor also holds an internal function-pointer immutable, `_getBlockNumberish`, which via-IR stores as a small compiler-assigned function id. Source and manifest cannot supply it, so the verifier takes it from an `eth_call` constructor simulation of the same creation bytecode at the pinned block and requires it to be at most 0xFF; every other byte is compared against the rebuilt source. Each contract has a fixed immutable allowlist (filler: reactor, router, permit2, usdc, launchHook, appRecipient; reactor: permit2 and `_getBlockNumberish`); any difference in either direction is an error and only `_getBlockNumberish` may use the simulation path. The manifest `reactorFeeOwner` is required, must not be the sentinel, must equal the deployment record, and must equal the on-chain `owner()`. The simulation uses that owner. For the fork rehearsal the verifier is given a scratch copy of the manifest with the anvil owner filled in. The verifier tries each built reactor profile and accepts an exact match; forge selected `small` for the script build.

Self-test (no network):

```
filler self-test: MATCH 9838 runtime bytes, keccak 0x351554fc...a32fada
filler self-test (one immutable byte flipped): MISMATCH at offsets [393] (inside immutables: usdc)
self-test ok: unmodified runtime matches, flipped immutable byte is rejected
```

`--self-test-flipped` runs the flipped case on its own and exits 1; `check-contracts.sh` runs `--self-test` and asserts that `--self-test-flipped` fails.

### Gates

`bash script/check-contracts.sh` passes, including the new self-test and `DeployScripts.t.sol` (sentinel refusal for both scripts, a positive control that the reactor script runs with the rehearsal override, wrong-chain refusal, and the manifest shipping the sentinel). `MercuriOrderFiller` was already the sole entry in `source-manifest.json` (`check-local-source.py`) and in `check-natspec.py`; the runtime-identity step is the new self-test above. The reactor and router are covered by the upstream source manifests and `verify-trade-router.py`.

`ARC_LOCAL_FORK_RPC=http://127.0.0.1:18545 TRADE_FORK_CHAIN_ID=5042002 TRADE_FORK_BLOCK=65100759 bash script/check-contracts.sh --stress` passed (exit 0) against a fresh fork at block 65100759. The fork suites ran and did not skip: `UniversalRouterFork` 10 passed, `TradeForkInvariants` 1024 runs and 262144 calls, 0 reverts. The one skipped test in the output is `TradeLocalState`, which is not a fork suite.

Rehearsal caveat: the same stress run against the anvil instance that had just received the two rehearsal deployments timed out in both fork suites (anvil stopped answering RPC, 45 s client timeouts). Two attempts hung the same way. A fresh fork at the same block passes. This is a loopback-tooling limitation, not a contract result.

### Open for the go step

- Owner names `reactorFeeOwner`; replace the sentinel in the manifest in the same reviewed change.
- Real deployment needs `deployments/5042002.json` written from the verified output (`reactor`, `reactorFeeOwner`, `filler`, `router`, `permit2`, `usdc`, `launchHook`, `appRecipient`, `block`, `blockHash`, `fillerRuntimeKeccak`, `reactorRuntimeKeccak`, `sourceRevision`, `compiler`), then `verify-trade-filler.py` at that block.

## 14. Addendum: exclusive cosigned orders and the single-point curve (spec D18)

This supersedes the curve and vector rows of section 8. The filler source is unchanged (`src/MercuriOrderFiller.sol` sha256 `459538fa…af24f1`); exclusivity is enforced by the upstream reactor (`V3DutchOrderReactor._resolve` → `ExclusivityLib.handleExclusiveOverrideBlock`).

| Requirement | Candidate | Tests | Result |
| --- | --- | --- | --- |
| Curve | Trader-signed output curve is one point: relative block `1`, amount `-2^128`. The keeper cosigns at head `H` with `decayStartBlock = H + 20`, `exclusiveFiller = MercuriOrderFiller`, `exclusivityOverrideBps = 0`. Through `H + 20` the output is its (cosigned) start amount; at `H + 21` it is start + 2^128, above `uint128`, and our filler reverts `InvalidOrder` with the nonce unused | `test_exclusiveWindowFillsThroughFiller` (+1..+20), `test_expiringOrderFillsInsideWindow`, `test_expiringOrderDeadAfterWindow`, `test_expiryBoundarySweep` (0..40) | Pass |
| Exclusivity | Any other filler is refused `NoExclusiveOverride` through `H + 20` (strict, override 0); from `H + 21` exclusivity ends but the output is unpayable, so no one can fill | `test_thirdPartyFillerBlockedInsideWindow` (control: the same order cosigned without an exclusive filler fills through the outside filler), `test_thirdPartyFillerCannotFillAfterWindow`, `testFuzz_exclusiveExpiryBoundary` (offset 0..40: fills iff offset <= 20, and only through our filler) | Pass; fuzz 10,001 runs under stress |
| Invariant | `expiring` handler: inside the window an outside filler must revert `NoExclusiveOverride` (input and nonce unchanged), then ours fills; outside it ours must revert `InvalidOrder`. Campaign counters for both refusals must grow | `TradeInvariants.t.sol`, `TradeForkInvariants.t.sol` | Pass, about 52k `expiring` calls per stress campaign, 0 reverts |
| Cross-language vector | `order_expiring.json` regenerated: uncosigned order with the new curve; `cosignedOrder` at `decayStartBlock` 1020 with `exclusiveFiller` = the exported `filler`; the export fills it through that filler at block 1020 after another caller is refused, and proves it dead at 1021. SHA-256 `25fbc6bc74d97ca6bb4ec137b9fc1ea5c464d20ade41c885ef24c2a35d1d1f79` | `test_exportExpiringOrderVector`, `check-contracts.sh` SHA gate with both copies set | Pass |

## 15. Addendum: the execution fee (spec D13 to D15, D18, D19)

This supersedes the "filler source is unchanged" statement of section 14. `MercuriOrderFiller` gained `MAX_EXECUTION_FEE = 100_000`, the immutables `executionFee` and `feeRecipient`, and a constructor of eight arguments (`…, uint256 fee, address recipient_`). The order format, reactor and cosigner binding are unchanged, so the cross-language vector `order_expiring.json` is byte-identical (SHA-256 `25fbc6bc74d97ca6bb4ec137b9fc1ea5c464d20ade41c885ef24c2a35d1d1f79`).

| Item | Behaviour | Evidence |
| --- | --- | --- |
| D13 fee and recipient | Fixed USDC fee, at most 0.10 USDC, default 30,000 in the manifest. Paid once, only on a successful fill, to the immutable `feeRecipient` (the keeper's transaction address), which is also the only permitted caller of `fill` (section 16). A zero recipient or a fee above the maximum reverts in the constructor; a fee of 0 skips the transfer | `test_execFeeConstructorRejectsFeeAboveMax`, `..ZeroRecipient`, `test_execFeePaidOnEachRoute`, `test_execFeeContractKeeper`, `test_execFeeNotPaidOnRevert`, `test_execFeeReentrantKeeperCannotDoublePay` |
| D13 where it comes from | Buy: from the USDC input before the swap (after the app fee). Sell: from the USDC output after the swap. Launch and listed pools alike. The trader's signed minimum is checked as before, so the fee only comes out of value above it | `test_execFeeSellExactBoundary`, `test_execFeeBuyInputTooSmall`, `testFuzz_executionFeeConservation` (signed minimum fuzzed in [1, output]; protocol fee on and off; the pool manager's USDC delta, with the hook fee added back. Sells: the swap output equals trader + fee + app fee + protocol fee exactly. Buys: the swap input plus app fee plus execution fee equals the trader's spend, and the protocol fee is taken in the token, so it is asserted against the minimum times bps rather than in the USDC split. The filler ends with zero balances and zero approvals) |
| D14 fee on top | The web app and keeper price the signed minimum net of the fee (sell: minimum less fee; buy: tokens priced from `amountIn - fee`). The contract needs no change for it; an order signed at the exact pre-fee quote reverts cleanly with the nonce unused until the price improves by the fee | `test_execFeePreFeeOrderFillsThroughNewFiller`, `test_execFeeTraderSurplusMatchesZeroFeeExceptFee` |
| D15 minimum order | Enforced in the API and keeper (10 USDC), not in the contract. The contract refuses only a buy whose input is at or below app fee plus fee (`InvalidOrder`), and a sell that cannot cover minimum plus fee | `test_execFeeAtMaxWithMinimumOrder` (10 USDC buys and the smallest viable sells at the maximum fee) |
| D18 exclusivity | Unchanged; only our filler can settle a cosigned order inside the window, and (section 16) only our keeper can call our filler | sections 14 and 16 |
| D19 keeper economics | The fee must cover gas: `estimatedGas x gasPrice <= executionFee`. Test gas for a fill rose by about 70k with the fee, but about 69k of that is the test shim's native-USDC transfer, not Arc's; real-chain gas is PENDING and the keeper should use `estimateGas` | gas table in the E1 report; PENDING real measurement |
| Zero fee | All 33 `UniswapXFillerTest` cases rerun with a fee of 0 and pass, so a zero-fee filler behaves as before. One difference: a buy of `amount == 0` reverts `InvalidOrder` in the callback | `UniswapXFillerZeroFeeTest` |

Deployment package. The manifest gains `"executionFee": 30000` and `"feeRecipient": "REQUIRED_AT_D3_OWNER_GO"` (an owner choice at the filler deployment, as `reactorFeeOwner` is at D2). `DeployOrderFiller` refuses a fee above the maximum (`ExecutionFeeTooHigh`) and a sentinel, malformed or zero recipient (`FeeRecipientNotChosen`) before any broadcast. Tests: `test_executionFeeAboveMaxRefused`, `test_feeRecipientSentinelRefused`, `test_manifestShipsSentinel`, and `test_scriptMaxExecutionFeeMatchesFiller`, which pins the script's copy of the bound to `MercuriOrderFiller.MAX_EXECUTION_FEE()` so the two cannot drift.

Rehearsal guard for the recipient. A loopback rehearsal sets `TRADE_LOCAL_REHEARSAL=true` and `FEE_RECIPIENT_OVERRIDE` (alongside `REACTOR_FEE_OWNER_OVERRIDE`). It is honoured only when the RPC reports `anvil` in `web3_clientVersion` (`RehearsalNeedsAnvil`) and the address is one of anvil's ten public default accounts (`RehearsalOwnerNotAnvilAccount`); the real testnet shares chain id 5042002, so the chain id alone is not a guard. A public dev account must never be the recipient of a real deployment, and the manifest value is never read under the override.

Verifier. The filler's immutable allowlist includes `executionFee` and `feeRecipient`, read in both directions (an unlisted or missing immutable is rejected). Live verification requires a non-sentinel, non-zero recipient equal to the deployment record, and a fee in [0, 100000]. Self-tests: one flipped byte in `usdc`, in `executionFee` and in `feeRecipient` each report `MISMATCH` against their own immutable name (`check-contracts.sh` asserts the name), and a non-hex recipient (`0xzz...`, a trailing `g`, a sign character) is refused with a clean `SystemExit`, not a traceback.

NatSpec fix (review R35). The `fill` notice and contract notice said the trader receives "its net output less the execution fee", which is wrong for buys (the fee comes from the USDC input). They now say the trader receives every output above what the reactor takes, and the fee is taken from the order's USDC side. Comment-only: `forge inspect MercuriOrderFiller deployedBytecode` and `bytecode` are byte-identical before and after (`cmp` clean; `bytecode_hash = none`), `source-manifest.json` is refreshed, `check-natspec.py` passes (19 entries, 0 failures).

Local export. `anvil-order.json` now carries `executionFee` and `feeRecipient` so the backend end-to-end test can read them.

### Questions for the reviewer (fee path)

1. Rounding. Fees are exact integers and the hook, app and protocol fees round down as before. Does any combination of the app fee (50 bps of the USDC side), the Launch hook fee and the 5 bps protocol fee let the filler end a fill holding dust, or pay out more than it received?
2. Fixed recipient and caller. The fee goes to an immutable address, and that same address is the only permitted caller of `fill`, so rotating the keeper key means a new filler (signed orders survive). Is that acceptable against the alternative of a settable keeper, and is there any path that pays the fee twice?
3. Interaction with protocol fees. The reactor's protocol fee is an output on top of the minimum. Does the net-minimum check, the sell swap minimum (`owed + fee`) or the buy approval (`amount - fee`) ever leave a fill that passes for the wrong reason?
4. Caller restriction. `fill` reverts `NotKeeper` for any caller other than `feeRecipient`, before the order is decoded, so a trader, a stranger or a copier of the keeper's calldata cannot settle an order or choose its pool. Confirm the check cannot be bypassed (the callback is reactor-only and requires an active fill) and that a contract keeper cannot re-enter to claw back or double the fee (`test_execFeeReentrantKeeperCannotDoublePay`).
5. Fee recipient liveness. USDC can blocklist addresses. If `feeRecipient` is blocklisted, every fill reverts at the final transfer and the filler is dead until replaced. There is no fallback by design (a fallback would let fills succeed without paying). Is that the right failure mode, and should a keeper-side check of the recipient run before each deploy?
6. Fee set at deployment. The fee is fixed for the filler's life and bounded at 0.10 USDC; a new value needs a new filler. Is the 30,000 default and the bound defensible against Arc gas?

### Open for the go step (fee)

- The owner chooses `feeRecipient` (the keeper address) and confirms `executionFee`, and both replace the sentinel in the same reviewed change.
- `deployments/5042002.json` also records `executionFee` and `feeRecipient`; the verifier requires the recipient to match.
- Backend settlement indexing must subtract the fee (see the E1 hand-off); real-chain fill gas is PENDING.

Gas snapshot (E2). `forge snapshot --diff` after the strengthened fuzz test and the new helper: overall +176 gas (0.000%), 8 `ExecFee` rows each +22 (a test-side helper changed the compiled test contract; no production change). `.gas-snapshot` updated, and `forge snapshot --check` passes.

## 16. Addendum: only the keeper fills (final review, ruling R39, spec D20)

Finding (final whole-branch review, Important). `fill` was open to any caller, and the caller chooses the pool key. A copier could take a keeper-cosigned order from the mempool and settle it first through a pool of its own choice (for example a hookless pool that avoids Launch's hook fee), leaving the keeper to pay for its own revert. Exclusivity (section 14) binds the order to this filler, not to the keeper. Earlier text in this packet that said the surplus always reaches the trader whoever calls, or that a copier has no incentive because the fee is not paid to `msg.sender`, overstated the protection: the fee was safe, the pool choice was not.

Change (`81cd88c`). `fill` now begins `if (msg.sender != feeRecipient) revert NotKeeper();`, with a NatSpec'd `error NotKeeper()`. The contract notice states that only the configured keeper can fill, why (exclusivity plus pool choice), and that rotating the keeper key means a new filler. No new immutable; the constructor, verifier allowlist and deployment manifest are unchanged (`feeRecipient` already had to be the keeper's transaction address; the deploy script's notice now says it is also the only caller). Runtime 10,602 bytes (+33).

| Property | Evidence |
| --- | --- |
| A trader, a stranger and a contract each revert `NotKeeper` on every route (Launch and listed, buy and sell), with no balance moved and the nonce unused; the keeper then fills the same order | `test_notKeeperCannotFill` (replaces `test_execFeeSelfFill`) |
| A contract keeper fills and earns exactly the fee | `test_execFeeContractKeeper` (replaces `test_execFeeContractCaller`; the filler is deployed with the FillCaller's predicted address as `feeRecipient`) |
| Re-entry through the keeper path is still refused: nested `fill` (reaches the `active` guard as the keeper), direct callback, reactor, router sweep, USDC pull; fee paid once | `test_execFeeReentrantKeeperCannotDoublePay` (replaces `test_execFeeReentrantCallerCannotDoublePay`) |
| Every other fill in the suites is sent as the keeper (`_fill` helper pranks `feeRecipient`) | `UniswapXFiller.t.sol`, zero-fee rerun |
| Invariant: before every fill one of the three fixed non-keeper callers tries first and must be refused `NotKeeper` (nonce, keeper, caller and trader USDC unchanged); the keeper then fills. Campaign-only counter `notKeeperRejections[i]` must grow for every caller | `TradeInvariants.t.sol`, `TradeForkInvariants.t.sol` |
| Backend end-to-end: a copier's fill of the keeper's calldata reverts `NotKeeper` on Anvil; the keeper's own fill settles and pays the fee | root `TestLocalLateCosignAnvil` |

Gas. `forge snapshot --diff`: overall +398,819 gas (+0.071%) across the integration tests, from the extra prank per fill and the replaced tests; no production path other than the one `msg.sender` comparison changed. `.gas-snapshot` updated; `forge snapshot --check` passes.

Gates at `81cd88c`. `bash script/check-contracts.sh` (vector copies set) exit 0: NatSpec 20 ABI entries, 0 failures; verifier self-tests MATCH and each flipped immutable reported by name; `forge test` 124 passed, 4 skipped (11 suites); `order_expiring.json` identical in all three repos (`25fbc6bc…1f79`). `--stress` (`ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io`, read-only; `TRADE_FORK_CHAIN_ID=5042002`) exit 0: `forge test` with the fork suites 136 passed, 2 skipped; 10,000-run fuzz 132 passed, 2 skipped; local and fork invariant suites 2 passed each at 1,024 runs x 256 depth (262,144 calls each, 0 reverts, fail-on-revert on).

## 17. Addendum: style conformance with the deployed Launch contracts

The filler, the deployment scripts, the test contract headers and the repository docs were brought into the style of the deployed Launch contracts (`contracts/launch` at `8d2aa60`): NatSpec continuation lines aligned under their tags, constants before immutables with blank lines between declaration groups, imports ordered OpenZeppelin, Uniswap v4, Permit2, then UniswapX, private helpers after the external functions (`_owed` moved below `reactorCallback`), a private `BPS = 10_000` constant in place of the literal `10000`, a long `if` condition given a block body to stay within 120 columns, and constructor parameters named after their immutables with a trailing underscore (`reactor_`, `router_`, `permit2_`, `usdc_`, `launchHook_`, `appRecipient_`, `executionFee_`, `feeRecipient_`; previously `r`, `u`, `p`, `usd`, `hook`, `recipient`, `fee`, `recipient_`). No identifier in the ABI's selectors changed and no state variable moved. The README, AGENTS.md, CLAUDE.md, CONTRIBUTING.md, SECURITY.md and lib-versions.md follow their Launch counterparts' structure; SECURITY.md now scopes this repository's filler rather than Launch's deployed contracts.

| Check | Result |
| --- | --- |
| `forge inspect MercuriOrderFiller deployedBytecode` and `bytecode`, before (`d37022d`) and after (`a59eabb`) | `cmp` clean for both: runtime sha256 `93b0f0ad…62dd`, creation sha256 `a72fe07b…7b2d` (`bytecode_hash = none`); also checked after each step (comments, import order, helper move) |
| ABI | Function, event and error names, types and selectors identical. Only the constructor's input names changed (above); any ABI JSON copy, such as the backend's `filler.json`, should be regenerated |
| `forge fmt --check`, `check-natspec.py`, `check-local-source.py` | Pass; NatSpec 20 ABI entries, 0 failures; manifest sha256 `1b7aa366…4514` |
| `bash script/check-contracts.sh` (vector copies set) at `cea3257` | Exit 0; verifier self-tests MATCH (filler 10,602 runtime bytes) and each flipped immutable reported by name; `forge test` 124 passed, 4 skipped; snapshot check 99 passed, 1 skipped; `order_expiring.json` identical in all three repos (`25fbc6bc…1f79`) |
| `--stress` (`ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io`, read-only; `TRADE_FORK_CHAIN_ID=5042002`) at `cea3257` | Exit 0 in 229 s: fork-suite run 136 passed, 2 skipped; 10,000-run fuzz 132 passed, 2 skipped; local and fork invariants 4 passed at 1,024 runs x 256 depth (262,144 calls each, 0 reverts) |

Fix round 1 (second reviewer, "same author" pass with fixes). `dfbbf30`: function `@param`/`@return` text starts with the noun, never an article (Launch `LiquidityLocker.sol:39-40`, `BondingCurve.sol:160-163`); the private helper `@dev` reads "Returns …"; the contract `@notice` keeps to three lines and the fee side is left to `executionFee`'s `@dev`; the repeated "switches by configuration" is said once. `61d033a`: script loops in Launch form (`++i`, no `= 0` init) and backticked `--account`/`--ledger`. `0a95f2a`: security reports routed to the public Launch repository's private reporting (this repository is private); SECURITY scopes testnet 5042002 only, states the keeper-key trust boundary and that the verifier runs in `--self-test` mode until a deployment record exists; README uses the mercurifi product names, drops the decision-history wording, links each testnet address to `https://explorer.testnet.arc.io/address/…` and moves `sh` comments above their commands; lib-versions records the Launch submodule commit `99d7c28a…c469`, the toolchain identity (Foundry 1.4.3-Homebrew, SHA-256 `7a91e6ef…20c6`, solc 0.8.26) and replaces the stale "local test deployments" sentence.

| Check (fix round 1, at `0a95f2a`) | Result |
| --- | --- |
| `deployedBytecode` and `bytecode` vs `d37022d` | `cmp` clean for both |
| `forge fmt --check`, `check-natspec.py`, `check-local-source.py` | Pass; 20 ABI entries, 0 failures; manifest sha256 `f728729c…f0ad` |
| `bash script/check-contracts.sh` (vector copies set) | Exit 0; verifier self-tests MATCH; `forge test` 124 passed, 4 skipped (includes `DeployScriptsTest`); snapshot check 99 passed, 1 skipped; `order_expiring.json` `25fbc6bc…1f79` in all three repos |
