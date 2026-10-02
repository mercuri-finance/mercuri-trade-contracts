# Vendored dependencies (upstream closures committed as plain files; Launch as a pinned submodule)

| Path | Package | Version |
| --- | --- | --- |
| `lib/mercuri-launch-contracts` | mercuri-finance/mercuri-launch-contracts | Git submodule at `99d7c28a19e254e5c1cf0444819ddabae3e9c469` |
| `lib/universal-router` | Uniswap/universal-router | `999d561c3ad58fb5cab91b602911f3c75591a9c7`, 110-file compiler closure |
| `lib/uniswapx` | Uniswap/UniswapX | `eb7ce077036258b9510b42ad37aa920cf3aaf308`, 34-file compiler closure |

`lib/mercuri-launch-contracts` is a Git submodule of the public
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts) repository, pinned to commit
`99d7c28a19e254e5c1cf0444819ddabae3e9c469` (`git submodule status`). It brings the deployed Launch sources this
repository builds against, and the Uniswap v4, Permit2, OpenZeppelin and forge-std trees Launch itself pins (see its own
`lib-versions.md`). The Launch test scaffolding under `test/utils/` and `test/utils/launch/` was copied from the
`arc.launch/contracts` working tree on 29 September 2026 so the Trade tests build here without Launch's private test
tree; keep it in step with Launch when that tree changes.

## Trade router local tests — 2026-09-27

`lib/universal-router` pins Uniswap/universal-router revision `999d561c3ad58fb5cab91b602911f3c75591a9c7`, selected by
the official deployment registry at Uniswap/contracts revision `02fd176` for Arc router
`0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1`. This is the compiler import closure (110 unchanged Solidity files), not
the full upstream checkout. `source-manifest.json` records the keccak256 of each source. Nested dependency licenses
accompany the sources.

The router builds separately with Solidity 0.8.26, Cancun, via-IR, optimizer 4444 and no metadata bytecode hash. Run
`bash script/build-trade-router.sh`. Canonical Mercurifi compiler profiles and production contracts are unchanged.
Both deployed runtimes match the reproduced router after all immutable values are reconstructed, including each
chain's EIP-712 domain. Evidence: `docs/reports/2026-09-27-trade-router-comparison.json` in the arc.launch workspace.

## Local UniswapX order integration

`lib/uniswapx` contains the 34-file compiler closure of Uniswap/UniswapX `eb7ce077036258b9510b42ad37aa920cf3aaf308`
for `V3DutchOrderReactor`. Sources are unchanged, accompanied by licenses and `source-manifest.json`.
`python3 script/check-trade-sources.py` verifies both compiler closures. The two unscoped
`openzeppelin-contracts/utils/math/` and `openzeppelin-contracts/security/` aliases support Solar lint's handling of
context remappings; deployed Mercurifi imports use their existing prefixes.

The reactor and `src/MercuriOrderFiller.sol` are not deployed: no deployment record exists, and the testnet inputs in
`deployments/manifest-5042002.json` still hold the owner-choice sentinels. The filler builds typed single-pool R1–R4
swaps, enforces net output and full input consumption, and sends surplus to the signed trader. It is a release
candidate with evidence in `docs/reports/2026-10-02-order-filler-release.md`, not yet independently reviewed.

## Reproducible source identity

| Item | Identity |
| --- | --- |
| `lib/mercuri-launch-contracts` | submodule commit `99d7c28a19e254e5c1cf0444819ddabae3e9c469` |
| `lib/uniswapx` | Uniswap/UniswapX `eb7ce077036258b9510b42ad37aa920cf3aaf308`, checked by `script/check-trade-sources.py` |
| `lib/universal-router` | Uniswap/universal-router `999d561c3ad58fb5cab91b602911f3c75591a9c7`, checked by `script/check-trade-sources.py` |
| `src/MercuriOrderFiller.sol` | sha256 in `source-manifest.json`, checked by `script/check-local-source.py` |

Build with Solidity 0.8.26, Cancun, via-IR and the per-path optimizer profiles in `foundry.toml`. The executable used
for the release evidence identifies itself as Foundry 1.4.3-Homebrew, build timestamp `2025-10-22T03:58:23Z`; it
reports `VERGEN_IDEMPOTENT_OUTPUT` instead of an upstream commit. Its SHA-256 is
`7a91e6efdcbb02203367c2c8c7e54928b7d1f3c6e636f7393c73b6201a9020c6`.
