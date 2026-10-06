# Security

## Reporting a vulnerability

This repository is private, so GitHub's private reporting does not reach it. Report privately through **Security →
Report a vulnerability** on the public
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts) repository, naming Trade and the
filler. The report is visible only to the maintainers until a fix is deployed and disclosed. Please do not open a public
issue for anything that could be exploited.

Include the contract and function, the chain (testnet 5042002), a transaction or a Foundry test that shows the
behaviour, and what you think the impact is. You will get an acknowledgement within 48 hours and updates as the fix
moves.

## Scope

The contracts in `src/`, `MercuriOrderFiller` and the `MercuriOrderValidator` it deploys, and the deployment scripts in
`script/`. Nothing is deployed yet; once it is, the scope is the addresses in the deployment records under
`deployments/`. The vendored dependencies under `lib/` are upstream code, and Launch's contracts are in their own public
repository; report defects in them there as well.

Out of scope: the web app, the API and the hosting, which are not in this repository. The keeper's own code is out of
scope; keeper or cosigner behaviour that lets a fill break the filler's guarantees is in scope. Findings that require a
compromised keeper or cosigner key are a trust boundary rather than a defect; what each key can do is stated below.

## Trust and governance

| Component | Mutability | Who controls what |
| --- | --- | --- |
| `MercuriOrderFiller` | Immutable: no owner, pause, upgrade or rescue path | Nobody. Every dependency, the execution fee, the keeper address and its validator are fixed in its bytecode. Only the keeper can call `fill`; only the reactor can call back into it or send it native value. It refuses an order that does not name its validator and swaps only through the pool the trader signed |
| `MercuriOrderValidator` | Immutable: no owner, pause, upgrade or storage. Deployed by the filler's constructor with CREATE2, bound to that filler and to the v4 PoolManager | Nobody. The reactor calls it before any transfer; it refuses every filler but its own and, for a take-profit or stop-loss, a pool price that has not reached the signed trigger in the order's direction. It reads the pool's current spot price, which can be moved within a block |
| `V3DutchOrderReactor` | Immutable upstream code (UniswapX `eb7ce07`, unchanged) with one owner | The owner is Launch's TimelockController on the same network (`timelock` in Launch's deployment record; the deployment scripts and the verifier require it). The owner can set a protocol fee controller, which adds output-token fees of at most 5 bps of the outputs, or transfer ownership. A controller can also make every fill revert: an input-token fee is refused by the filler (`FeeOutputUnsupported`) and a reverting controller blocks the reactor itself. Every owner action waits the timelock's delay. The reactor ships with no controller, and the scripts and the verifier require that |
| Keeper (`feeRecipient`) | Off-chain service with one transaction key | The only caller of `fill`. It chooses when to fill and receives the execution fee; the pool is the one the trader signed. A compromised key can fill a cosigned order the moment its condition holds on chain, skipping the six-block hold the honest keeper waits for; it cannot fill an untriggered take-profit or stop-loss, use another pool or another filler, pay the trader less than the signed minimum or take more than one execution fee per fill |
| Cosigner | Off-chain key named in each order | Cosigns an order at fill time: the decay start block, the exclusive filler and output overrides that can only raise the outputs (the reactor refuses a lower one). A compromised cosigner can cosign any stored order, but only our filler can settle it (the validator refuses every other filler), and only its keeper can call that filler |
| Keeper and cosigner together | The worst case the contracts bound | Can fill a stored order through our filler and its signed pool once the order's condition holds, and can push that pool's price within the same block to make it hold (R9). The trader still receives at least the signed minimum, so the loss on an order is at most its value less that minimum: for a protected stop the trader-signed band times the order's notional, and only on orders whose trigger is reached on chain. A limit order fills at the trader's own price or better |

What is enforced on chain, for every order: the trader's input is spent only once, by the trader's own signature, and
only if the trader's balance rises by at least the signed minimum output before the deadline and within the
cosigned window. The order names our validator and carries its condition in the trader-signed
`additionalValidationData`: `abi.encode(uint8 version, uint8 kind, bytes32 poolId, uint160 triggerSqrtPriceX96)`. Only
our filler can settle it, only through that pool, and a take-profit or stop-loss only while the pool's current price
is at or beyond the trigger in the order's direction (release report, section 20). The six-block hold before the
keeper fires (spec D3) stays off chain: it is the keeper's filter against a price pushed for a block or two.

Limits a reviewer should know:

- The app fee on a listed pool is charged on the gross signed input of a buy, which includes the execution fee.
- Pools of any hook other than the filler's `launchHook` take the listed-pool path: they pay the app fee and the
  trader loses Launch's referral credit. A new Launch hook therefore needs a new filler.
- On Arc native value is USDC. The reactor refunds its whole native balance to the filler after every fill; the filler
  accepts it from the reactor only, never pays it out, and has no way to return it.
- The trigger is checked against the signed pool's spot price before the swap, not an oracle (none exists on Arc for
  these assets). Anyone can move a pool's price, with no key at all: a third party can sell into a thin pool to push
  it through a stop-loss and buy back after the fill (re-audit of 5 Oct 2026, C-01). Two bounds hold. The honest keeper
  cosigns only after the trigger has held for six consecutive finalized blocks (`HoldBlocks = 6` in the keeper), so a
  push for a block or two is not filled and the attacker must hold the price past the trigger for that long; and the
  fill reverts unless the trader receives at least the signed minimum (`NetMinimumNotMet`), so the loss on an order is
  at most its value less that minimum, the trader-signed band times the notional for a protected stop. A sustained hunt
  that holds the price for six blocks is not prevented on chain: it is an accepted design limit while Arc has no
  oracle (spec E12, D22, R9), controlled by the keeper's stop-capacity limits per pool (D30) and tight bands on thin
  pools, and it belongs in the order terms shown to traders. Under a key compromise the hold does not bind (R9).
- The filler and its validator are bound together (R7). Orders name the validator, so a replacement filler cannot
  settle orders signed for the old one; they stay fillable only through the old pair, by the old keeper key.
- The keeper address is fixed for the filler's life, and it has two roles: it is the only address allowed to call
  `fill` and the recipient of every execution fee (C-02). If that key is lost, must be rotated, or the address can no
  longer transact or receive USDC (for example a blocklist, if Arc's USDC has one), every open order stops: nobody else
  may call `fill`, and a fee transfer that reverts reverts the fill. No funds are at risk, because inputs stay in the
  traders' wallets and an order lasts at most 30 days. Recovery is a new filler and validator, and every trader with an
  open order must sign again against the new validator; the steps are in the runbook (forced replacement). The fee is
  deliberately not split to another address: it is paid to the keeper so that it funds the keeper's gas (spec D13), and
  a separate recipient would not help the main case, a lost key.
- Pools whose currency is native USDC (`address(0)`) cannot be traded through orders (C-06). The callback requires the
  pool's currencies to be exactly the order's input and output, one of them the ERC-20 USDC address, and Permit2 inputs
  are never `address(0)`, so such an order always reverts `PoolMismatch` and nothing moves. The keeper and the web app
  must not offer orders on those pools.

## Griefing defence

The keeper pays the gas of every fill it sends, including one that reverts. Between the keeper's simulation and the
transaction's inclusion a trader can make a cosigned fill revert: move the input tokens away, revoke the input token's
approval to Permit2, cancel the order's Permit2 nonce, or let the deadline pass. Before this guard such a fill failed
deep inside the reactor, at Permit2's input transfer, after the order had been decoded, hashed and its cosignature
checked. Two layers answer it:

- **On chain, the early guard.** `fill` decodes the order and, before calling the reactor, refuses it with a typed
  error if the deadline has passed (`OrderExpired`), the Permit2 nonce bit is set (`NonceUsed`), or the trader's input
  balance (`SwapperBalanceTooLow`) or allowance to Permit2 (`SwapperAllowanceTooLow`) is below the exact amount the
  reactor would take in that block (the cosigned input, the base-fee adjustment and the input curve, resolved as the
  reactor resolves them). The guard only reads, runs on every fill, and can only make a fill revert earlier: each of
  its conditions is one the reactor or Permit2 would refuse anyway, at the same bound, so it changes no fee, minimum,
  exclusivity or surplus rule. On the local fixture a griefed fill now costs about 41k to 57k gas for the whole
  transaction, against about 101k to 156k before (release report, section 19).
- **Off chain, the keeper's lanes.** The keeper classifies each revert by its selector. `SwapperBalanceTooLow`,
  `SwapperAllowanceTooLow` and `NonceUsed` are caused by the trader; `OrderExpired` is not (the deadline was signed up
  front). Wallets without a clean fill history trade in a probation lane with one order in flight and their own revert
  budget, a self-caused revert bans the wallet for escalating periods, and the keeper keeps a griefing reserve in its
  self-funding ledger. This is keeper code, outside this repository.

Residual risk:

- The guard makes a griefed fill cheap, not impossible: each grief still costs the keeper one small reverted
  transaction. Bounding how many is the keeper lanes' job.
- A fill that passes the guard can still revert later at full cost for reasons the trader does not control directly
  (price moved past the signed minimum, liquidity) or through an input token with unusual behaviour.
- The input token's `balanceOf` and `allowance` are called as static calls. A token whose views overstate passes the
  guard and fails in Permit2 as before; one whose views understate or revert only blocks its own orders; their gas is
  bounded by the transaction the keeper chose to send. `fill` already called that token's `balanceOf` before the guard.
- The guard reads the filler's own `permit2`; the deployment script requires it to be the reactor's Permit2.

## Pause and recovery

The filler has no pause. Fills stop when the keeper stops cosigning and stops calling `fill`, which is the incident
lever. Orders already signed stay valid Permit2 signatures until their deadline; a trader cancels one by invalidating
its nonce with Permit2 (`invalidateUnorderedNonces`).

Nothing sent to the filler can be recovered (C-06). Tokens or native value sent to it outside a fill, and the
reactor's end-of-fill native refunds (native USDC dust on Arc), stay in the filler for good: there is no owner and no
rescue function. They never pay a fee, subsidise an order or reach a later fill, because every fill measures its
own balances against a baseline and pays the trader at most that fill's own surplus. Never send funds to the filler.

## Replacement

| Change | Cost |
| --- | --- |
| New filler (bug fix, keeper key rotation, fee change, a new Launch hook, a new route) | Deploy the filler, which deploys its new validator; verify, write the record, then switch the keeper and API configuration to the pair, so new orders name the new validator. Open orders are bound to the old pair (R7): keep the old filler and its keeper key serving them until they expire (at most 30 days) or the traders sign again. After a key compromise, ask traders to sign again and rely on the on-chain bounds above |
| New reactor | Every open order must be signed again by its trader: the reactor is in the signed order and is the Permit2 spender |
| Cosigner rotation | Configuration in the keeper and API (the cosigner address the web app puts in new orders). Orders signed with the old cosigner can only be filled by that key until they expire or are cancelled |

The steps are in [`docs/runbooks/filler-replacement.md`](docs/runbooks/filler-replacement.md).

## Execution fee custody

The execution fee is paid to `feeRecipient`, the keeper's transaction address, which is a hot wallet: it also pays the
gas for every fill. The fee is operationally swept to the treasury; it is not held for traders and is never refunded
by the contract.

## What already exists

- Release evidence for the filler candidate: `docs/reports/2026-10-02-order-filler-release.md`, including the
  independent audit of 3 October 2026 and its fix round (section 18).
- Reproducible bytecode: `python3 script/verify-trade-filler.py` after `forge build`, for the reactor, the filler and
  the validator, with the binding between the last two checked both ways. The reactor's runtime is pinned in each
  manifest (`reactorCodeHash`); the deployment scripts and the verifier compare against that pin, never against a hash
  the operator supplies (C-04). Until a deployment record exists it runs in `--self-test` and `--preflight` mode
  against the freshly built artifacts, the manifests and Launch's deployment records.
- A filler pair that someone else lands first, by replaying the init code through the permissionless CREATE2 deployer,
  is adopted only when both runtimes are byte for byte the ones the script would deploy; any other code at either
  address is refused (C-05). Such a pair is the same contract, so it is not a risk to traders. Its deployment record
  carries `fillerAdopted: true` and names the reactor's sender as `reactorDeployer`, with no `deployer`, because the
  filler's CREATE2 was not the operator's transaction.
- The filler and the validator are immutable, with no owner, pause, upgrade or rescue path; only the configured keeper
  can call `fill`.

An independent review was performed on 3 October 2026 (release report, section 18). A re-audit of 5 October 2026
covered the early guard (section 19) and the on-chain order validation (section 20) and found no exploitable defect;
its six Low and Info findings and their resolutions are in section 21. A focused re-audit of those fixes on 6 October
2026 found one Low and three Info items in the tooling and tests, with no change to any contract; their fixes are also
in section 21. No professional third-party audit has been performed yet.
