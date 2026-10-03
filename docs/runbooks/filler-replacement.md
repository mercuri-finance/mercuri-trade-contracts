# Runbook: replacing the order filler and its validator

`MercuriOrderFiller` and the `MercuriOrderValidator` it deploys are immutable and bound to each other for life. Any
change to what either does, who may call the filler or what it charges is a new filler, and every new filler deploys
its own new validator (spec D22). Signed orders do not move to the new pair: each order names its validator in the
trader's signature, and that validator accepts only its own filler. Open orders stay fillable only through the old pair,
by the old keeper key, until they expire (at most 30 days) or their traders sign again (spec R7).

Nothing here authorises a broadcast. Each deployment is its own owner go, with `--account` or `--ledger`, testnet
first.

## When a new filler is needed

| Trigger | Why it needs a new filler |
| --- | --- |
| A filler bug fix | The bytecode cannot change |
| Keeper key rotation, planned or after a compromise | `feeRecipient` is both the fee recipient and the only address allowed to call `fill` |
| An execution fee change | `executionFee` is an immutable, bounded by `MAX_EXECUTION_FEE` (0.10 USDC) |
| A new Launch hook | `launchHook` is an immutable. Pools of any other hook take the listed-pool path: they pay the app fee and the trader loses Launch's referral credit |
| A new route (another router entry point, more than one pool per fill) | The swap recipe is fixed in the filler |
| A validator change (a new condition version or kind, another price source) | The validator is fixed for the filler's life and the filler names it |
| A new app fee recipient | `appRecipient` is an immutable; it must stay Launch's treasury |

A new reactor is a different, larger change: every open order must be signed again by its trader.

## Steps

1. **Manifest.** Change only what the trigger needs in `deployments/manifest-<chainId>.json` (for a keeper rotation,
   `feeRecipient`), in a reviewed commit. Run `python3 script/verify-trade-filler.py --preflight` and
   `bash script/check-contracts.sh`; both must pass with no pending owner choice.
2. **Rehearse.** On a loopback anvil fork of the target network, run the deployment with `TRADE_LOCAL_REHEARSAL=true`,
   write the record with `script/write-trade-record.py --rehearsal --out-dir <scratch>` and verify it with
   `verify-trade-filler.py --rehearsal`. Nothing from the rehearsal goes into `deployments/`.
3. **Deploy.** Keep the reactor. Run `script/DeployOrderFiller.s.sol` with `TRADE_REACTOR` and
   `TRADE_REACTOR_CODEHASH` from the current record and verification. It refuses a reactor whose code hash, permit2,
   owner or fee controller differ, a router whose code hash differs, a CREATE2 deployer other than the standard one,
   and any manifest value that disagrees with Launch's record. It prints the predicted filler and validator addresses,
   deploys the filler through the standard CREATE2 deployer (the filler deploys the validator), and reverts unless both
   land at their predictions and name each other. If a new reactor is part of the change, deploy it first with
   `script/DeployTestnetReactor.s.sol` and verify it alone with `verify-trade-filler.py --reactor-only` before any
   filler is deployed against it.
4. **Record.** Archive the current `deployments/<chainId>.json` as `deployments/archive/<chainId>-<deployBlock>.json`,
   then run `script/write-trade-record.py --filler-broadcast broadcast/DeployOrderFiller.s.sol/<chainId>/run-latest.json
   --previous-record deployments/archive/<chainId>-<deployBlock>.json` (or `--reactor-broadcast` for a new reactor).
   It writes only from a completed broadcast whose arguments match the manifest, and records the validator only when
   it is the one contract the filler created, at its predicted CREATE2 address.
5. **Verify.** Run `verify-trade-filler.py --rpc <rpc> --block <fillerDeployBlock> --deployment
   deployments/<chainId>.json`. Every byte of the reactor, filler and validator, the binding both ways (each names the
   other; the validator is the filler's CREATE2 deployment; the filler is the standard deployer's CREATE2 of the built
   code with the manifest's arguments), the reactor's owner and fee controller, and the router's code hash and PERMIT2
   bytes must match.
6. **Switch.** Point the keeper and the API at the new pair (and, for a rotation, the new keeper key) in one
   configuration change: the API publishes the new validator, so new orders name it, and the cosigner names the new
   filler as exclusive filler. Orders signed before the switch name the old validator and can only be settled by the
   old filler: the keeper must choose the filler whose `validator()` the order names.
7. **Serve or retire the old pair.** Neither can be disabled. Without a compromise, keep the old filler and its keeper
   key serving orders signed for it until the last one expires (at most 30 days) or its trader signs again, then stop
   using it. After a key compromise, prompt every affected trader to cancel (Permit2 `invalidateUnorderedNonces`, or
   cancel all) and sign again; until they do, the old keeper and cosigner keys can fill an order only through the old
   filler and its signed pool, and a take-profit or stop-loss only once its trigger is reached on chain, at or above
   the signed minimum (loss at most the band times the notional, spec D21 and D22). Rotate the cosigner too (below).
   Sweep the old keeper wallet's execution fees to the treasury.
8. **Record the release.** Update the release report with the new source revision, bytecode hashes, record and
   verification output.

## Cosigner rotation

The cosigner address is in each signed order, so a new cosigner applies to orders signed after the switch.

1. Create the new cosigner key in the keeper's key store and publish its address through the API configuration, so
   the web app puts it in new orders.
2. Keep the old key available to the keeper only for orders signed with it, until they expire or are cancelled. After a
   compromise, do not wait: ask the affected traders to cancel (Permit2 `invalidateUnorderedNonces`) and sign again.
   With the keeper key as well, the old cosigner key can fill their stored orders through our filler and signed pool
   once each condition holds on chain, at no less than the signed minimum.
3. No contract changes: the filler and the reactor do not store the cosigner.
