#!/usr/bin/env python3
# 按 IATA 从 Wikidata 抓「机场服务城市」(P931) 的多语言名 → /tmp/cities.json {iata: [去重别名列表]}。
# 仅供搜索匹配（如「纽约」/「뉴욕」/「ニューヨーク」→ JFK），不用于显示。
import json, time, urllib.parse, urllib.request

airports = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"))
codes = [a["iata"] for a in airports]

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airport data build; murphy.lyu@hotmail.com)"}

# 抓城市名的语言（含简繁 + 6 语言）。英文城市名已在 airports.json 的 city 字段，这里不重复。
LANGS = ["zh-hans", "zh-hant", "de", "es", "fr", "ja", "ko", "pt-br", "pt"]
QVARS = [l.replace("-", "") for l in LANGS]

def run(values):
    opt = "\n".join(f'OPTIONAL {{ ?c rdfs:label ?{v}. FILTER(LANG(?{v})="{l}") }}'
                    for v, l in zip(QVARS, LANGS))
    q = f'SELECT ?iata {" ".join("?"+v for v in QVARS)} WHERE {{ VALUES ?iata {{ {" ".join(chr(34)+c+chr(34) for c in values)} }} ?a wdt:P238 ?iata . ?a wdt:P931 ?c . {opt} }}'
    url = ENDPOINT + "?" + urllib.parse.urlencode({"format": "json", "query": q})
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=90) as r:
        return json.load(r)["results"]["bindings"]

cities = {}
BATCH = 200
for i in range(0, len(codes), BATCH):
    chunk = codes[i:i+BATCH]
    for attempt in range(4):
        try:
            for b in run(chunk):
                code = b["iata"]["value"]
                s = cities.setdefault(code, set())
                for v in QVARS:
                    val = b.get(v, {}).get("value")
                    if val:
                        s.add(val)
            break
        except Exception as e:
            print(f"  batch {i} attempt {attempt} failed: {e}")
            time.sleep(5 * (attempt + 1))
    print(f"cities batch {i//BATCH+1}/{(len(codes)+BATCH-1)//BATCH}  with-city={len(cities)}")
    time.sleep(2)

out = {k: sorted(v) for k, v in cities.items() if v}
json.dump(out, open("/tmp/cities.json", "w"), ensure_ascii=False)
print(f"DONE city aliases: {len(out)}/{len(codes)} airports have >=1 localized city name")
