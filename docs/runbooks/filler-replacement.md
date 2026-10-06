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
| Keeper key rotation, planned or after a compromise; a lost keeper key; a keeper address that can no longer send transactions or receive USDC | `feeRecipient` is both the fee recipient and the only address allowed to call `fill`, fixed for the filler's life. Follow [Forced replacement](#forced-replacement-the-keeper-address-is-lost-or-blocked) |
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
3. **Deploy.** Keep the reactor. Run `script/DeployOrderFiller.s.sol` with `TRADE_REACTOR` from the current record.
   The reactor's expected runtime is the manifest's reviewed `reactorCodeHash`, never an operator-supplied value
   (re-audit C-04). It refuses a reactor whose code hash, permit2, owner or fee controller differ, a router whose code
   hash differs, a CREATE2 deployer other than the standard one, and any manifest value that disagrees with Launch's
   record. It prints the predicted filler and validator addresses, deploys the filler through the standard CREATE2
   deployer (the filler deploys the validator), and reverts unless both land at their predictions and name each other.
   If a new reactor is part of the change, deploy it first with `script/DeployTestnetReactor.s.sol`, which refuses
   before broadcasting any reactor whose runtime is not `reactorCodeHash`, and verify it alone with
   `verify-trade-filler.py --reactor-only` before any filler is deployed against it.

   The standard deployer is permissionless and the filler's init code is public once the transaction is pending, so
   someone can land the same pair first (re-audit C-05). The pair is then the one we would deploy, so it is safe, and
   the operator's transaction reverts or is never needed. Run the script again: it finds the occupied address, checks
   that the filler and validator runtimes are byte for byte the ones it would deploy, prints `ADOPTED` and broadcasts
   nothing. Any other code at either address is refused (`DeploymentMismatch`, `NoCode` or `AlreadyDeployed`) and
   needs investigation before anything else is sent.
4. **Record.** Archive the current `deployments/<chainId>.json` as `deployments/archive/<chainId>-<deployBlock>.json`,
   then run `script/write-trade-record.py --filler-broadcast broadcast/DeployOrderFiller.s.sol/<chainId>/run-latest.json
   --previous-record deployments/archive/<chainId>-<deployBlock>.json` (or `--reactor-broadcast` for a new reactor).
   It writes only from a completed broadcast whose arguments match the manifest, and records the validator only when
   it is the one contract the filler created, at its predicted CREATE2 address. For an adopted pair there is no filler
   broadcast: pass `--adopted-filler-block N` instead of `--filler-broadcast`, where N is the block of the transaction
   that created the pair (from the explorer, or the first block at which `eth_getCode` of the filler is not empty). The
   record then carries `fillerAdopted: true`.
5. **Verify.** Run `verify-trade-filler.py --rpc <rpc> --block <fillerDeployBlock> --deployment
   deployments/<chainId>.json`. Every byte of the reactor, filler and validator, the binding both ways (each names the
   other; the validator is the filler's CREATE2 deployment; the filler is the standard deployer's CREATE2 of the built
   code with the manifest's arguments), the reactor's owner and fee controller, the reactor's code hash against the
   manifest pin, and the router's code hash and PERMIT2 bytes must match. For an adopted pair, run it at exactly
   `fillerDeployBlock`: it also requires the filler to have had no code one block earlier.
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

## Forced replacement: the keeper address is lost or blocked

The keeper address is fixed for the filler's life as both the only `fill` caller and the fee recipient (re-audit C-02).
If its key is lost, or the address can no longer send transactions or receive USDC, every open order on that filler
stops at once: nobody else may call `fill`, and a reverting fee transfer reverts the whole fill. Traders' funds are not
at risk (their inputs stay in their wallets, and each order expires within 30 days), but no order fills until it is
signed again.

1. **Stop.** Stop cosigning and stop submitting fills for the old filler, and say in the web app that open orders are
   paused and must be signed again.
2. **New keeper and pair.** Create the new keeper key, then run steps 1 to 5 above with the new address as
   `feeRecipient`. The new filler deploys its own new validator.
3. **Switch.** Publish the new filler, validator and keeper through the API (step 6). From then on the web app signs
   new orders against the new validator.
4. **Re-sign path.** For every open order that names the old validator, the web app must show the trader that it
   cannot fill, offer to sign it again against the new validator with the same terms (pair, side, size, trigger, band
   and remaining lifetime), and offer to cancel the old one with Permit2 `invalidateUnorderedNonces`. The old signature
   cannot be moved: the validator is in the signed order. Until the trader signs again the order does nothing; it can
   never fill through the new pair.
5. **Retire.** If the old key still exists (a planned rotation, not a loss), the old keeper can keep serving orders
   signed for the old pair until they expire, as in step 7. Sweep whatever execution fees the old address can still move.

## Pool eligibility

Only pools whose two currencies are the order's input and output, one of them the ERC-20 USDC address, can be traded
through orders. A pool quoted in native USDC (`currency0 == address(0)`) always reverts `PoolMismatch` (re-audit C-06);
the keeper and the web app must not offer orders on it. Funds sent to the filler or the validator cannot be recovered.

## Trigger reads and the six-block hold

The validator compares the signed pool's spot price with the trigger; anyone can move that price, with no key
(re-audit C-01). The on-chain bound is the signed minimum: the trader's loss on a manipulated fill is at most the order's
value less that minimum. The off-chain bound is the keeper's hold: it cosigns a take-profit or stop-loss only after
the trigger has held for six consecutive finalized blocks (`HoldBlocks = 6`), so a push for a block or two is never
filled. A replacement filler does not change either. When operating or replacing the keeper, keep the hold at six
blocks or more, keep the per-pool stop-capacity limits (spec D30) and tight default bands on thin pools, and treat any
change to them as a reviewed change. A hunter that holds the price past the trigger for six blocks can still force a
stop to fill near its signed minimum; that residual risk is part of the order terms shown to traders.

## Cosigner rotation

The cosigner address is in each signed order, so a new cosigner applies to orders signed after the switch.

1. Create the new cosigner key in the keeper's key store and publish its address through the API configuration, so
   the web app puts it in new orders.
2. Keep the old key available to the keeper only for orders signed with it, until they expire or are cancelled. After a
   compromise, do not wait: ask the affected traders to cancel (Permit2 `invalidateUnorderedNonces`) and sign again.
   With the keeper key as well, the old cosigner key can fill their stored orders through our filler and signed pool
   once each condition holds on chain, at no less than the signed minimum.
3. No contract changes: the filler and the reactor do not store the cosigner.
