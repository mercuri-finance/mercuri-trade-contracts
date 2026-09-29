# Contributing

This is the working repository for mercurifi trade's contracts. Unlike the
published Launch record it takes changes, but under the same discipline.

- Every change is made as `mercurifinance`: login, author, committer and push
  transport. See the identity gate in `arc.launch/docs/agents/release.md`.
- A change to `src/` comes with its tests and an updated `lib-versions.md`
  when a pin moves. `forge build` and `forge test --no-match-contract
  TradeForkInvariants` must pass; run the fork invariants against a loopback
  Anvil fork before anything that touches settlement.
- `lib/uniswapx` and `lib/universal-router` are unchanged upstream closures.
  `python3 script/check-trade-sources.py` must keep passing; a new upstream
  revision is a deliberate pin, recorded with its commit and reason.
- Launch's contracts are a dependency, never edited here. If Trade needs
  something from Launch, it is a Launch release first.
- Nothing here is deployed. A deployment is its own release: review, a
  deployment record under `deployments/`, evidence, and the owner's go.

Security reports go through GitHub's private reporting; see `SECURITY.md`.
