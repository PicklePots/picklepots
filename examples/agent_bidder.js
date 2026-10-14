#!/usr/bin/env node
/**
 * PicklePots agent example. Pickle Chain TESTNET only (test ETH, no real value).
 *
 * Default mode is READ-ONLY: it prints the state of every jar (or one with --tier).
 *
 *   npm install ethers@6
 *   node examples/agent_bidder.js
 *   node examples/agent_bidder.js --tier 0
 *
 * Bid mode needs a THROWAWAY testnet key in the environment (never a real wallet) and --bid.
 * It plays a simple "snipe" rule: when another player is leading and the clock is nearly out,
 * it places one minimum bid. It stops after --max-bids bids or --max-minutes minutes.
 *
 *   PRIVATE_KEY=0x... node examples/agent_bidder.js --tier 0 --bid \
 *       [--beneficiary 0xWhereWinningsGo] [--max-bids 2] [--snipe-secs 8] [--max-minutes 10]
 *
 * NOTE: the bid path is a starting point and has not been exercised on-chain by the authors of
 * this example. Try it on jar 0 with a small balance first. Native-coin jars only (0 to 3);
 * the PKL jar needs approve + dropBidToken, which this example does not cover.
 */
"use strict";

const { ethers } = require("ethers");

const RPC = process.env.PICKLE_RPC || "https://rpc.picklechain.xyz";
const CHAIN_ID = 78270;
const PROXY = "0x720fb1562e50bbe3530b973ecf1e26379ec60818";

const ABI = [
  "function numTiers() view returns (uint8)",
  "function getRound(uint8 tierId) view returns (uint256 roundId, uint256 potAmount, address leader, uint256 deadline, uint256 totalBids, uint256 timeLeft, bool isExpired, string tierName, uint256 minBid)",
  "function getRoundExtra(uint8 tierId) view returns (uint256 uniqueBidders, uint256 seed, address token)",
  "function dropBidFor(uint8 tierId, address beneficiary) payable",
];

function arg(name, fallback) {
  const i = process.argv.indexOf("--" + name);
  if (i === -1) return fallback;
  const next = process.argv[i + 1];
  return next === undefined || next.startsWith("--") ? true : next;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function readJar(contract, id) {
  const r = await contract.getRound(id);
  const x = await contract.getRoundExtra(id);
  return {
    id,
    name: r.tierName,
    round: r.roundId,
    pot: r.potAmount,
    leader: r.leader,
    totalBids: Number(r.totalBids),
    timeLeft: Number(r.timeLeft),
    expired: r.isExpired,
    minBid: r.minBid,
    unique: Number(x.uniqueBidders),
    token: x.token,
  };
}

function describe(j) {
  const unit = j.token === ethers.ZeroAddress ? "ETH" : "PKL";
  const king = j.leader === ethers.ZeroAddress ? "nobody yet" : j.leader;
  const clock = j.expired ? (j.leader === ethers.ZeroAddress ? "no bids" : "expired, awaiting settlement") : j.timeLeft + "s left";
  return (
    `jar ${j.id} ${j.name} | round ${j.round} | pot ${ethers.formatEther(j.pot)} ${unit} | ` +
    `min ${ethers.formatEther(j.minBid)} ${unit} | bids ${j.totalBids} (${j.unique} unique) | ${clock} | king ${king}`
  );
}

// Poll for the receipt ourselves: this chain can return a null blockHash at preconfirmation,
// so we do not use tx.wait().
async function pollReceipt(provider, hash, timeoutMs = 60000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const receipt = await provider.send("eth_getTransactionReceipt", [hash]);
    if (receipt) return receipt;
    await sleep(1000);
  }
  return null;
}

async function main() {
  const network = ethers.Network.from({ chainId: CHAIN_ID, name: "pickle-testnet" });
  const provider = new ethers.JsonRpcProvider(RPC, network, { staticNetwork: network, batchMaxCount: 1 });

  const chainId = BigInt(await provider.send("eth_chainId", []));
  if (chainId !== BigInt(CHAIN_ID)) {
    throw new Error(`Wrong network: RPC reports chain ${chainId}, expected ${CHAIN_ID}. Refusing to continue.`);
  }

  const reader = new ethers.Contract(PROXY, ABI, provider);
  const tierArg = arg("tier", null);
  const wantBid = arg("bid", false) === true;

  if (!wantBid) {
    const count = Number(await reader.numTiers());
    const ids = tierArg === null ? [...Array(count).keys()] : [Number(tierArg)];
    for (const id of ids) console.log(describe(await readJar(reader, id)));
    return;
  }

  // ---- bid mode ----
  const key = process.env.PRIVATE_KEY;
  if (!key) throw new Error("Bid mode needs PRIVATE_KEY (a throwaway testnet key) in the environment.");
  const tier = Number(tierArg === null ? 0 : tierArg);
  const maxBids = Number(arg("max-bids", 2));
  const snipeSecs = Number(arg("snipe-secs", 8));
  const deadline = Date.now() + Number(arg("max-minutes", 10)) * 60000;

  const wallet = new ethers.Wallet(key, provider);
  const beneficiary = arg("beneficiary", wallet.address);
  if (!ethers.isAddress(beneficiary)) throw new Error("--beneficiary is not a valid address");
  const contract = new ethers.Contract(PROXY, ABI, wallet);

  console.log(`bidder ${wallet.address} | winnings and refunds go to ${beneficiary} | jar ${tier}`);
  let placed = 0;

  while (placed < maxBids && Date.now() < deadline) {
    const jar = await readJar(reader, tier);
    if (jar.token !== ethers.ZeroAddress) throw new Error("Jar " + tier + " is a token jar. This example only bids in native-coin jars.");

    const otherIsKing = jar.leader !== ethers.ZeroAddress && jar.leader.toLowerCase() !== beneficiary.toLowerCase();
    if (otherIsKing && !jar.expired && jar.timeLeft > 0 && jar.timeLeft <= snipeSecs) {
      console.log("sniping: " + describe(jar));
      const tx = await contract.dropBidFor(tier, beneficiary, { value: jar.minBid, gasLimit: 300000n });
      console.log("sent " + tx.hash);
      const receipt = await pollReceipt(provider, tx.hash);
      if (!receipt) console.log("no receipt after 60s (check the explorer)");
      else console.log(receipt.status === "0x1" ? "confirmed" : "FAILED (status " + receipt.status + ")");
      placed += 1;
      await sleep(3000);
    } else {
      await sleep(1500);
    }
  }
  console.log(`done: ${placed} bid(s) placed`);
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
