# Runbook: replacing the order filler

`MercuriOrderFiller` is immutable. Any change to what it does, who may call it or what it charges is a new filler. Signed
orders survive a replacement: they bind to the reactor and the cosigner, not to the filler, and the cosigner names the
filler as exclusive filler only when it cosigns at fill time.

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
   owner or fee controller differ, a router whose code hash differs, and any manifest value that disagrees with
   Launch's record. If a new reactor is part of the change, deploy it first with `script/DeployTestnetReactor.s.sol`
   and verify it alone with `verify-trade-filler.py --reactor-only` before any filler is deployed against it.
4. **Record.** Archive the current `deployments/<chainId>.json` as `deployments/archive/<chainId>-<deployBlock>.json`,
   then run `script/write-trade-record.py --filler-broadcast broadcast/DeployOrderFiller.s.sol/<chainId>/run-latest.json
   --previous-record deployments/archive/<chainId>-<deployBlock>.json` (or `--reactor-broadcast` for a new reactor).
   It writes only from a completed broadcast whose arguments match the manifest.
5. **Verify.** Run `verify-trade-filler.py --rpc <rpc> --block <fillerDeployBlock> --deployment
   deployments/<chainId>.json`. Every byte, the reactor's owner and fee controller, and the router's code hash and
   PERMIT2 bytes must match.
6. **Switch.** Point the keeper and the API at the new filler (and, for a rotation, the new keeper key) in one
   configuration change: the cosigner then names the new filler as exclusive filler.
   Settle or let lapse any order already cosigned for the old filler (the window is 20 blocks).
7. **Retire the old filler.** It cannot be disabled. Stop using it: its keeper key is the only address that can call
   it, and it can only settle orders cosigned exclusive to it, which lapse 20 blocks after cosigning. After a key
   compromise, rotate the cosigner too (below), because the old key with a cosignature could still settle an order at
   its signed minimum. Sweep the old keeper wallet's execution fees to the treasury.
8. **Record the release.** Update the release report with the new source revision, bytecode hashes, record and
   verification output.

## Cosigner rotation

The cosigner address is in each signed order, so a new cosigner applies to orders signed after the switch.

1. Create the new cosigner key in the keeper's key store and publish its address through the API configuration, so
   the web app puts it in new orders.
2. Keep the old key available to the keeper only for orders signed with it, until they expire or are cancelled. After a
   compromise, do not wait: ask the affected traders to cancel (Permit2 `invalidateUnorderedNonces`) and sign again,
   because the old key can cosign and fill any of their stored orders at the signed minimum, ignoring the trigger.
3. No contract changes: the filler and the reactor do not store the cosigner.
