# Contributing

This private repository is the working repository for mercurifi trade's contracts. Unlike the published Launch
record it takes changes, but under the same discipline. Nothing here is deployed; merging a change never authorizes
a contract transaction.

## What a change needs

- **Identity.** Every change is made as `mercurifinance`: login, author, committer and push transport. See the
  identity gate in `arc.launch/docs/agents/release.md`.
- **Tests.** A change to `src/` comes with its tests and an updated `lib-versions.md` when a pin moves.
  `bash script/check-contracts.sh` must pass; run the fork invariants (`--stress`) against a loopback Anvil fork
  before anything that touches settlement.
- **Pins.** `lib/uniswapx` and `lib/universal-router` are unchanged upstream closures.
  `python3 script/check-trade-sources.py` must keep passing; a new upstream revision is a deliberate pin, recorded
  with its commit and reason.
- **Launch.** Launch's contracts are a dependency, never edited here. If Trade needs something from Launch, it is a
  Launch release first.

## What happens to a deployment

A deployment is its own release: review, a deployment record under `deployments/`, evidence, and the owner's specific
release authorization. Security reports go privately through **Security → Report a vulnerability** on the public
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts) repository, naming Trade and the
filler; see [`SECURITY.md`](SECURITY.md).

## Building

```sh
git submodule update --init --recursive
bash script/build-trade-router.sh
forge build
bash script/check-contracts.sh
```

`forge build` uses the pinned toolchain in `foundry.toml`, the vendored `lib/` closures and the Launch submodule. The
contract gate also needs Python 3; it checks the source manifests, formatting, NatSpec and the runtime verifier's
offline self-tests, then runs the tests and the gas snapshot.
