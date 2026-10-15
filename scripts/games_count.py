#!/usr/bin/env python3
"""Count games run on PicklePots V2 from on-chain state (no event logs needed).
A game = a round that has been settled (roundId - 1 per jar), plus the live round if it has bids.
usage: games_count.py [--save]   (--save stores a baseline so the next run shows the change)"""
import json, sys, os, urllib.request
RPC="https://rpc.picklechain.xyz"; P="0x720fb1562e50bbe3530b973ecf1e26379ec60818"
NAMES=["Cocktail Jar","Baby Gherkin","Classic Dill","Spicy Brine","PKL Barrel","Pickle Starter"]
BASE=os.path.expanduser("~/.picklepots_games.json")
def call(data):
    r=json.load(urllib.request.urlopen(urllib.request.Request(RPC,json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":P,"data":data},"latest"]}).encode(),{"content-type":"application/json"}),timeout=30))
    return r.get("result")
rows={}
for t in range(6):
    res=call("0xb4e5a830"+"%064x"%t)
    if not res or res=="0x": continue
    b=bytes.fromhex(res[2:]); w=lambda i:int.from_bytes(b[i*32:(i+1)*32],"big")
    rows[t]={"settled":w(0)-1,"live_with_bids":1 if w(4)>0 else 0}
total=sum(r["settled"]+r["live_with_bids"] for r in rows.values())
prev=json.load(open(BASE)) if os.path.exists(BASE) else None
print("Games run:",total)
for t,r in rows.items():
    n=r["settled"]+r["live_with_bids"]
    d=""
    if prev and str(t) in prev["rows"]:
        p=prev["rows"][str(t)];d=f"  (+{n-(p['settled']+p['live_with_bids'])})"
    print(f"  {NAMES[t] if t<len(NAMES) else 'Jar '+str(t)}: {n}{d}")
if prev: print("Change since last saved check:",total-prev["total"])
if "--save" in sys.argv: json.dump({"total":total,"rows":{str(k):v for k,v in rows.items()}},open(BASE,"w"))
