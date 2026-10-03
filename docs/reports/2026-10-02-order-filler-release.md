# MercuriOrderFiller release evidence and independent-review packet, 2 Oct 2026

Status: candidate for independent review. This is a report only. No review has been commissioned, no one has been contacted, nothing was broadcast, and no `deployments/5042002.json` exists. Anything not evidenced below is marked PENDING; nothing is marked pass on inference.

The 29 Sep report `docs/reports/2026-09-29-filler-assurance.md` predates the rename of `LocalOrderFiller` to `MercuriOrderFiller` and the changes below; read its findings as describing the former contract, not this candidate.

## 1. Source revision and build identity

| Requirement | Baseline | Candidate | Command / artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Source revision | `d84519d3e451146ef3b53fe32358db226c588ac3` (29 Sep candidate; `LocalOrderFiller`) | branch `orders/late-cosign`, HEAD `25beac0c06967d3fea486147e1d6f1c13ea2c5ca`, clean tree at the gate run, local only (not pushed). This report row was updated in the commit after `25beac0`; no code changed in that commit | `git rev-parse HEAD`, `git status --short` (empty), `git log --oneline d84519d..HEAD` | Commits through `4be3452` as reviewed in this packet (bc4047b rename, d43c0b5 output-token fees, c3371ea invariant reachability, ea78ad8 expiry curve, b794a9c deploy package, 4be3452 deploy guards), then `74cfb76` (local keeper test export, test-only), `c52acb4` (NatSpec on the four custom errors; runtime and creation bytecode unchanged with `bytecode_hash = none`, gas snapshot unchanged) and `25beac0` (verifier reactor function-pointer self-test, script-only) | The final tag/SHA to deploy is PENDING; any further commit invalidates this packet. Revision update (self-funding round): `01d4edb` adds the execution fee (section 15); `48bbf65` is a NatSpec-only fix; later E2 commits are tests, verifier and report only. Final review fix (R39, section 16): `81cd88c` restricts `fill` to the keeper; this report was updated in the commit after `81cd88c` (docs only). Final code HEAD for review: `81cd88c`. Style conformance (section 17): `a59eabb` (filler NatSpec and layout, bytecode byte-identical), `19f5bf4` (scripts), `fcf70c0` (test headers), `cea3257` (docs), then fix round 1 `dfbbf30` (filler NatSpec, bytecode byte-identical), `61d033a` (scripts), `0a95f2a` (docs), then polish `cecc15d` (one filler comment, SECURITY reflow, bytecode byte-identical); this report was updated in the commit after `cecc15d`. The filler `src/` sha256 was `0f11784d154599cd20664a6f888e2c2bc6bbd25fc1d6faa3f2676659528f5b78` at `cecc15d` (`f728729c…f0ad` at `dfbbf30`, `1b7aa366…4514` at `a59eabb`, `9ce08495…3820` at `81cd88c`). Audit fix round (section 18), from `2873bf3`: `a21cb41` (F1 native refund), `653826e` (TRD-07 errors), `0000950` (TRD-08 interface), `e6fadd9` (F2 fee controller), `b613a07` (TRD-01 timelock owner), `6f2db4a` (ECON-02 fee), `8ce9f66` (F5 cross-checks, mainnet manifest), `7689e35` (TRD-04 record writer), `a6e648f` (rehearsal verification), `dad40b3` (TRD-06 invariant), `0db36d2` (docs); this report was updated in the commit after `0db36d2`. Final code HEAD for review: `0db36d2`. Sources now: `src/MercuriOrderFiller.sol` sha256 `0550d570d79be40bdc38019e6b51a752e980a007aebb09ecdcdae210051efa75`, `src/interfaces/IOrderSwapRouter.sol` sha256 `a8cffdb5307ab46c5fe166d5a291971835cc73af2cb6813458bb2aad5a96019b`. Early guard (section 19): `63c1f11` (code, tests, gas snapshot, manifest), then docs and this report in the commit after it; `src/MercuriOrderFiller.sol` sha256 now `14149bd68af46a7282e8849d53107432e5ad453a52d5939b586e90438ee12bf9`, isolated re-audit pending |
| Compiler and settings | solc 0.8.26, cancun, via-IR, optimizer, `bytecode_hash=none`; `src/**` compiled at optimizer_runs 200 | Unchanged except `fs_permissions` gained `read ./deployments` | `foundry.toml`; forge 1.4.3-Homebrew | Same compiler, EVM and optimizer settings as baseline; the only `foundry.toml` diff is the `./deployments` read permission (needed by deploy-script tests) | None |
| Filler runtime size | 7,542 bytes (29 Sep report) | 10,569 bytes (below EIP-170 limit of 24,576) | `script/verify-trade-filler.py --self-test` | 10,602 bytes, keccak `0x0c151c4de9dab6d48929bba85283709a4c26ce01611edb301dc788caace454a5` in the self-test (`81cd88c`, with the keeper-only check); 10,569 bytes at `48dd683` and 9,838 bytes before the execution fee. The fork-rehearsal keccak in section 9 predates the fee and is stale | Growth from 7,542 bytes (+3,027) is not individually attributed; PENDING |
| Filler source hash | recorded for `LocalOrderFiller.sol` | `src/MercuriOrderFiller.sol` sha256 `0f11784d154599cd20664a6f888e2c2bc6bbd25fc1d6faa3f2676659528f5b78` at `cecc15d` (the current `source-manifest.json` value; comment and layout only, section 17; `f728729c…f0ad` at `dfbbf30`; `1b7aa366…4514` at `a59eabb`; `9ce084954969d3a876385e7ec278eeb1204bb7dfc5ceeb7d15208577a3b63820` at `81cd88c`; `c0d2ff5e…2116` at `48dd683`; earlier `459538fa742b3d4f1569ea3546a8f6eb9f02220b09d309703cdb9b52f4af24f1` at `c52acb4`, before the execution fee) | `source-manifest.json`, `python3 script/check-local-source.py` | Pass inside gate | None |
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
| Input-token fee | Reverts | Still reverts `InvalidOrder`, order stays open, no funds move. A fee in the input token cannot be paid because the whole input is spent on the swap | `test_protocolFeeOnInputFailsWithoutLoss`; invariant `inputFeeAttempt` asserts the selector | Pass locally | This is a liveness limit, not a safety defect: if a reactor owner enables an input-token fee controller, every order on that reactor stops filling until a replacement filler is deployed (spec R4, E11). On the Uniswap-owned mainnet reactor this is outside our control. Superseded by spec D27 (section 20): both networks run our own reactor, owned by Launch's timelock |
| Controller owner for tests | | `MockFeeController` set by the reactor owner (`setProtocolFeeController` is `onlyOwner`) | A2 report | Confirmed | Whether Uniswap would ever enable a controller on a reactor we do not own is an assumption (R4) |
| Zero-amount fee output | | Accepted (bps = 0 covered by fuzz) | A2 report | Pass | None |

## 8. Expiry-curve semantics

| Requirement | Baseline | Candidate | Command / artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Curve (spec D2) | no expiry curve test | Trader-signed relative blocks `[20, 21]`, relative amounts `[0, -2^128]`. Keeper cosigns with `decayStartBlock` equal to the finalized head. At offset up to +20 the required output is the cosigned value; at +21 the required output exceeds `uint128` and the fill reverts `InvalidOrder`, nonce unused | `test_expiringOrderFillsInsideWindow`, `test_expiringOrderDeadAfterWindow`, `test_expiryBoundarySweep` (0..40 with snapshots), `testFuzz_expiryBoundary` (512 runs default, 10,000 under stress, fills iff offset <= 20; since renamed `testFuzz_exclusiveExpiryBoundary`, see section 14) | Pass. No filler change was needed: the filler already rejects outputs above `uint128` | `test_expiringOrderFillsInsideWindow` alone asserts only no-revert (the fuzz is the stronger check; deferred minor) |
| Cosigner cannot lower output | | `InvalidCosignerOutput` | `test_cosignerCannotLowerOutput` | Pass | None |
| Raised output above market | | Router reverts `V4TooLittleReceived(gross+1, gross)`, trader balance and nonce unchanged; raised = gross fills | `test_raisedOutputAboveMarketReverts` | Pass | A raised output at gross is the largest fillable; anything higher fails, which is the intended D4 limit |
| Condition data in signed order | | `additionalValidationData` set, validation contract zero, still fills | `test_orderWithConditionDataStillFills` | Pass | Reactor ignores the data; the keeper enforces the trigger (D11). Superseded by section 20 (D22): the validator checks the condition and refuses the D11 encoding (`test_orderWithLegacyConditionDataRefused`) |
| Invariant | | `expiring` handler: even seeds at +0..+20 must fill, odd seeds at +21..+40 must revert `InvalidOrder` with input and nonce unchanged | `TradeInvariants.t.sol` | Pass, 52k calls per stress campaign | None |
| Cross-language vector | | `test-export/trade-orders/order_expiring.json` consumed by backend and web app; SHA-256 `cd325ce75f4091cdc0bed4e0328c6f3937731fe8885adc81d9b805c6d404c631` identical in all three copies at A3 time | `check-contracts.sh` SHA gate with `TRADE_VECTOR_BACKEND` and `TRADE_VECTOR_WEBUI` set | Pass at A3 | The SHA gate was not exercised in the final gate run of this packet (variables unset, it printed the skip notice). Backend and web copies are not committed in their repos yet (B2 and C1). Gate silently skips when only one variable is set (deferred minor) |

Block time and wall-clock figures in the spec ("about 10 s") are not evidenced by this report; they depend on Arc block time (PENDING).

## 9. Immutability and replacement path (E11)

Superseded in part by section 20 (spec D22, R7): orders now name the filler's validator in the trader's signature, so
a replacement filler, which comes with its own validator, cannot settle orders signed for the old one
(`test_execFeeOrderForAnotherFillerRefused`). The rows below describe the candidate before that change.

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

Polish (second reviewer verdict PASS, optional items). `cecc15d`: the contract `@dev` says "The execution fee comes from the USDC side (see `executionFee`)." and SECURITY.md prose is reflowed to 120 columns. `deployedBytecode` and `bytecode` `cmp`-identical to `d37022d`; manifest sha256 `0f11784d…5b78`; `forge fmt --check`, `check-natspec.py` (20 entries, 0 failures) pass; `bash script/check-contracts.sh` with the vector copies set exit 0 (124 passed, 4 skipped; snapshot 99/1; vector `25fbc6bc…1f79` in all three repos).

## 18. Addendum: independent audit 3 Oct 2026 and fix round

An independent review of `2873bf3` on 3 October 2026 raised the findings below; an adversarial adjudicator confirmed
each one. Every finding is fixed, or decided by the owner and implemented, on branch `orders/late-cosign` from
`2873bf3`. Nothing was broadcast, no transaction was sent to any network, and `deployments/5042002.json` still does not
exist. The only chain activity was a loopback anvil fork of Arc testnet (reads of testnet state through the fork).

| Finding | Fix | Commit | Evidence |
| --- | --- | --- | --- |
| F1 (Medium): `BaseReactor._fill` refunds the reactor's whole native balance to the filler, which had no `receive()`; on Arc one wei, or one ERC-20 USDC unit sent to the reactor, reverted every fill with `NativeTransferFailed` | `receive()` accepts native value from the reactor only (`NotReactor` otherwise). The refund arrives after the callback's input checks and the reactor's output transfers. The callback now records `outputSurplus`, the swap's output above what it had to deliver, and `fill` pays the trader at most that (and at most the balance above the baseline and fee, as before), so the refund never subsidises the fill it arrives in; the next fill's baselines include it, so no later fill spends it. It stays in the filler with no rescue path. A taxed output token that delivers less than required now reverts `InsufficientOutput` in the callback | `a21cb41` | The audit's two PoCs ported as `test_nativeDustOnReactorDoesNotBlockFill` and `test_usdcErc20TransferToReactorDoesNotBlockFill`: both FAIL at `2873bf3` (`NativeTransferFailed`), PASS after. A bare `receive()` without the cap was tried first: `test_reactorRefundNeverSubsidizesOrLaterFills` and `testFuzz_reactorDustNeverReachesTrader` then FAIL (a 5-unit refund reached a selling trader, 90177789 != 90177784), so the cap is required. Also `test_nonReactorNativeRefused` (stranger, trader, keeper). All pass; fuzz 513 runs |
| TRD-07: `InvalidOrder` raised for about a dozen causes | Split into `Reentered`, `InvalidOutputs`, `InvalidOrderCount`, `PoolMismatch`, `AmountOverflow` (also how an expired late-cosigned order fails), `InputTooSmallForFees`, `InputNotConsumed` (taxed input, partial fill), `InsufficientOutput` and `FeeOutputUnsupported`, each with a `@notice` | `653826e` | Tests assert each selector: `test_orderRejectsPartialFillWhenLiquidityRunsOut`, `test_orderTaxCannotSpendDonations`, `test_orderTransferTaxRollsBackAndReentrancyIsBlocked` (InputNotConsumed); `test_orderTaxedOutputCannotMeetGrossMinimum` (InsufficientOutput); `test_orderRejectsForeignCallbackAndWrongPool` (PoolMismatch); `test_protocolFeeOnInputFailsWithoutLoss`, invariant `inputFeeAttempt` (FeeOutputUnsupported); `test_expiringOrderDeadAfterWindow`, `test_expiryBoundarySweep`, `testFuzz_exclusiveExpiryBoundary`, invariant `exerciseExpiring` (AmountOverflow); `test_execFeeBuyInputTooSmall`, `testFuzz_executionFeeConservation` (InputTooSmallForFees); new `test_orderRejectsInvalidOutputs`; `test_execFeeReentrantKeeperCannotDoublePay` now asserts the nested fill reverts `Reentered`. NatSpec 30 entries, 0 failures |
| TRD-08: inline router interface; buy-side app fee base undocumented | `IOrderSwapRouter` moved to `src/interfaces/IOrderSwapRouter.sol` (in the source manifest and the NatSpec check); `APP_FEE_BPS` NatSpec and the README state that a listed pool's buy pays the app fee on the gross signed input, which includes the execution fee | `0000950` | Filler runtime and creation bytecode `cmp`-identical before and after this commit; `check-local-source.py` now requires the manifest to list every `src/` file |
| F2 / TRD-02: reactor fee controller not checked | Manifest `reactorFeeController` (zero; zero when absent). `DeployTestnetReactor` checks owner and controller on the reactor it just deployed; `DeployOrderFiller._requireReactor` checks them on `TRADE_REACTOR`; the verifier calls `feeController()` (`0x6999b377`) at the pinned block and compares with the record | `e6fadd9` | `test_fillerRefusesWrongReactor` (a set controller is refused unless expected), `test_reactorScriptChecksDeployedReactor`, `test_reactorFeeControllerManifestValue`; verifier `fee_controller_self_test` |
| TRD-01 / ECON-05 (owner decision): reactor fee owner | `reactorFeeOwner` is Launch's TimelockController. Testnet manifest: `0x41129B5215cA24b29a4cABcaE26d3569744DEe2E`, the `timelock` of `lib/mercuri-launch-contracts/deployments/5042002.json`. Both scripts read the record at run time and require equality (`ReactorFeeOwnerNotTimelock`); the anvil rehearsal override still works and skips that check with a warning. `feeRecipient` stays `REQUIRED_AT_D3_OWNER_GO` | `b613a07` | `test_reactorFeeOwnerMustBeLaunchTimelock` (treasury and the mainnet timelock refused, rehearsal allowed), `test_reactorScriptDeploysWithTimelockOwner` (shipped manifest deploys a reactor owned by the timelock with no controller), `test_fillerScriptRefusesShippedManifest` (now `FeeRecipientNotChosen`), `test_manifestShipsSentinel` |
| ECON-02 (owner decision): execution fee | Manifest `executionFee` 30,000 → 50,000 (0.05 USDC); `MAX_EXECUTION_FEE` stays 100,000. The test harness fills at 50,000; README updated | `6f2db4a` | `test_manifestShipsSentinel` asserts 50,000; all fee tests rerun at 50,000 and at zero |
| F5: deployment inputs not cross-checked | The router has no permit2 getter (`PERMIT2` is `internal immutable` in `PaymentsImmutables`), so the manifest pins `routerCodeHash` (testnet `0xd09ab86e…c84b`, mainnet `0x7f949fe7…ad71`) and `DeployOrderFiller` requires it (`RouterMismatch`). Both scripts require manifest permit2, USDC, Launch hook and app fee recipient (= Launch treasury) to equal Launch's record (`LaunchRecordMismatch`). `verify-trade-filler.py --preflight` rebuilds the router runtime from the pinned build and the router report, checks it equals the bytes the report observed (sha256), that its keccak is `routerCodeHash` and that all three PERMIT2 slots (offsets 3930, 11947, 14462) hold the manifest permit2, and checks the Launch fields and timelock owner; live runs read the router at the pinned block. `--reactor-only` verifies a reactor before any filler exists. `deployments/manifest-5042.json` (mainnet, review only): addresses from Launch's `5042.json`, owner = mainnet timelock `0x94aFdf4c…eb40`, `executionFee` and `feeRecipient` = `REQUIRED_AT_MAINNET_OWNER_GO`; the scripts still refuse chain 5042 | `8ce9f66` | `test_manifestsMatchLaunchRecords`, `test_launchRecordMismatchRefused` (each field by name, wrong record, wrong chain), `test_mainnetManifestIsReviewOnly`, `test_routerCodeHashRequired`, `test_scriptsRefuseOtherChains`; `preflight_self_test` (both manifests clean with only owner choices pending; 12 tampered values refused, including the mainnet timelock as testnet owner; the testnet router against the mainnet manifest and a flipped PERMIT2 byte refused); the gate runs `--preflight` on both manifests and requires a pending choice to be refused without `--allow-pending` |
| TRD-04: no record writer | `script/write-trade-record.py` writes `deployments/<chainId>.json` in Launch's record shape (sorted keys, integer chain and blocks) with reactor, filler, executionFee, feeRecipient, reactorFeeOwner, reactorFeeController, appRecipient, launchHook, usdc, permit2, router, deployBlock, fillerDeployBlock, deployer, version and sourceRevision, only from a completed forge broadcast; it never overwrites a record, and `--previous-record` covers a replacement filler on the recorded reactor | `7689e35`, `a6e648f` | Self-test 18/18 in the gate (pending, missing receipt, failed status, other chain, other contract, receipt address, commit, owner, reactor, fee, sentinel keeper, dry run, existing record, rehearsal rules, replacement). Anvil-fork rehearsal (fork of Arc testnet at block 65262754, chain 5042002): reactor `0xC37B7C35…7118` at block 65262755, filler `0x0ec33fFb…965f` at 65262756; `verify-trade-filler.py --reactor-only --rehearsal` MATCH (reactor 14,758 bytes, keccak `0xdc4591d8…cb2f`, owner and feeController match); the writer produced the record from the two `run-latest.json` files and refused them without `--rehearsal` (owner is not the timelock) and into `deployments/`; full `--rehearsal` verification from that record exit 0 (filler 10,971 bytes, keccak `0xfd962f5b…95a7`; router code hash and PERMIT2 match at block 65262756) |
| TRD-06 / TEST-01: invariant reachability flake | The `expiring` handler settles one order inside the window and refuses one past it on every call, instead of one side per call, so `afterInvariant`'s expired-order and exclusivity checks depend only on the selector being called (about 6e-7 per run, like the other selector-gated checks) rather than a per-call coin flip (about one run in 850) | `dad40b3` | 40 unseeded campaigns each with a fresh `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR`: before the fix 16 of 40 failed ("never saw an expired-order rejection" or "...exclusivity rejection"); after it 40 of 40 passed. Seeded gate (`0x5042`) passes. A first, contaminated attempt reused forge's persisted counterexample and replayed it ("replay failure"), so those numbers are not used |
| TRD-05, F3 / TRD-03, F4, ECON-04, DESIGN-01: governance, trust and replacement documentation | SECURITY.md: component table (filler immutable with no owner; reactor immutable upstream code owned by Launch's timelock, with power over a 0 to 5 bps output fee controller and the ability to stall fills; keeper and cosigner as off-chain keys: the on-chain guarantee is the signed minimum and expiry, the take-profit or stop-loss trigger is the keeper's commitment, a compromised cosigner can fill a stored order at its signed minimum), pause and recovery limits, replacement cost, execution fee custody in the keeper hot wallet (swept to treasury). `docs/runbooks/filler-replacement.md`: triggers, steps (deploy, verify incl. `--reactor-only`, record, switch, retire) and cosigner rotation. README: a new Launch hook needs a new filler | `0db36d2` | Review of the docs |

ECON-04 (optional trigger-validation contract) was not built. The reactor ignores `additionalValidationData` while the
order's validation contract is zero; an on-chain trigger check against the pool's spot price can be manipulated within
the same block and would add a new immutable contract to audit; and the keeper already enforces the trigger. The hard
guarantee remains the trader's signed minimum.

### Bytecode identity

Hashes are `shasum -a 256` of `forge inspect MercuriOrderFiller deployedBytecode` / `bytecode` output, as in
section 17 (raw-byte sha256 in brackets).

| | Before (`2873bf3`) | After (`0db36d2`) |
| --- | --- | --- |
| Runtime | 10,602 bytes, `93b0f0aded6c1d71746dd6729aaa626d4f7a76c5d18bf9f703195e532a9862dd` (raw `7dade0f2…43ac`) | 10,971 bytes, `071edbcdc7e498dd6820bc35fcc0684bd320fab5e97cf431edab8b9d3c449bce` (raw `60cddff4…2953`) |
| Creation | 11,263 bytes, `a72fe07b4e623b4792c6bbdd4b90165464de783abb5169a5bd106a29768f7b2d` (raw `6116d0ca…b999`) | 11,640 bytes, `6237ea72059a3e96eb7e9cb8f265e204591f616238cb6188699f4cf1f371da87` (raw `b8bbf3c0…9879`) |
| Self-test keccak (manifest immutables) | `0x0c151c4d…54a5` (section 16) | `0x3c593855e5be7eb03741e17c661633382268998e06c189ecf7e07b35560a1610` |

ABI: `InvalidOrder` removed; `receive()` and the errors `NotReactor`, `Reentered`, `InvalidOutputs`,
`InvalidOrderCount`, `PoolMismatch`, `AmountOverflow`, `InputTooSmallForFees`, `InputNotConsumed`,
`InsufficientOutput` and `FeeOutputUnsupported` added. Functions, events and the constructor are unchanged. Any ABI
copy, such as the backend's, must be regenerated (`forge inspect MercuriOrderFiller abi --json`).

### Gas

`.gas-snapshot`: 100 rows before, 106 after (the four `UniswapXFillerNativeTest` cases and `test_orderRejectsInvalidOutputs`
in both fee suites added). Across the 100 common rows +2,245,326 gas (+0.366%). A fill costs about 4.3k to 4.5k more
(`test_orderMercuriBuy` +4,540, `test_orderMercuriSell` +4,290, `test_orderOtherBuy` +4,518, `test_orderOtherSell`
+4,291): one more output `balanceOf` in the callback and the `outputSurplus` slot written and cleared in the same
fill. Tests that deploy extra fillers rise with the larger creation code (`test_execFeeConstructorRejectsFeeAboveMax`
+148,106); `test_orderTaxedOutputCannotMeetGrossMinimum` falls 27,743 because the short output now reverts in the
callback. The fee change itself moved +62,843 in total and no fill path. `forge snapshot --check` passes.

### Gates at `0db36d2`

`TRADE_VECTOR_BACKEND=<backend copy> TRADE_VECTOR_WEBUI=<copy> bash script/check-contracts.sh`: exit 0. Upstream
sources 110 and 34 match; source manifest (two files) matches; `forge fmt --check` clean; NatSpec 30 ABI entries, 0
failures; preflight clean for both manifests (testnet pending `feeRecipient`, mainnet pending `executionFee` and
`feeRecipient`) and a pending choice refused without `--allow-pending`; verifier self-tests ok (flipped `usdc`,
`executionFee`, `feeRecipient` and reactor pointer bytes each reported by name); record writer self-test 18/18;
`forge test --fuzz-seed 0x5042` 138 passed, 0 failed, 4 skipped (12 suites); `order_expiring.json` identical in the
three places, SHA-256 `25fbc6bc74d97ca6bb4ec137b9fc1ea5c464d20ade41c885ef24c2a35d1d1f79` (unchanged: the vector does not
embed the filler); snapshot check 105 passed, 1 skipped. The `--stress` run was not repeated for this round.

Open for the go step, unchanged except as stated: the owner chooses `feeRecipient` (D3); the mainnet manifest's
`executionFee` and `feeRecipient`; the real deployment, record and verification; real-chain fill gas.

## 19. Addendum: early guard (hybrid griefing defence)

The owner approved a two-part ("hybrid") defence against traders who make a keeper's fill revert on chain after the
keeper simulated it: an early guard in the filler (this section) and revert classification with trust lanes in the
keeper (backend code, not in this repository). The guard is commit `63c1f11` on `orders/late-cosign`, from `a2062a3`.
Nothing was broadcast and no transaction was sent to any network; `deployments/5042002.json` still does not exist.
**An isolated re-audit of this change is pending**; the independent review of section 18 does not cover it.

### The change

Before calling `reactor.executeWithCallback`, `fill` runs `_requireFundable` on the order it already decodes with the
pinned `V3DutchOrder` ABI (no hand-rolled offsets). It reverts with a new typed error when:

| Error | Guard condition | Condition the reactor or Permit2 already refuses |
| --- | --- | --- |
| `OrderExpired()` | `order.info.deadline < block.timestamp` | `V3DutchOrderReactor._validateOrder`: `DeadlineReached` on the same comparison (Permit2's `SignatureExpired` is `block.timestamp > deadline`, the same set) |
| `NonceUsed()` | `nonceBitmap(swapper, nonce >> 8) & (1 << (nonce & 0xff)) != 0` on the filler's `permit2` | Permit2 `_useUnorderedNonce`: `InvalidNonce` when that bit is already set. `DeployOrderFiller._requireReactor` requires `reactor.permit2()` to be the filler's `permit2` |
| `SwapperBalanceTooLow()` | `input.balanceOf(swapper) < amount` | Permit2 transfers `requestedAmount = order.input.amount` with solmate `safeTransferFrom`; an ERC-20 refuses a transfer above the balance |
| `SwapperAllowanceTooLow()` | `input.allowance(swapper, permit2) < amount` | The same transfer is refused above the trader's allowance to Permit2 |

`amount` is the input the reactor resolves for this block, computed by `_inputAmount` as `V3DutchOrderReactor._resolve`
does: the cosigned `inputAmount` when nonzero (a cosigned input above the signed start is left for the reactor's
`InvalidCosignerInput`), the base-fee adjustment (`_computeDelta`'s rounding with solmate `mulDivDown`/`mulDivUp`, then
`MathExt.boundedAdd(…, 0, maxAmount)`), then `NonlinearDutchDecayLib.decay(V3DutchInput, decayStartBlock, block.number)`.
The decay, bounded arithmetic and mulDiv are the upstream library functions from the pinned 34-file closure; the two
reactor-internal steps (cosigned override and base-fee delta) are re-stated in the filler because they are not library
functions, and their equivalence is tested differentially (below). `block.number` is the reactor's block number on
every chain but Arbitrum's (`BlockNumberish`), Arc included. On Mercurifi's own order shape (fixed input: start = max,
no input curve, no adjustment, no cosigned input; the backend refuses any other) `amount` is the signed input.

What does not change: the guard reads only the order's info and input side and never writes or mutates the decoded
order (the emitted `orderHash` is unchanged, `test_fillEmitsOrderFilled`). Fee, signed minimum, exclusivity, output
override, surplus and `NetMinimumNotMet` rules are untouched. It runs on every fill: `fill` is the only entry point and
the guard sits after `NotKeeper`, `Reentered` and `InvalidOutputs`, before `active` is set.

Only earlier, never looser: every guard revert is a condition under which the reactor or Permit2 would revert anyway at
the same bound, and the guard adds no path to success. Its external calls are static (`view`): the trusted Permit2's
bitmap and the input token's `balanceOf` and `allowance`. A malicious input token can (a) overstate its views: the
guard passes and Permit2's transfer fails as before; (b) understate them or revert: the fill reverts earlier, which
blocks only that token's own orders, and `fill` already called the token's `balanceOf` before this change; (c) burn gas
in a view: bounded by the gas limit the keeper sets for a transaction it chose to send after simulating it. No gas-capped
low-level call was added; the keeper's choice of order and gas limit is the bound, as for the existing `balanceOf`.

### Tests

New `test/integration/UniswapXFillerGuard.t.sol` (9 tests) and the test-only `test/utils/InputProbe.sol` and
`test/utils/MisreportingTradeToken.sol`:

| Test | What it shows |
| --- | --- |
| `test_guardRefusesEachGriefOnEveryPath` | Launch and listed pool, buy and sell (4 paths) x 4 griefs: the keeper's simulation fills; after the grief (balance or allowance left exactly one unit short, nonce cancelled, deadline passed) `fill` reverts with the typed error, trader input and output, keeper and app fee balances are unchanged, and the nonce is untouched unless the grief cancelled it |
| `test_guardMovedBalance`, `test_guardRevokedAllowance`, `test_guardInvalidatedNonce`, `test_guardExpiredOrder` | One griefing path each, on different routes |
| `test_guardExactBoundariesStillFill` | On all 4 paths, balance and allowance exactly the input and a fill at the deadline's own second still fill and take exactly the input: the guard is not stricter than the reactor |
| `test_guardRefusesReplay` | A filled order's replay reverts `NonceUsed` |
| `testFuzz_guardAmountMatchesReactor` | Differential: fuzzed start, max, cosigned input, base-fee adjustment, starting and current base fee, a two-point input curve, decay start and elapsed blocks. `InputProbe` lets the reactor resolve the order and reverts from the callback with the resolved input `R`. Then allowance `R - 1` reverts `SwapperAllowanceTooLow`, balance `R - 1` reverts `SwapperBalanceTooLow`, and exactly `R` of each fills and takes exactly `R`. So the guard's amount equals the reactor's. 513 runs at seed `0x5042`; an instrumented 300-run sample (seed `0x77`) resolved 322 orders, rejected 21 below the 1 USDC floor, and had 292 where the curve, adjustment or cosigned input moved the amount off the signed start (212 above it, 150 with a nonzero adjustment) |
| `test_guardMisreportingTokenNeverFillsWrongly` | Overstated balance with nothing held and overstated allowance with the approval revoked: the guard passes and the reactor refuses (`TRANSFER_FROM_FAILED`), nonce unused. Understated views: `SwapperBalanceTooLow`, nothing moves. Reverting views: the fill reverts. The honest control fills |

Existing tests need no change: those that cancel a nonce, pass the deadline or replay used a bare `vm.expectRevert()`.
The invariant handler's cancellation, expiry and replay actions still see a failed fill with no movement.

### Gas

`test/integration/UniswapXFillerGriefGas.t.sol` measures the same order on the listed pool, ungriefed and after each
grief, with one low-level call from the keeper and `vm.lastCallGas().gasTotalUsed`, under `forge test --isolate`. In
isolation forge runs that call as its own transaction with cold accounts and slots, and `gasTotalUsed` is the whole
transaction: intrinsic 21,000, calldata and execution. Checked with a 4-byte view call on the filler: 21,331 isolated
= 21,000 + 64 calldata + 267 execution, 267 without isolation. Calldata is 11,064 (buy) and 11,076 (sell) gas of each
figure. The test does not depend on the revert reason, so "before" is the same file run against `a2062a3`'s source.
USDC in the fixture is `NativeUsdcShim`, whose transfers use cheatcodes and a CREATE, so the successful fill's absolute
figure is not Arc's; its difference is.

| Path (transaction gas, `--isolate`) | Before `a2062a3` | Reverts with | After `63c1f11` | Reverts with | Change |
| --- | --- | --- | --- | --- | --- |
| Buy, balance moved | 155,858 | `TRANSFER_FROM_FAILED` | 54,171 | `SwapperBalanceTooLow` | -101,687 |
| Buy, Permit2 approval revoked | 155,613 | `TRANSFER_FROM_FAILED` | 57,375 | `SwapperAllowanceTooLow` | -98,238 |
| Buy, nonce invalidated | 128,880 | `InvalidNonce` | 46,707 | `NonceUsed` | -82,173 |
| Buy, deadline passed | 101,291 | `DeadlineReached` | 40,932 | `OrderExpired` | -60,359 |
| Sell, balance moved | 155,831 | `TRANSFER_FROM_FAILED` | 53,797 | `SwapperBalanceTooLow` | -102,034 |
| Sell, Permit2 approval revoked | 153,571 | `TRANSFER_FROM_FAILED` | 57,070 | `SwapperAllowanceTooLow` | -96,501 |
| Sell, nonce invalidated | 129,278 | `InvalidNonce` | 46,719 | `NonceUsed` | -82,559 |
| Sell, deadline passed | 101,689 | `DeadlineReached` | 40,944 | `OrderExpired` | -60,745 |
| Buy, successful fill | 506,839 | | 511,849 | | +5,010 |
| Sell, successful fill | 549,017 | | 554,210 | | +5,193 |

Every griefed revert is now 41k to 57k gas for the whole transaction, below the 60k to 70k target; about a fifth of
each is calldata. The owner's figure for such a revert on chain, about 300k, was not measured here; real-chain gas
remains open.

`.gas-snapshot`: 106 rows before, 116 after (the nine guard tests and the two gas tests). Across the 106 common rows
+5,288,520 gas (+0.821%). A successful fill costs +5,010 (buy) or +5,193 to 5,194 (sell); a revert that reaches the
reactor +5,003. `test_orderMercuriBuy`, `…Sell`, `test_orderOtherBuy` and `…Sell` (both fee suites) fall 56,466 to
56,763 because their closing replay now fails at `NonceUsed`; `test_execFeeNotPaidOnRevert` falls 145,758 (its
cancelled, expired and replayed orders now fail early). Tests that deploy extra fillers rise with the larger creation
code (up to +1,287,195 for `test_execFeeReentrantKeeperCannotDoublePay`). `forge snapshot --check` passes.

### Bytecode identity

Hashes are `shasum -a 256` of `forge inspect MercuriOrderFiller deployedBytecode` / `bytecode` output, as in
section 18 (raw-byte sha256 in brackets).

| | Before (`a2062a3`, = `0db36d2`) | After (`63c1f11`) |
| --- | --- | --- |
| Runtime | 10,971 bytes, `071edbcdc7e498dd6820bc35fcc0684bd320fab5e97cf431edab8b9d3c449bce` (raw `60cddff4…2953`) | 13,062 bytes, `9b55039d6672ccbe6ffbf2aee1b5f97ddcb1d8554b0303af066b3ae612ecd327` (raw `077f275103afe6dfeb18e526b215027c267fb4541a68684680fdd2509dbfdb30`) |
| Creation | 11,640 bytes, `6237ea72059a3e96eb7e9cb8f265e204591f616238cb6188699f4cf1f371da87` (raw `b8bbf3c0…9879`) | 13,738 bytes, `48324df63c1329ddb4c3b32295977978447d0a854615479fb45e9a7f43f88b6d` (raw `5fbb209b4807e165f6f1d87292350505d76be8a82ba9f586cc11e6c6c83398e2`) |
| Self-test keccak (manifest immutables) | `0x3c593855e5be7eb03741e17c661633382268998e06c189ecf7e07b35560a1610` | `0x7c91e0016c4479ee370f298ae33c64dbc973037601ce0fccf14128a7abf46ace` |
| `src/MercuriOrderFiller.sol` sha256 | `0550d570…fa75` | `14149bd68af46a7282e8849d53107432e5ad453a52d5939b586e90438ee12bf9` (in `source-manifest.json`) |

The runtime grows 2,091 bytes (still below EIP-170's 24,576): the upstream decay, `Uint16Array`, bounded-math and
mulDiv code the reactor already uses. Same compiler, settings and pins; no `lib/` change (the closures still match).

ABI: errors `OrderExpired`, `NonceUsed`, `SwapperBalanceTooLow` and `SwapperAllowanceTooLow` added. The ABI now also
lists the upstream library errors `InvalidDecayCurve()` and `IndexOutOfBounds()`, which the guard can raise only for an
order whose input curve the reactor would refuse with the same error. Functions, events and the constructor are
unchanged. Any ABI copy, such as the backend's, must be regenerated (`forge inspect MercuriOrderFiller abi --json`); the
backend's self-caused selector list (`SwapperBalanceTooLow()`, `SwapperAllowanceTooLow()`, `NonceUsed()`) matches these
names. `order_expiring.json` does not embed the filler and is unchanged (`25fbc6bc…1f79`).

forge-lint reports, on the new filler lines, `incorrect-shift` on `1 << (nonce & 0xff)` (a false positive: the
literal is the value shifted, as in Permit2's own `1 << bitPos`), `unsafe-typecast` on the two `int256(...)` casts,
which mirror `_computeDelta` exactly, including where it would revert, and `named-struct-fields`. The existing filler
already carries the same kinds of notes.

### Gates at `63c1f11`

`TRADE_VECTOR_BACKEND=<backend copy> TRADE_VECTOR_WEBUI=<web app copy> bash script/check-contracts.sh`: exit 0, about
10 s with a warm build. Upstream sources 110 and 34 match; source manifest (two files) matches; `forge fmt --check`
clean; NatSpec 34 ABI entries, 0 failures; preflight clean for both manifests (testnet pending `feeRecipient`, mainnet
pending `executionFee` and `feeRecipient`) and a pending choice refused without `--allow-pending`; verifier self-tests
ok (13,062-byte runtime MATCH; flipped `usdc`, `executionFee`, `feeRecipient` and reactor pointer bytes each reported by
name); record writer self-test 18/18; `forge test --fuzz-seed 0x5042` 149 passed, 0 failed, 4 skipped (14 suites);
`order_expiring.json` identical in the three places (`25fbc6bc74d97ca6bb4ec137b9fc1ea5c464d20ade41c885ef24c2a35d1d1f79`);
snapshot check 115 passed, 1 skipped.

Invariants: 40 unseeded campaigns of `test/invariant/*` at the default 64 runs x 64 depth with `fail_on_revert`, each
with a fresh `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR`: 40 of 40 passed, 4,096 calls and 0 reverts per invariant in each.
The `--stress` run was not repeated for this round.

The e2e fixture was regenerated with `TRADE_EXPORT_STATE=true forge test --match-contract TradeLocalStateTest
--match-test test_exportState` (`test-export/` is not tracked).

Open: the isolated re-audit of `63c1f11`; real-chain gas of a griefed and a successful fill; the backend's ABI copy;
and, unchanged, the go-step items of section 18.

## 20. Addendum: on-chain order validation (spec D21, D22, D27)

The owner's 3 October decisions (spec section 10) move the take-profit and stop-loss condition, the pool and the filler
into the trader's signature and check them on chain. The code is commit `ea9006f` on `orders/late-cosign`, from
`0f7dfd4`, then `d48a116` (the verifier reports a missing binding getter cleanly; the validator's NatSpec table is
re-aligned, bytecode byte-identical); this section and the docs follow in the commit after it. Nothing was broadcast and no transaction was sent to
any network; every deployment below ran on a loopback anvil fork, and `deployments/5042002.json` still does not exist.
**An isolated re-audit of this change is pending**; neither the independent review of section 18 nor any other covers
it.

### The change

| Where | Change | Spec |
| --- | --- | --- |
| `src/MercuriOrderValidator.sol` (new) | Implements UniswapX `IValidationCallback.validate(filler, resolvedOrder)`, a view the reactor calls in `_prepare`, before the input transfer. Immutable, no owner, no storage. Immutables `filler` and `poolManager`. Decodes `additionalValidationData` as four words, `abi.encode(uint8 version, uint8 kind, bytes32 poolId, uint160 triggerSqrtPriceX96)`, range-checking each word before narrowing it, so malformed data is a typed refusal, never a decoder revert or panic: length other than 128 bytes or a trigger above 160 bits `InvalidValidationData`, version other than 1 `UnsupportedVersion`, kind above 2 `UnknownKind`, a limit with a nonzero trigger or a take-profit or stop-loss trigger outside `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)` `InvalidTrigger`. Refuses any filler but its own (`WrongFiller`). For kinds 1 and 2 reads the signed pool's `sqrtPriceX96` with v4-core `StateLibrary.getSlot0` (one `extsload`) from the pinned v4-core, refuses an uninitialized pool (`PoolNotInitialized`) and refuses a price that has not reached the trigger (`TriggerNotReached`); a limit is never price-checked | D22 |
| `src/MercuriOrderFiller.sol` | Constructor gains `IPoolManager poolManager_` (zero refused) and deploys `new MercuriOrderValidator{salt: VALIDATOR_SALT}(address(this), poolManager_)`, stored as the immutable `validator`. `fill` refuses an order whose `additionalValidationContract` is not `validator` (`WrongValidator`), after `InvalidOutputs` and before the early guard and the reactor. `reactorCallback` refuses a pool whose `keccak256(abi.encode(key))` is not the signed `poolId` (`PoolNotSigned`), after the existing `PoolMismatch` checks and before any approval or swap. NatSpec: orders are now bound to the filler through its validator (supersedes the E11 sentence) | D22, R7 |
| `script/TradeManifest.sol`, `script/DeployOrderFiller.s.sol` | Manifest field `poolManager`, required to equal Launch's record. The standard CREATE2 deployer's code hash is required. The script predicts the filler (`CREATE2_FACTORY`, `FILLER_SALT`, built creation code with the nine arguments) and the validator (CREATE2 from that filler, `VALIDATOR_SALT`, validator creation code with `(filler, poolManager)`), refuses an occupied filler address, deploys `new MercuriOrderFiller{salt: FILLER_SALT}` and reverts unless both land at their predictions and name each other and the manifest's PoolManager | D22 |
| `deployments/manifest-5042002.json`, `manifest-5042.json` | Gain `poolManager` (`0x8366…0951` on both, from Launch's records). The mainnet manifest still names no reactor: mainnet deploys its own, owned by Launch's mainnet timelock `0x94aF…eb40` (D27). Nothing in this repository names the Uniswap-owned mainnet reactor (owner `0x33f2…51e8`, spec E7) as ours; `test_mainnetManifestIsReviewOnly` asserts the manifest has no `reactor` key | D27 |
| `script/write-trade-record.py` | The filler broadcast must be a `CREATE2` call to the standard deployer whose input is `FILLER_SALT ++ init code`, whose init code is the built filler with exactly the recorded arguments, and whose address is that CREATE2 address (a factory call's receipt carries no contract address); the one contract it created must be the `MercuriOrderValidator` at its predicted address with the built validator init code. The record gains `validator` and `poolManager` | D22 |
| `script/verify-trade-filler.py` | Verifies the validator's runtime (immutables `filler`, `poolManager`) next to the filler's (now with `validator`); checks the binding both ways (each immutable names the other, the validator is the filler's CREATE2 deployment, the filler is the standard deployer's CREATE2 of the built code and manifest arguments, and `filler.validator()` and `validator.filler()` read on chain agree) and the deployer's code hash; adds `poolManager` to the Launch-record preflight. New self-tests: flipped filler `validator`, validator `filler` and `poolManager` bytes, and EIP-1014's own CREATE2 examples | D22 |
| `script/check-natspec.py`, `source-manifest.json`, `script/check-contracts.sh` | NatSpec coverage extended to the validator (54 ABI entries, from 34); the source manifest lists three sources; the gate requires the three new flipped-byte reports by name | |

#### Trigger direction

The trigger is the signed pool's `sqrtPriceX96` (currency1 per currency0, raw units), compared inclusively with the
pool's spot price before the swap. Take-profit fires when the order's rate, output per input, has risen to the
trigger; stop-loss when it has fallen to it. v4 sorts currencies, so the input is currency0 exactly when its address
is lower, and the rate rises with the price exactly then:

| Order | USDC is | Input is | Token's USDC price | Take-profit fires | Stop-loss fires |
| --- | --- | --- | --- | --- | --- |
| Sell token for USDC | currency1 | currency0 | rises with the price | price >= trigger | price <= trigger |
| Sell token for USDC | currency0 | currency1 | falls with the price | price <= trigger | price >= trigger |
| Buy token with USDC | currency0 | currency0 | falls with the price | price >= trigger | price <= trigger |
| Buy token with USDC | currency1 | currency1 | rises with the price | price <= trigger | price >= trigger |

So a sell's take-profit fires as the token's USDC price rises to the trigger and its stop-loss as it falls; a buy's
take-profit as the token's price falls and its stop-loss as it rises. The web app opens buys as limits only today;
the contract handles all four rows. Clients must express the trigger in the signed pool's own orientation.

#### Why the validator is deployed by the filler

Each contract names the other, so neither init code can contain the other's address if both are deployed separately
through the CREATE2 deployer (each init code hash would depend on the other). The filler therefore deploys the
validator itself, with CREATE2 from its own address. Both addresses are still deterministic and predicted before the
broadcast (the filler's from the standard deployer, the validator's from the filler), the pair is created in one
transaction, there is no moment when the filler exists without its validator, and nobody else can deploy that
validator. The filler's init code embeds the validator's creation code (filler creation code 13,738 to 15,671 bytes);
its runtime does not.

### CREATE2 deployer, read-only (`eth_getCode`)

| Network | RPC | Block | Block hash | Code at `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| --- | --- | --- | --- | --- |
| Arc testnet (5042002) | `https://rpc.testnet.arc.network` | 65,275,728 | `0x059b37a03941c9d838b911a575a1b0ece373ac0252ef755501d18042280c8f09` | 69 bytes, keccak `0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989` |
| Arc testnet (5042002) | `https://rpc.testnet.arc.network` | 64,325,644 (the fork pin) | `0x47b31c84b571d202c795d0839d0a2b66fb8276d9796e24b60dec740e391da7c3` | same 69 bytes and keccak |
| Arc mainnet (5042) | `https://rpc.mainnet.arc.io` | 24,040,008 | `0x789b98f14e39856a37eb69b7e4f6fa4296e09b8ecdc36eb0de077d9b87515b30` | same 69 bytes and keccak |

The code is the standard deterministic deployer (`0x7fff…ffe036016000816020823780358282 34f580151560395781 82fd5b80825250505060 14600cf3`,
the same bytes on both networks), which `TradeManifest.CREATE2_FACTORY_CODEHASH` pins. `https://rpc.arc.io` did not
resolve (DNS) from this host on 3 Oct; the mainnet read used `https://rpc.mainnet.arc.io`, the endpoint this
repository's `probe-trade-rpc.py` names. Every request was a read with a `curl` User-Agent; nothing was sent.

### Tests

| Suite / test | What it shows |
| --- | --- |
| `MercuriOrderValidatorTest` (new, real v4 PoolManager, 10 tests) | `test_triggerDirectionTable`: 2 kinds x 2 sides x 2 USDC positions x (one unit before, at, one unit past the trigger) = 24 cases against an oracle written from the token's USDC price, independently of the contract's `input < output` rule: 16 accepted, 8 refused, and in every orientation the trigger itself and exactly one neighbour pass. `testFuzz_triggerDirectionMatchesOracle` (any price and trigger in v4's range, boundary forced often). `test_stopLossFiresOnlyAfterPriceFalls`, `test_wrongFillerRefused`, `test_limitNeedsNoPrice` (passes on a pool that does not exist; nonzero trigger refused), `test_triggerOutsideV4RangeRefused`, `test_uninitializedPoolRefused`, `test_malformedConditionRefused` (13 encodings: empty, the D11 encoding, 127 and 129 bytes, versions 0, 2 and dirty, kinds 3, 255 and dirty, triggers of 2^160 for both kinds, all-zero), `testFuzz_arbitraryDataNeverPanics` (random bytes: only a well-formed limit passes, every refusal is one of the typed errors), `test_constructorAndGetters` |
| `UniswapXFillerTriggerTest` (new, real reactor, filler, validator and Launch fixture, 6 tests) | `test_fillerRefusesOrderWithoutItsValidator` (no validator, and a look-alike validator that also accepts our filler: `WrongValidator`, nothing moved, nonce unused). `test_fillerRefusesPoolOtherThanSigned` (a listed market's Launch pool, an unsigned pool of the same pair with another fee, and the reverse binding: `PoolNotSigned`). `test_triggeredOrdersOnEveryRoute` (Launch and listed pools, token below and above USDC, buy and sell, take-profit and stop-loss: one unit short `TriggerNotReached` with nothing moved, at the price fills). `test_stopLossFillsAfterMarketFalls` (a real swap moves the pool through the trigger). `test_compromiseDrill` and `testFuzz_compromiseExtractionBound`, below |
| Compromise drill (spec §10 bar 12, contract part) | The attacker holds the keeper key (pranks `feeRecipient`) and the cosigner key (cosigns at will, exclusive to our filler or open). On an untriggered protected stop (minimum = today's net value less a 3% band): our filler `TriggerNotReached`; the attacker's own `MercuriOrderFiller` keyed to itself `WrongValidator`; a bare reactor filler `WrongFiller` (open cosign) or `NoExclusiveOverride` (exclusive cosign). The attacker then pushes the signed pool through the trigger with its own swap (R9, same block): the Launch pool and an attacker-made pool of the pair at the trigger price are refused `PoolNotSigned`, the outside filler still `WrongFiller`, nothing moved and the nonce unused. Through the signed pool the fill either pays the victim at least the signed minimum (`extracted <= value - minimum <= value x band`) or reverts with nothing moved. The fixed cases exercise both: a 1e6 push fills within the band, a 100e6 push leaves the order unfilled, for the token below and above USDC; the fuzz covers pushes of 1e6 to 400e6 and both positions |
| `DeployScriptsTest` (+4) | `test_scriptValidatorSaltMatchesFiller`, `test_create2FactoryCodeRequired` (known code accepted, other code `Create2FactoryMismatch`), `test_deployPairLandsAtPrediction` (the script's broadcast lands both at their predictions, naming each other; a changed argument moves both addresses; a second run `AlreadyDeployed`), `test_deployedPairMismatchRefused` (filler off prediction, another validator, another PoolManager). `test_launchRecordMismatchRefused` now also tampers `poolManager`; `test_mainnetManifestIsReviewOnly` asserts no `reactor` key and the record's PoolManager |
| `DeployOrdersForkTest` (new) | `test_create2PredictionOnArcFork`: on an anvil fork of testnet at 64,325,644 the deployer's code hash is the pinned one, a locally deployed reactor owned by the record's timelock, and the script's pair deployment from the manifest lands at the predicted filler `0x80d8…CFbf` and validator `0x30E2…Cf79`, bound to the recorded PoolManager. Also passes on a mainnet fork at 24,040,000 (filler `0x77D9…771f`, validator `0x95Fb…B14e`, with a placeholder keeper and fee). Skipped without `ARC_LOCAL_FORK_RPC` |
| Changed existing tests | The harness signs every order for a filler's validator with a limit condition on the order's pool (`signFor`, `marketKey`, `_condition`). `test_orderWithConditionDataStillFills` became `test_orderWithLegacyConditionDataRefused` (the D11 encoding and empty data refused by the validator; the D22 condition fills). `test_execFeePreFeeOrderFillsThroughNewFiller` became `test_execFeeOrderForAnotherFillerRefused` (R7: an order signed for another filler is refused `WrongValidator`, the signatures differ). Third-party filler tests now expect `WrongFiller` after the exclusive window and for an open cosign (exclusivity is a second, independent barrier). `testFuzz_guardAmountMatchesReactor` probes the reactor with an unvalidated copy of the same input side (the validator never reads amounts). Grief gas gains `test_conditionGas` |
| Invariants | `TradeInvariantsTest` (and its fork variant): every `step` call also runs the four D22 actions: an order with no validator or a look-alike (`WrongValidator`), an order routed through the same token's other pool (`PoolNotSigned`), a take-profit or stop-loss one unit short (`TriggerNotReached`), and the same at the current price (fills, counts toward the execution-fee ghost). Every refusal follows a refused non-keeper attempt and must move nothing, pay nothing and leave the nonce unused; `afterInvariant` requires each of the four in every run; new `invariant_validatorBinding`. Running all four per `step` instead of a sixth selector keeps their per-run reachability as likely as `step` itself (a separate selector missed one in a 64-call run in the first campaign; recorded here, not a contract result) |

### Gas

Isolated transaction gas (`forge test --isolate`, method of section 19), the same listed-pool order:

| Path | `63c1f11` | `ea9006f` | Change |
| --- | --- | --- | --- |
| Buy, successful limit fill | 511,849 | 519,031 | +7,182 (calldata 11,064 to 12,260: +1,196) |
| Sell, successful limit fill | 554,210 | 561,379 | +7,169 (calldata 11,076 to 12,260: +1,184) |
| Buy, take-profit at the trigger | | 520,427 | +1,396 over the limit fill (the price read) |
| Sell, take-profit at the trigger | | 562,799 | +1,420 over the limit fill (+24 calldata) |
| Buy, balance moved / allowance revoked / nonce used / deadline passed | 54,171 / 57,375 / 46,707 / 40,932 | 55,497 / 58,701 / 48,032 / 42,258 | +1,325 to +1,326 |
| Sell, same four | 53,797 / 57,070 / 46,719 / 40,944 | 55,111 / 58,384 / 48,032 / 42,258 | +1,313 to +1,314 |

A limit fill costs about +6,000 in execution: the reactor's call into the validator (a cold account), its decode, and
the filler's `WrongValidator` check, data decode and pool-id hash; the rest is the 160 extra calldata bytes (validator
address word and four condition words). A take-profit or stop-loss adds one cold `extsload` of the pool's slot 0, which
the swap would otherwise warm, about +1,400. Griefed reverts grow mostly by the calldata. Deploying the pair (one
transaction, rehearsal receipt) uses 3,264,199 gas.

`.gas-snapshot`: 116 rows before, 130 after. Three rows left with their renamed or replaced tests
(`test_orderWithConditionDataStillFills` in both fee suites, `test_execFeePreFeeOrderFillsThroughNewFiller`); 17 rows
were added (the new suites and the renamed tests). Across the 113 common rows +15,720,330 gas (+1.975%). The test
rows include harness work that is not contract gas: every market now writes its `PoolKey` to the `marketKey` registry
(three storage slots, about 66k) and each order reads it and the filler's `validator()`; so a single-fill row such as
`test_orderOtherBuy` rises 57,678 (`test_orderMercuriBuy` 77,555), against the +6,000 contract figure above. Tests that
deploy fillers rise with the validator deployment (about 350k per filler, for example
`test_execFeeConstructorRejectsFeeAboveMax` +701,086 and `test_execFeeReentrantKeeperCannotDoublePay` +1,499,568, three
fillers); `test_exportExpiringOrderVector` +738,007 deploys a validator and initializes a pool. Rows fall where a
control fill became a refusal (`test_thirdPartyFillerBlockedInsideWindow` -25,958, `test_thirdPartyFillerCannotFillAfterWindow`
-14,446). `forge snapshot --check` passes.

### Bytecode identity

`forge inspect <contract> deployedBytecode` / `bytecode` output hashed with `shasum -a 256` as in sections 18 and 19
(raw-byte sha256 in brackets). Same compiler, settings and pins; no `lib/` change.

| | Before (`63c1f11`, = `0f7dfd4`) | After (`ea9006f`) |
| --- | --- | --- |
| Filler runtime | 13,062 bytes, `9b55039d6672ccbe6ffbf2aee1b5f97ddcb1d8554b0303af066b3ae612ecd327` | 13,413 bytes, `155b04c3cd980403f63c606c0af2cbe5e860013119baa7c9784f3ca7176487dc` (raw `befb555a0541dc60970fc6baf694830481a74897f4c238c574e4af0b00e70aba`) |
| Filler creation | 13,738 bytes, `48324df63c1329ddb4c3b32295977978447d0a854615479fb45e9a7f43f88b6d` | 15,671 bytes, `ac00c9f3907ea895d68a2733bd024a84427b1236451eca385eb9c949e06bec8e` (raw `13a955427175cab109877fbdd38cfbcb896fe3a37be006c9781a075cd4187f96`) |
| Validator runtime | | 1,222 bytes, `d622f25c3e10d1bed0ae25210fce66b5675a03522c4e99c4e74793c4fc31e914` (raw `775ee89bffc3fbfefafedb280ce5211d0e616538ee9140fa994e92cf2a9e7f01`) |
| Validator creation | | 1,440 bytes, `3ddfd93fad45f94150005a3a13dfc0e72d565d8e5575781781d949e64e2461d5` (raw `e4e42b268d669283c65b1aa4afe2c90891c8f52d0c05ace770cd3e9709e9165d`) |
| Self-test keccak (manifest immutables, placeholder reactor, keeper, filler and validator) | filler `0x7c91e0016c4479ee370f298ae33c64dbc973037601ce0fccf14128a7abf46ace` | filler `0xd84224181321da1372f6e486e8253606f5d66ecebed3b24051b3c61104a0ef9e`, validator `0x8f74eb329798a6c50da55f56c174449163f411e3c4fffc82f73319f7e3575fe6` |
| `src/MercuriOrderFiller.sol` sha256 | `14149bd6…2bf9` | `4ff0fbe472e5a22285bf8fdcd9d0ab87c155b62ff1b4a60a52db16cf4244b2d3` |
| `src/MercuriOrderValidator.sol` sha256 | | `a2f81fd970daae8f338f890f92cd7b38923035dd2c4e43661e0fc92dbb818704` (`780ad88a…c0d1` at `ea9006f`, NatSpec alignment only) |

The filler runtime grows 351 bytes (the validator check, the pool-id check and the `validator` and `VALIDATOR_SALT`
getters). Both are far below EIP-170.

ABI. Filler: constructor gains `poolManager_`; functions `validator()` and `VALIDATOR_SALT()`; errors `WrongValidator()`
and `PoolNotSigned()`. Validator: `validate`, `filler()`, `poolManager()`, `VERSION()`, `KIND_LIMIT()`,
`KIND_TAKE_PROFIT()`, `KIND_STOP_LOSS()`, and errors `ZeroAddress`, `WrongFiller`, `InvalidValidationData`,
`UnsupportedVersion`, `UnknownKind`, `InvalidTrigger`, `PoolNotInitialized`, `TriggerNotReached`. A fill can now revert
with a validator error (bubbled through the reactor); the keeper's revert classification needs the validator ABI.
Exported with `forge inspect <contract> abi --json` to the session scratchpad (`filler-abi.json` sha256
`f3dc2cc97fd59179c2e5c3ae98b5298761395da7500dbf8cf2507d6004964d75`, `validator-abi.json`
`fc37cc99b7b682c649d437fa08461d30199bb480280711ead10256773672d121`); the backend's copies are not updated here.

### Loopback rehearsal at `ea9006f`

Anvil forked `https://rpc.testnet.arc.network` at block 65,275,728 on port 8550 (`--fork-header "User-Agent: curl/8.7.1"`).
`DeployTestnetReactor` (rehearsal owner: anvil account 1) then `DeployOrderFiller` (rehearsal keeper: anvil account 2),
sender anvil account 0, both with `--broadcast` to the loopback anvil only:

| Item | Value (fork-only) |
| --- | --- |
| Reactor | `0xC37B7C35aD214bB8c11Ee49E3c4483d3B33A7118`, block 65,275,729, runtime keccak `0xd7a5867bd6bea358f040527c10ba7ab2e76ce071e7b7be6181b26a0c1e7e7dcb` (profile `small`, unchanged) |
| Filler | `0xDE23A3b9E70dF562E6E97Beca6323913CabaaBFE`, block 65,275,730, the script's prediction; runtime keccak `0x53a0c31b338556821b27a223706b254a782ae531abd77262079951b3bcd12351` |
| Validator | `0x28Fbd127F04eE06c54f9D26BA4c0FBe98dFBa92E`, the script's prediction; runtime keccak `0xee298477e1ded9872c0f297fe484cc3d36590197b5d47ee9e95e9d16dde2e035` |

The same addresses came out of an earlier rehearsal on a fork at another block: the CREATE2 addresses do not depend
on the sender's nonce. `write-trade-record.py --rehearsal` wrote the record (with `validator`, `poolManager` and
`sourceRevision` `ea9006fb8ed3d2aec19bcd353ae127d3fa34de54`) into the scratchpad, and `verify-trade-filler.py --rehearsal
--block 65275730` exited 0: reactor, filler and validator MATCH; "validator … is the filler's own CREATE2 deployment";
"filler … is the standard deployer's CREATE2 of the built code with the manifest arguments"; "binding read on chain:
filler.validator() and validator.filler() name each other"; router, reactor owner and fee controller match. With the
record's validator replaced by the reactor's address, or by an address without code, it exited 1: the filler MISMATCH
inside `validator`, the validator MISMATCH, "is not the CREATE2 address", and the on-chain binding read reported as a
revert or an empty return.

### Vector and fixture

`test_exportExpiringOrderVector` regenerates `test-export/trade-orders/order_expiring.json`. The order now names a
`MercuriOrderValidator` bound to the vector's filler, with `additionalValidationData = abi.encode(1, 1, poolId,
trigger)`: a take-profit on a hookless pool of the two vector tokens initialized at the order's own rate, so the order
is exactly at its trigger. The test still proves it a real order (refused for another filler inside the window, filled
by the named filler at block 1020, dead at 1021) and adds that another filler is refused `WrongFiller` past the window.
New fields: `validator`, `poolId`, `kind`, `triggerSqrtPriceX96` (a decimal string) and `additionalValidationData`.
SHA-256 `0bc97dd52d2036c3999bff8cb625992ffa8e5d6a194c2e33f5b7555dfa5e0e3a` (deterministic across runs), copied
uncommitted to the backend's `internal/orders/testdata/order_expiring.json` and the web app's
`src/lib/trade/__fixtures__/order_expiring.json`; the gate confirms the three copies identical. `order.json` (the legacy
pre-cosigned vector) is unchanged (`79365514…acca`). The backend's `Order.Condition` still parses the D11 encoding and
rejects any validation contract, so its tests that read this vector fail until the backend adopts D22.

`TRADE_EXPORT_STATE=true forge test --match-contract TradeLocalStateTest --match-test test_exportState` regenerates the
e2e fixture: the four uncosigned limit orders name the filler's validator with a limit condition on their own pool,
`anvil-order.json` gains `validator`, and `anvil-state.json` holds the reactor, filler and validator code.

### Residual risks

- **R7.** The filler and its validator are bound together and orders name the validator. A replacement (including a
  keeper key rotation) strands open orders on the old pair, fillable only by the old keeper key; runbook updated.
- **R9.** The validator reads the pool's current spot price. An attacker holding both keys can push it through a
  trigger in the same block and fill there. The signed minimum bounds the loss (the band, for a protected stop),
  proven by the compromise drill; the six-block hold stays off chain and does not bind a compromised keeper.
- The trigger compares the spot price before the swap, not the execution price; the fill's own price impact and fees
  are bounded only by the signed minimum (D21's band rule sizes it).
- A pool with an unexpected hook could move its own price during a swap; the backend admits only the Launch hook or
  no hook (spec D12), and the trader signs the pool.

### Gates at `d48a116`

`TRADE_VECTOR_BACKEND=<backend copy> TRADE_VECTOR_WEBUI=<web app copy> bash script/check-contracts.sh`: exit 0 (also at
`ea9006f`, 3 min 40 s on a cold build). Upstream sources 110 and 34 match; source manifest (three files) matches; `forge fmt
--check` clean; NatSpec 54 ABI entries, 0 failures; preflight clean for both manifests (testnet pending `feeRecipient`,
mainnet pending `executionFee` and `feeRecipient`) and a pending choice refused without `--allow-pending`; verifier
self-tests ok, with the filler `usdc`, `executionFee`, `feeRecipient`, `validator`, the validator `filler` and
`poolManager` and the reactor pointer byte each reported by name, and the EIP-1014 examples reproduced; record writer
self-test 26/26; `forge test --fuzz-seed 0x5042` 171 passed, 0 failed, 5 skipped (17 suites); `order_expiring.json`
identical in the three places (`0bc97dd5…0e3a`); snapshot check 129 passed, 1 skipped.

Invariants: 40 unseeded campaigns of `test/invariant/*` at `ea9006f`, the default 64 runs x 64 depth with
`fail_on_revert`, each with a fresh `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR` (`mktemp -d`): 40 of 40 passed, 4,096 calls
and 0 reverts for each of the three invariants (`invariant_executionFeePerFill`, `invariant_tradeCustodyAndApprovals`,
`invariant_validatorBinding`) in every campaign, 252 s in all; no failure was persisted in any of the 40 directories.
Every run's `afterInvariant` required at least one of each D22 refusal and one triggered fill.

Stress: `ARC_LOCAL_FORK_RPC=<loopback anvil fork of https://rpc.testnet.arc.network at 64,325,644>
TRADE_FORK_CHAIN_ID=5042002 TRADE_FORK_BLOCK=64325644 bash script/check-contracts.sh --stress` at `d48a116`: exit 0 in
526 s. With the fork set the default suite ran 185 passed, 0 failed, 2 skipped (the fork suites, including
`DeployOrdersForkTest`, did not skip); `verify-trade-router.py` passed; `FOUNDRY_FUZZ_RUNS=10000` over every
non-invariant suite 179 passed, 0 failed, 2 skipped (15 suites); invariants at 1024 runs x 256 depth, `fail_on_revert`,
seed `0x5042002`, for `TradeInvariantsTest` and `TradeForkInvariantsTest`: 6 of 6 passed, 262,144 calls and 0 reverts
each, nothing persisted. This stress run left the vector copy check out (both variables unset): a concurrent session in
the backend tree had restored that repository's committed `order_expiring.json` (`25fbc6bc…1f79`) while the first
attempt ran, and that attempt stopped at the copy check. The copies were written again and the gate above confirms all
three identical.

Open: the isolated re-audit of `ea9006f`; the backend (D22 encoding, validator address in `/v1/network`, revert
classification with the validator's errors, ABI copies) and the web app (encoding, trigger as the pool's
`sqrtPriceX96` in its orientation) must adopt the new vector; `CLAUDE.md`/`AGENTS.md` still describe `src/` as the
filler alone; real-chain gas; and, unchanged, the go-step items of section 18.
