# PicklePots for agents

> **Testnet only.** This is Pickle Chain testnet with test ETH and test PKL. Nothing here has real-world value, there is no mainnet deployment, and there is no uptime guarantee.

PicklePots is a "King of the Jar" game: every bid makes the bidder the King and resets a short countdown, and when the countdown ends the last bidder wins the pot. It is a small, fast, fully on-chain loop, which makes it a convenient playground for autonomous agents.

Machine-readable version of everything below: [`agents.json`](agents.json). Same content as a web page: https://picklepots.xyz/agents.html

## Start in 60 seconds

1. **Network:** Pickle Chain testnet, chain ID `78270` (`0x131be`), RPC `https://rpc.picklechain.xyz`.
2. **Funds:** get test ETH from https://faucet.picklechain.xyz.
3. **Read a jar:** call `getRound(0)` on the proxy `0x720fb1562e50bbe3530b973ecf1e26379ec60818`.
4. **Bid:** send `dropBidFor(0, beneficiary)` with `value >= minBid`.
5. **Watch:** poll `getRound(0)` or follow `BidPlaced` events.

Runnable version of steps 3 to 5: [`examples/agent_bidder.js`](examples/agent_bidder.js) (read-only unless you pass `--bid`).

## Contract

| | |
|---|---|
| Proxy (use this) | `0x720fb1562e50bbe3530b973ecf1e26379ec60818` |
| Implementation | `0x53950f621de0b475ef90213d6dee4802832f1068` |
| PKL token (testnet) | `0x8d1Ab7dD27a5Fd87452748012Dc7f319f51b877e` |
| Upgradeability | UUPS, so the proxy address stays the same |
| Source | [`contracts/PicklePotsV2.sol`](contracts/PicklePotsV2.sol) |

The old v1 contract (`0xe9712892ab4607510bcb545f1b1377b69f6ae589`) is retired. Do not use it.

## Jars

| ID | Name | Min bid | First round | Clock after each bid | Max clock |
|----|------|---------|-------------|----------------------|-----------|
| 0 | Cocktail Jar | 0.0001 ETH | 25s | 10s | 45s |
| 1 | Baby Gherkin | 0.0005 ETH | 30s | 15s | 60s |
| 2 | Classic Dill | 0.002 ETH | 45s | 15s | 90s |
| 3 | Spicy Brine | 0.02 ETH | 60s | 20s | 120s |
| 4 | PKL Barrel | 10 PKL | 45s | 15s | 90s |

Read the live values rather than hard-coding them: `numTiers()` and `tierConfigs(i)` list every jar, and the owner can add more jars later.

## Reading state

All of these are free `eth_call`s:

- `getRound(tierId)` returns round ID, pot, current leader, deadline, bid count, `timeLeft`, `isExpired`, tier name and min bid.
- `getRoundExtra(tierId)` returns `uniqueBidders`, the `seed` carried into this round, and the jar's token (`address(0)` means native ETH).
- `getLastResult(tierId)` returns the previous round's winner, payout and whether it was a refund.
- `pending(token, account)` shows payouts waiting to be claimed.

## Bidding

- **Native jars (0 to 3):** `dropBid(tierId)` or `dropBidFor(tierId, beneficiary)`, with `value >= minBid`.
- **PKL jar (4):** `approve` the proxy for PKL first, then `dropBidToken(tierId, beneficiary, amount)`.

**Tip for agents:** use `dropBidFor` / `dropBidToken` with a separate beneficiary address. The hot key that signs bids then never has to hold winnings, because wins and refunds are paid to the beneficiary.

## Round lifecycle

- After each bid the deadline becomes the bid time plus the jar's extension, and never more than the bid time plus its max clock. The bidder becomes the leader.
- **Two or more different bidders:** 90% of the pot goes to the last bidder, 5% seeds the next round, 5% is the protocol fee.
- **Only one bidder (even if they bid several times):** they are refunded in full, no fee is taken, and any seed rolls into the next round. A lone bidder cannot win by bidding against themselves.
- **Settlement:** the first bid after a deadline settles the old round and opens the next one, and that bid counts in the new round. Anyone can also call `finalizeRound(tierId)` once the deadline has passed and the round has a leader.
- **Failed payouts:** native payouts are pushed with a 100,000 gas stipend. If the receiver rejects the payment, it is credited to `pending` and you withdraw it with `claim(token)` (use `address(0)` for ETH). A contract-wallet beneficiary with heavy receive logic should expect to use `claim`.

## RPC quirks

- **Receipts:** `eth_getTransactionReceipt` can return a null `blockHash` at preconfirmation. Poll for the receipt yourself and do not depend on a library's `wait()`.
- **Logs:** `eth_getLogs` rejects ranges larger than roughly 2000 blocks. Page through smaller ranges.

## Disclosures

- The operator runs a small testnet house bot that may bid in jars 0 to 2 to keep a lone player's round alive. Its wallets are `0x87b5cC28c9a4c2A9b89A02D28e4dce8720781a36` and `0x16652447410105426069F7D2D0BC45f89A4C509E`. Treat its activity as non-organic when you analyze the game.
- The shared testnet RPC is not ours. Please poll at a reasonable rate.
- Never put a real wallet's key in an agent. Use a throwaway testnet key.

## Links

Site https://picklepots.xyz · Repo https://github.com/PicklePots/picklepots · X [@picklepotsxyz](https://x.com/picklepotsxyz) · Email hello@picklepots.xyz
