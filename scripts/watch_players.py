#!/usr/bin/env python3
"""List unique bidders on PicklePots V2 (Pickle Chain testnet) from recent blocks.
usage: watch_players.py [lookback_blocks]  (default 150000)"""
import json, sys, urllib.request
RPC = "https://rpc.picklechain.xyz"
PROXY = "0x720fb1562e50bbe3530b973ecf1e26379ec60818"
BID = "0x504547b29ca4f575a458afe315561aeb77834de87f8ad648f92eb48a034918c6"
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
print("head", head, "total bids", len(logs))
for a, d in sorted(out.items(), key=lambda x: -x[1]["last_block"]):
    print(a, "bids", d["bids"], "tiers", sorted(d["tiers"]), "last_block", d["last_block"])
