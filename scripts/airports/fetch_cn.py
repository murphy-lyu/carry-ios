#!/usr/bin/env python3
# 按 IATA 从 Wikidata 批量取机场中文名（zh-hans / zh-hant，带 zh 兜底）。
import json, time, urllib.parse, urllib.request

airports = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"))
codes = [a["iata"] for a in airports]

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airport data build; murphy.lyu@hotmail.com)"}

def run(values):
    q = """SELECT ?iata ?hans ?hant ?zh WHERE {
      VALUES ?iata { %s }
      ?a wdt:P238 ?iata .
      OPTIONAL { ?a rdfs:label ?hans. FILTER(LANG(?hans)="zh-hans") }
      OPTIONAL { ?a rdfs:label ?hant. FILTER(LANG(?hant)="zh-hant") }
      OPTIONAL { ?a rdfs:label ?zh. FILTER(LANG(?zh)="zh") }
    }""" % " ".join('"%s"' % c for c in values)
    url = ENDPOINT + "?" + urllib.parse.urlencode({"format": "json", "query": q})
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)["results"]["bindings"]

hans, hant = {}, {}
BATCH = 350
for i in range(0, len(codes), BATCH):
    chunk = codes[i:i+BATCH]
    for attempt in range(4):
        try:
            for b in run(chunk):
                code = b["iata"]["value"]
                zh = b.get("zh", {}).get("value")
                h = b.get("hans", {}).get("value") or zh
                t = b.get("hant", {}).get("value") or zh
                if h and code not in hans: hans[code] = h
                if t and code not in hant: hant[code] = t
            break
        except Exception as e:
            print(f"  batch {i} attempt {attempt} failed: {e}")
            time.sleep(5 * (attempt + 1))
    print(f"batch {i//BATCH+1}/{(len(codes)+BATCH-1)//BATCH}  hans={len(hans)} hant={len(hant)}")
    time.sleep(2)

json.dump({"hans": hans, "hant": hant}, open("/tmp/cn_names.json", "w"), ensure_ascii=False)
print(f"DONE hans={len(hans)} hant={len(hant)} of {len(codes)}")
