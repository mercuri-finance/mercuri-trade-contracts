# Security

## Reporting a vulnerability

This repository is private, so GitHub's private reporting does not reach it. Report privately through
**Security → Report a vulnerability** on the public
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts) repository, naming Trade and
the filler. The report is visible only to the maintainers until a fix is deployed and disclosed. Please do not open a
public issue for anything that could be exploited.

Include the contract and function, the chain (testnet 5042002), a transaction or a Foundry test that
shows the behaviour, and what you think the impact is. You will get an acknowledgement within 48 hours and updates as
the fix moves.

## Scope

The contract in `src/`, `MercuriOrderFiller`, and the deployment scripts in `script/`. Nothing is deployed yet; once
it is, the scope is the addresses in the deployment records under `deployments/`. The vendored dependencies under
`lib/` are upstream code, and Launch's contracts are in their own public repository; report defects in them there as
well.

Out of scope: the web app, the API and the hosting, which are not in this repository. The keeper's own code is out of
scope; keeper or cosigner behaviour that lets a fill break the filler's guarantees is in scope. Findings that require a
compromised keeper key are a trust boundary rather than a defect: that key alone can call `fill` and receives the
execution fee, so rotating it means a new filler.

## What already exists

- Release evidence for the filler candidate: `docs/reports/2026-10-02-order-filler-release.md`.
- Reproducible bytecode: `python3 script/verify-trade-filler.py` after `forge build`. Until a deployment record exists
  it runs in `--self-test` mode against the freshly built artifacts.
- The filler is immutable, with no owner, pause, upgrade or rescue path; only the configured keeper can call `fill`.

No independent review or professional third-party audit has been performed yet.
