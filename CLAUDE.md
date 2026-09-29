# mercurifi trade contracts — Claude

This is a separate Git repository: Trade's contract set, apart from Launch's.
Launch's deployed contracts live in `lib/mercuri-launch-contracts` (a pinned
submodule of the public repository) and in the canonical public
`contracts/launch/deployments/` records; never change them here, and never change them for a Trade feature
without flagging it to the owner as a live-contract change. Trade adds no
deployed contract yet: `src/LocalOrderFiller.sol` is a local candidate, absent
from every deployment record.

Before any commit, push, PR or issue, follow the identity gate in
`../../docs/agents/release.md` in the Mercurifi workspace: the active GitHub login, the commit author
and committer, and the push transport must all be `mercurifinance`; use the
HTTPS remote so the pusher is recorded as `mercurifinance`. No AI
`Co-authored-by` trailer.

Local `forge` builds and tests do not authorize a broadcast, an upgrade, a
Safe or governance action, or a deployment record. Do not read `.env` or
expose signer material. Keep `lib/uniswapx` and `lib/universal-router` as
unchanged upstream closures (`python3 script/check-trade-sources.py`); a
change to either is a new pin recorded in `lib-versions.md`.
