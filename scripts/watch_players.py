#!/usr/bin/env python3
"""List unique bidders on PicklePots V2 (Pickle Chain testnet) from recent blocks.

Bidders are split into three groups so test data is kept but never counted as users:
  - REAL PLAYERS: everyone not listed below
  - HOUSE BOT (test data): wallets in HOUSE_WALLETS
  - IGNORED: wallets in IGNORE_WALLETS (for example the owner's own wallet)

usage:
  HOUSE_WALLETS=0xabc...,0xdef... IGNORE_WALLETS=0x123... python3 watch_players.py [lookback_blocks]
  (lookback default 150000; wallet lists are comma-separated and optional)

The wallet lists come from the environment so no addresses are stored in this repo.

LIMITATION: as of 2026-10-14 the public RPC only serves roughly the last 400-700 blocks
(about 2-3 minutes). A run of this script therefore only sees bids from that window, and
"0 players" does NOT mean nobody has played. For a reliable count, run it on a schedule
(every minute or two) and append the output, or use an indexer/explorer with history."""
import json, os, sys, urllib.request
RPC = "https://rpc.picklechain.xyz"
PROXY = "0x720fb1562e50bbe3530b973ecf1e26379ec60818"
BID = "0x504547b29ca4f575a458afe315561aeb77834de87f8ad648f92eb48a034918c6"

def wallets(name):
    return {w.strip().lower() for w in os.environ.get(name, "").split(",") if w.strip()}

HOUSE = wallets("HOUSE_WALLETS")
IGNORE = wallets("IGNORE_WALLETS")

def rpc(m, p):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))

head = int(rpc("eth_blockNumber", [])["result"], 16)
look = int(sys.argv[1]) if len(sys.argv) > 1 else 150000
step = 2000
logs = []
for s in range(max(0, head - look), head + 1, step):
    r = rpc("eth_getLogs", [{"address":PROXY,"fromBlock":hex(s),"toBlock":hex(min(s+step-1, head)),"topics":[BID]}])
    if "error" in r:
        step = max(100, step // 4); print("range error, step", step, file=sys.stderr); break
    logs += r["result"]

out = {}
for l in logs:
    a = "0x" + l["topics"][3][-40:]
    d = out.setdefault(a, {"bids":0,"tiers":set(),"last_block":0})
    d["bids"] += 1; d["tiers"].add(int(l["topics"][1],16)); d["last_block"] = max(d["last_block"], int(l["blockNumber"],16))

groups = {"REAL PLAYERS": [], "HOUSE BOT (test data, not counted as users)": [], "IGNORED": []}
for a, d in sorted(out.items(), key=lambda x: -x[1]["last_block"]):
    key = "HOUSE BOT (test data, not counted as users)" if a in HOUSE else "IGNORED" if a in IGNORE else "REAL PLAYERS"
    groups[key].append((a, d))

print("head", head, "total bids", len(logs), "(all wallets)")
for name, rows in groups.items():
    bids = sum(d["bids"] for _, d in rows)
    print(f"\n{name}: {len(rows)} wallet(s), {bids} bid(s)")
    for a, d in rows:
        print(" ", a, "bids", d["bids"], "tiers", sorted(d["tiers"]), "last_block", d["last_block"])
if not HOUSE:
    print("\nnote: HOUSE_WALLETS not set, so any house bot wallets are counted under REAL PLAYERS", file=sys.stderr)
