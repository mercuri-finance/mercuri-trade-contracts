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
`script/`. Nothing is deployed yet; once
it is, the scope is the addresses in the deployment records under `deployments/`. The vendored dependencies under
`lib/` are upstream code, and Launch's contracts are in their own public repository; report defects in them there as
well.

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
  these assets). Anyone can move a pool's price within a block; under a key compromise that lets an order fill at the
  manipulated moment (R9). The signed minimum bounds the cost: the band, for a protected stop.
- The filler and its validator are bound together (R7). Orders name the validator, so a replacement filler cannot
  settle orders signed for the old one; they stay fillable only through the old pair, by the old keeper key.

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
its nonce with Permit2 (`invalidateUnorderedNonces`). Tokens or native value sent to the
filler outside a fill, and the reactor's native refunds, have no rescue path and stay in the filler; they never pay a
fee or subsidise an order.

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
  the validator, with the binding between the last two checked both ways. Until a deployment record exists it runs in
  `--self-test` and `--preflight` mode against the freshly built artifacts, the manifests and Launch's deployment
  records.
- The filler and the validator are immutable, with no owner, pause, upgrade or rescue path; only the configured keeper
  can call `fill`.

An independent review was performed on 3 October 2026 (release report, section 18); the early guard added after it
(section 19) and the on-chain order validation (section 20) await their own isolated re-review. No professional
third-party audit has been performed yet.
