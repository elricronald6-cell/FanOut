# FanOut

Two-level referral attribution on BOT Chain.

A campaign owner sets two commission rates: one for whoever referred a
contributor, and one for whoever referred *them*. Every contribution splits
itself at the moment it arrives — no reconciliation, no tracking pixel, nobody
signing off on who introduced whom.

## Two deliberate choices

1. **Attribution is permanent.** Your first join fixes your referrer for that
   campaign forever. Later contributions pay the same two people. Nobody can be
   re-attributed by a later transaction — passing a different referrer on a
   second contribution is simply ignored.
2. **Unearned commission goes back to the campaign, not the protocol.** A
   contributor with no referrer, or a referrer with no referrer of their own,
   just leaves more in the campaign vault. The platform's cut is `feeBps`
   (2% default, capped 5%) and nothing else.

Commissions are **pull-based**: they accrue to a balance the earner withdraws,
so one bad recipient can never block somebody else's contribution.

## Contract surface

| Call | Who | What it does |
|---|---|---|
| `createCampaign(name, l1Bps, l2Bps, minContribution)` | anyone | Levels capped at 40% together; L2 may not exceed L1 |
| `setOpen(id, bool)` | campaign owner | Stop or resume taking contributions |
| `join(id, referrer)` | anyone but the owner | Contributes and splits. Referrer must already be in the campaign |
| `withdrawEarnings(id)` | earner | Pulls accrued commission. **Works while paused** |
| `withdrawVault(id)` | campaign owner | Pulls the campaign's share. **Works while paused** |
| `uplineOf`, `directReferrals`, `previewSplit` | view | Trace the network and check a split before sending |

`withdrawFees` is bounded by `accumulatedFees` and can never reach a vault or
somebody's unclaimed commission. A pause blocks new campaigns and new
contributions but never a withdrawal.

## Build and deploy

```bash
npm install
npx hardhat test          # 15 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Kinetic typography**: the
type *is* the layout. Oversized display rows, running marquee bands, words that
shift and tighten on hover, and no cards or panels anywhere — structure comes
from scale and motion alone. Each campaign's two commission levels are set
enormous, and your position in the referral net is a line of names rather than
a diagram.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.

The page also generates a `?ref=` link that pre-fills the referrer field for
whoever opens it.
