# MercuriOrderFiller testnet release package — 2 Oct 2026 (rehearsal evidence)

This is the start of the A5 release-evidence packet. It records a rehearsal on a loopback Arc testnet fork only. Nothing was broadcast to Arc testnet or mainnet, no `deployments/5042002.json` exists, and the owner has not chosen `reactorFeeOwner`.

The 29 Sep report `docs/reports/2026-09-29-filler-assurance.md` predates the rename of `LocalOrderFiller` to `MercuriOrderFiller`; read its findings as describing the same contract under its former name.

## Package

| File | Purpose |
| --- | --- |
| `deployments/manifest-5042002.json` | Testnet constructor inputs. `reactorFeeOwner` is the literal `REQUIRED_AT_D2_OWNER_GO`. |
| `script/DeployTestnetReactor.s.sol` | Deploys the pinned `V3DutchOrderReactor(permit2, reactorFeeOwner)`. |
| `script/DeployOrderFiller.s.sol` | Deploys `MercuriOrderFiller` against `TRADE_REACTOR`. |
| `script/TradeManifest.sol` | Shared manifest reader, chain guard, code-presence guard. |
| `script/verify-trade-filler.py` | Byte-for-byte runtime verifier with `--self-test`. |
| `test/local/DeployScripts.t.sol` | Proves the sentinel and any other chain stop both scripts. |

Both scripts refuse `block.chainid != 5042002`, require code at permit2, router, usdc, launchHook and reactor, contain no key, and need `--account` or `--ledger` at the go step. Both refuse to run unless `reactorFeeOwner` parses as an address. `TRADE_LOCAL_REHEARSAL=true` with `REACTOR_FEE_OWNER_OVERRIDE=<address>` replaces it for a loopback rehearsal and prints a loud warning; it must never be set at the real deployment.

## Manifest values and read-only code lengths (`eth_getCode`, testnet RPC, latest at 2 Oct 2026)

| Field | Address | Code bytes |
| --- | --- | --- |
| permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | 9152 |
| router | `0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1` | 24546 |
| usdc (Launch record `.usdc`) | `0x3600000000000000000000000000000000000000` | 1798 |
| launchHook (Launch record `.launchHook`) | `0x87e6BaBAc4598F99f4A0717ad294934455Fe60cc` | 3431 |
| appRecipient | `0xc914763d1652931dc3874B75387B3886aBAcF891` | 0 (an externally owned account) |

## Fork rehearsal

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

Verifier notes. Immutables are substituted from the manifest and deployment (filler: reactor, router, permit2, usdc, launchHook, appRecipient; reactor: permit2). The reactor also holds an internal function-pointer immutable, `_getBlockNumberish`, which via-IR stores as a small compiler-assigned function id. Source and manifest cannot supply it, so the verifier takes it from an `eth_call` constructor simulation of the same creation bytecode at the pinned block and requires it to be at most 0xFF; every other byte is compared against the rebuilt source. The reactor owner is read from `owner()` and compared with the deployment record, since it lives in storage, not in runtime code. The verifier tries each built reactor profile and accepts an exact match; forge selected `small` for the script build.

Self-test (no network):

```
filler self-test: MATCH 9838 runtime bytes, keccak 0x351554fc...a32fada
filler self-test (one immutable byte flipped): MISMATCH at offsets [393] (inside immutables: usdc)
self-test ok: unmodified runtime matches, flipped immutable byte is rejected
```

`--self-test-flipped` runs the flipped case on its own and exits 1; `check-contracts.sh` runs `--self-test` and asserts that `--self-test-flipped` fails.

## Gates

`bash script/check-contracts.sh` passes, including the new self-test and `DeployScripts.t.sol` (sentinel refusal for both scripts, a positive control that the reactor script runs with the rehearsal override, wrong-chain refusal, and the manifest shipping the sentinel). `MercuriOrderFiller` was already the sole entry in `source-manifest.json` (`check-local-source.py`) and in `check-natspec.py`; the runtime-identity step is the new self-test above. The reactor and router are covered by the upstream source manifests and `verify-trade-router.py`.

`ARC_LOCAL_FORK_RPC=http://127.0.0.1:18545 TRADE_FORK_CHAIN_ID=5042002 TRADE_FORK_BLOCK=65100759 bash script/check-contracts.sh --stress` passed (exit 0) against a fresh fork at block 65100759. The fork suites ran and did not skip: `UniversalRouterFork` 10 passed, `TradeForkInvariants` 1024 runs and 262144 calls, 0 reverts. The one skipped test in the output is `TradeLocalState`, which is not a fork suite.

Rehearsal caveat: the same stress run against the anvil instance that had just received the two rehearsal deployments timed out in both fork suites (anvil stopped answering RPC, 45 s client timeouts). Two attempts hung the same way. A fresh fork at the same block passes. This is a loopback-tooling limitation, not a contract result.

## Open for the go step

- Owner names `reactorFeeOwner`; replace the sentinel in the manifest in the same reviewed change.
- Real deployment needs `deployments/5042002.json` written from the verified output (`reactor`, `reactorFeeOwner`, `filler`, `router`, `permit2`, `usdc`, `launchHook`, `appRecipient`, `block`, `blockHash`, `fillerRuntimeKeccak`, `reactorRuntimeKeccak`, `sourceRevision`, `compiler`), then `verify-trade-filler.py` at that block.
- A5 completes this packet.
