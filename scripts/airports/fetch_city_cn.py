#!/usr/bin/env python3
# 按 IATA 从 Wikidata 取「机场服务城市」(P931) 的简繁中文名，作为搜索别名（如 JFK→纽约）。
import json, time, urllib.parse, urllib.request

airports = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"))
codes = [a["iata"] for a in airports]

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airport data build; murphy.lyu@hotmail.com)"}

def run(values):
    q = """SELECT ?iata ?hans ?hant WHERE {
      VALUES ?iata { %s }
      ?a wdt:P238 ?iata . ?a wdt:P931 ?c .
      OPTIONAL { ?c rdfs:label ?hans. FILTER(LANG(?hans)="zh-hans") }
      OPTIONAL { ?c rdfs:label ?hant. FILTER(LANG(?hant)="zh-hant") }
    }""" % " ".join('"%s"' % c for c in values)
    url = ENDPOINT + "?" + urllib.parse.urlencode({"format": "json", "query": q})
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)["results"]["bindings"]

cities = {}  # iata -> set of zh city names
BATCH = 300
for i in range(0, len(codes), BATCH):
    chunk = codes[i:i+BATCH]
    for attempt in range(4):
        try:
            for b in run(chunk):
                code = b["iata"]["value"]
                s = cities.setdefault(code, set())
                for k in ("hans", "hant"):
                    v = b.get(k, {}).get("value")
                    if v:
                        s.add(v)
            break
        except Exception as e:
            print(f"  batch {i} attempt {attempt} failed: {e}")
            time.sleep(5 * (attempt + 1))
    print(f"batch {i//BATCH+1}/{(len(codes)+BATCH-1)//BATCH}  iata-with-city={len(cities)}")
    time.sleep(2)

out = {k: sorted(v) for k, v in cities.items() if v}
json.dump(out, open("/tmp/city_cn.json", "w"), ensure_ascii=False)
print(f"DONE iata-with-city-aliases={len(out)} of {len(codes)}")
