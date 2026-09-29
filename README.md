# mercurifi trade · contracts

The on-chain surface of mercurifi trade, the DEX on Arc for every USDC pool:
the ones mercuri launch graduates into and the listed Arc assets. It is a
separate product with a separate contract set, as decided on 28 September
2026: Launch's deployed contracts stay in
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts)
and are never changed for Trade; anything Trade needs on chain lives here.

## What Trade runs on

Trade adds no deployed contract of its own today. Spot swaps go through
Uniswap's Universal Router and Permit2 into the Uniswap v4 pools on Arc; the
1% trade fee on a graduated token's pool is Launch's hook, unchanged. Listed
Arc assets pay an app fee to the treasury as a command in the router plan the
trader signs. Limit, take-profit and stop-loss orders are UniswapX V3 Dutch
orders, cosigned by the API and filled by a keeper.

What this repository holds:

| Path | What it is | Status |
| --- | --- | --- |
| `src/LocalOrderFiller.sol` | The filler the keeper uses against the UniswapX reactor: builds a single-pool swap, enforces net output and full input consumption, hands all surplus to the signed trader | Local integration candidate. Not deployed, not reviewed, no release manifest entry |
| `lib/uniswapx` | The 34-file compiler closure of Uniswap/UniswapX `eb7ce07` for `V3DutchOrderReactor` | Unchanged upstream sources, checksummed in `source-manifest.json` |
| `lib/universal-router` | The 110-file closure of Uniswap/universal-router `999d561`, the revision behind Arc's router `0x4fcA…9Fb1` | Unchanged upstream sources, checksummed; builds separately with `script/build-trade-router.sh` |
| `lib/mercuri-launch-contracts` | Launch's deployed sources and its pinned Uniswap v4, Permit2, OpenZeppelin and forge-std trees | Git submodule, pinned |
| `test/` | The router swap, UniswapX filler and order invariants, the fork invariants and the local-state tests, with the Launch fixtures they need | Local |

The first real Trade deployment will be a filler for the hosted keeper. That
needs its own review, deployment record and release evidence in this repository
before orders open on either network.

## Build and test

```sh
git submodule update --init --recursive
python3 script/check-trade-sources.py   # the two upstream closures are unchanged
bash script/build-trade-router.sh        # the pinned router, read by the tests from out/trade-router
forge build
bash script/check-contracts.sh
```

For stress and pinned fork checks, set `ARC_LOCAL_FORK_RPC`, `TRADE_FORK_CHAIN_ID` and `TRADE_FORK_BLOCK`, then run `bash script/check-contracts.sh --stress`. The default gate runs locally without a fork.

The fork invariants read `ARC_LOCAL_FORK_RPC` (a loopback Anvil fork),
`TRADE_FORK_CHAIN_ID` and `TRADE_FORK_BLOCK`; they are skipped without them.
`bash script/build-trade-router.sh` compiles the pinned router with its own
profile, leaving Mercurifi's compiler profiles alone. `lib-versions.md` records
every pin and where each source came from.

## Fees, for the record

- Graduated tokens: Launch's hook fee, split by Launch's FeeManager, on every
  pool swap whichever app sent it.
- Listed Arc assets: an app fee of at most 1% of the USDC side, paid to the
  treasury inside the router plan; the API refuses to trade a listed pool while
  no recipient is configured.
- Orders: the filler carries the same app recipient, so a fill pays the same
  fee at settlement.

One treasury serves both products; which product a fee came from is told by
the contract that paid it.

## Licence

MIT, as Launch. Upstream sources under `lib/` keep their own licences, which
accompany them.
