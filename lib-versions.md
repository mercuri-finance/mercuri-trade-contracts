# Library versions

`lib/mercuri-launch-contracts` is a Git submodule of the public
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts)
repository, pinned to the commit recorded in `.gitmodules`/`git submodule status`.
It brings the deployed Launch sources this repository builds against, and the
Uniswap v4, Permit2, OpenZeppelin and forge-std trees Launch itself pins (see its
own `lib-versions.md`). The Launch test scaffolding under `test/utils/` and
`test/utils/launch/` was copied from the `arc.launch/contracts` working tree on
29 September 2026 so the Trade tests build here without Launch's private test
tree; keep it in step with Launch when that tree changes.

## Trade router local tests — 2026-09-27

`lib/universal-router` pins Uniswap/universal-router revision
`999d561c3ad58fb5cab91b602911f3c75591a9c7`, selected by the official deployment
registry at Uniswap/contracts revision `02fd176` for Arc router
`0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1`.
This is the compiler import closure (110 unchanged Solidity files), not the full
upstream checkout. `source-manifest.json` records the keccak256 of each source.
Nested dependency licenses accompany the sources.

The router builds separately with Solidity 0.8.26, Cancun, via-IR, optimizer
4444 and no metadata bytecode hash. Run `bash script/build-trade-router.sh`.
Canonical Mercurifi compiler profiles and production contracts are unchanged.
Both deployed runtimes match the reproduced router after all immutable values
are reconstructed, including each chain's EIP-712 domain. Evidence:
`docs/reports/2026-09-27-trade-router-comparison.json` in the arc.launch workspace.

## Local UniswapX order integration

`lib/uniswapx` contains the 34-file compiler closure of Uniswap/UniswapX
`eb7ce077036258b9510b42ad37aa920cf3aaf308` for `V3DutchOrderReactor`.
Sources are unchanged, accompanied by licenses and `source-manifest.json`.
`python3 script/check-trade-sources.py` verifies both compiler closures.
The two unscoped `openzeppelin-contracts/utils/math/` and
`openzeppelin-contracts/security/` aliases support Solar lint's handling of
context remappings; deployed Mercurifi imports use their existing prefixes.

The reactor and `src/LocalOrderFiller.sol` are local test deployments.
They are absent from tracked deployment records and the release manifest.
The filler builds typed single-pool R1–R4 swaps, enforces net output and full
input consumption, and sends surplus to the signed trader. It is a local
candidate, not a reviewed production deployment.
