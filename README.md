<p align="center"><img src="assets/logo.jpg" alt="PicklePots logo" width="220"></p>

# PicklePots 🥒

**4-tier, real-time "King of the Jar" game on Pickle Chain.** Drop a bid, reset the timer, and be the last bidder standing to win the pot.

**Live app:** https://picklepots.xyz (reads rounds directly from Pickle Chain testnet)

## How it works

Each tier runs its own independent round, timer and pot. Every bid makes you the King of the Jar and extends the timer (up to the tier's cap). When the timer runs out, the last bidder wins.

| Tier | Name | Min bid | Round | Extension per bid | Max timer |
|------|------|---------|-------|-------------------|-----------|
| 0 | Cocktail Jar | 0.0001 ETH (~$0.25) | 25s | +10s | 45s |
| 1 | Baby Gherkin | 0.0005 ETH (~$1.25) | 30s | +15s | 60s |
| 2 | Classic Dill | 0.002 ETH (~$5.00) | 45s | +15s | 90s |
| 3 | Spicy Brine | 0.02 ETH (~$50.00) | 60s | +20s | 120s |

### Pot distribution (per round)

- **90%** to the winning King of the Jar
- **5%** seeds the next round of that tier
- **5%** protocol fee, sent to the fee recipient or routed through `PickleFeeRouter`

## Network

| | |
|---|---|
| Network | Pickle Chain |
| Chain ID | 78270 (`0x131be`) |
| RPC | https://rpc.picklechain.xyz |
| Explorer | https://explorer.picklechain.xyz |
| Currency | ETH (18 decimals) |

Quick RPC health check:

```bash
curl https://rpc.picklechain.xyz \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
```

## Deployed contract

- **Address:** `0xe9712892ab4607510bcb545f1b1377b69f6ae589`
- **Deployment tx:** `0xa8dca7b28a541ccc2821d928aa156478c12ec8ec8d2ef75e137d3e32a5c4b507`
- **Block:** #7,223,709
- **Protocol fee recipient:** `0x903d2AD79bBa6BB121FdF2102cA80469C6b735eb`

## Repository layout

```
contracts/PicklePots.sol        Solidity 0.8.20 contract (4 tiers)
scripts/deploy_picklepots.js    Hardhat deploy script for Pickle Chain
hardhat.config.js               Hardhat config (network "pickle", chain 78270)
index.html                      Standalone single-page dApp (static hosting)
.env.example                    Environment variable template
```

## Development

```bash
npm install
cp .env.example .env        # then fill in PRIVATE_KEY (never commit .env)
npx hardhat compile
npx hardhat test
npx hardhat run scripts/deploy_picklepots.js --network pickle
```

## Frontend

`index.html` is a self-contained static page. Open it directly, or deploy the repo root to any static host (Cloudflare Pages, Vercel, Netlify, GitHub Pages) with no build step and no build command.

## Pickle Chain compliance

Built for Pickle Chain's real-time execution and the `PickleFeeRouter` fee model: the contract routes the protocol take through `IPickleFeeRouter.routeProtocolFee` when a router is configured, and otherwise sends it to the fee recipient.

## Security

Never commit `.env` or any private key. Use a dedicated deployer wallet.
