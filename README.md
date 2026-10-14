<p align="center"><img src="assets/logo.jpg" alt="PicklePots logo" width="220"></p>

# PicklePots 🥒

**5-jar, real-time "King of the Jar" game on Pickle Chain.** Drop a bid, reset the timer, and be the last bidder standing to win the pot.

**Live app:** https://picklepots.xyz (reads rounds directly from Pickle Chain testnet)

**X:** [@picklepotsxyz](https://x.com/picklepotsxyz) · **Contact:** hello@picklepots.xyz

**Building an agent?** See [AGENTS.md](AGENTS.md), the [agent manifest](agents.json) and the [example bidder](examples/agent_bidder.js). Testnet only.

## How it works

Each tier runs its own independent round, timer and pot. Every bid makes you the King of the Jar and extends the timer (up to the tier's cap). When the timer runs out, the last bidder wins. If only one player entered the round, they are refunded in full.

| Tier | Name | Min bid | Round | Extension per bid | Max timer |
|------|------|---------|-------|-------------------|-----------|
| 0 | Cocktail Jar | 0.0001 ETH (~$0.25) | 25s | +10s | 45s |
| 1 | Baby Gherkin | 0.0005 ETH (~$1.25) | 30s | +15s | 60s |
| 2 | Classic Dill | 0.002 ETH (~$5.00) | 45s | +15s | 90s |
| 3 | Spicy Brine | 0.02 ETH (~$50.00) | 60s | +20s | 120s |
| 4 | PKL Barrel | 10 PKL (testnet token) | 45s | +15s | 90s |

### Pot distribution (per round)

With two or more different bidders:

- **90%** to the winning King of the Jar
- **5%** seeds the next round of that tier
- **5%** protocol fee, sent to the fee recipient or routed through `PickleFeeRouter`

With a single bidder (even if they bid several times) there is nobody to beat: they get their bids back in full, no fee is taken, and any seed already in the pot rolls into the next round. If a winner's address rejects payment, the funds are credited to them and they can pull them with `claim(token)`, so a jar can never be frozen.

## Two ways to play

- **Connected wallet:** your wallet pops up and you sign each bid.
- **⚡ Insta Wallet:** a small play wallet kept in your browser. Fund it once (send test ETH or PKL to its address, or deposit from your connected wallet) and every bid is signed locally and sent instantly with no pop-ups. Winnings and refunds are paid straight to your main wallet (the contract's `dropBidFor` / `dropBidToken` take a beneficiary). Withdraw any leftover balance whenever you like. Testnet play money only: the key lives in the browser, so use Export key to back it up.

### Wallet support

- **Tested on a phone with real wallets:** Trust Wallet over WalletConnect (connect and bid), and Rabby inside its built-in browser (connect, bid, ⚡ Insta Wallet deposit and bids, PKL jar).
- **Rabby over WalletConnect:** not supported. Rabby's WalletConnect only allows its built-in networks, so use Rabby's built-in browser.
- **Other wallets** (Brave Wallet, MetaMask, other in-app browsers) should work through the standard browser-wallet flow but have not been tested yet.
- **No connection needed:** fund the ⚡ Insta Wallet by sending test ETH or PKL to its address from any wallet.

## For agents

PicklePots is easy for autonomous agents to read and play: every jar is a view call away, and bids are a single payable call. [AGENTS.md](AGENTS.md) (also served at https://picklepots.xyz/agents.html) has the contract address, ABI, round rules and RPC quirks, and [agents.json](agents.json) is the same information in machine-readable form. [examples/agent_bidder.js](examples/agent_bidder.js) prints jar state by default and only bids when you pass `--bid` with a throwaway testnet key. Testnet only, no real value.

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

- **PicklePots v2 (proxy, use this address):** `0x720fb1562e50bbe3530b973ecf1e26379ec60818`
- **Implementation:** `0x53950f621de0b475ef90213d6dee4802832f1068`
- **Owner / protocol fee recipient:** `0x903d2AD79bBa6BB121FdF2102cA80469C6b735eb`
- **PKL token (testnet):** `0x8d1Ab7dD27a5Fd87452748012Dc7f319f51b877e`

v2 is a UUPS upgradeable proxy (OpenZeppelin v5), so the address stays the same across updates. Upgrades are owner-only, ownership transfers are two-step, and `freezeUpgrades()` permanently locks the logic once the design is final.

The earlier v1 contract (`0xe9712892ab4607510bcb545f1b1377b69f6ae589`) is retired.

## Repository layout

```
contracts/PicklePotsV2.sol      Current upgradeable contract (5 jars, solo refund, PKL jar)
contracts/PicklePots.sol        Retired v1 contract (kept for reference)
test/PicklePotsV2.test.js       Hardhat tests (11 scenarios)
scripts/deploy_v2.js            Deploys implementation + proxy
scripts/deploy_picklepots.js    Hardhat deploy script for Pickle Chain
hardhat.config.js               Hardhat config (network "pickle", chain 78270)
index.html                      Standalone single-page dApp (static hosting)
agents.html                     Agent-facing page (same content as AGENTS.md)
AGENTS.md                       Guide for autonomous agents
agents.json                     Machine-readable agent manifest
examples/agent_bidder.js        Example agent: read-only by default, optional bid mode
scripts/watch_players.py        Lists unique bidders from recent blocks
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
