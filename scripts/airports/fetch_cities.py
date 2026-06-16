#!/usr/bin/env python3
# 从 Wikidata 抓「机场服务城市」(P931) 的多语言名 → /tmp/cities.json {iata: [去重别名列表]}。
# 仅供搜索匹配（如「纽约」/「뉴욕」/「ニューヨーク」→ JFK），不用于显示。
# 先按 IATA(P238) 匹配；未命中的再按 ICAO(P239) 兜底。
import json, time, urllib.parse, urllib.request

airports = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"))
codes = [a["iata"] for a in airports]
icao_of = {a["iata"]: a["icao"] for a in airports if a["icao"]}
iata_of_icao = {v: k for k, v in icao_of.items()}

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airport data build; murphy.lyu@hotmail.com)"}

LANGS = ["zh-hans", "zh-hant", "de", "es", "fr", "ja", "ko", "pt-br", "pt"]
QVARS = [l.replace("-", "") for l in LANGS]

def query(values, prop, keyvar):
    opt = "\n".join(f'OPTIONAL {{ ?c rdfs:label ?{v}. FILTER(LANG(?{v})="{l}") }}' for v, l in zip(QVARS, LANGS))
    vals = " ".join(chr(34) + c + chr(34) for c in values)
    q = f'SELECT ?{keyvar} {" ".join("?"+v for v in QVARS)} WHERE {{ VALUES ?{keyvar} {{ {vals} }} ?a wdt:{prop} ?{keyvar} . ?a wdt:P931 ?c . {opt} }}'
    url = ENDPOINT + "?" + urllib.parse.urlencode({"format": "json", "query": q})
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=90) as r:
        return json.load(r)["results"]["bindings"]

cities = {}

def run_pass(items, prop, keyvar, resolve, label):
    BATCH = 200
    for i in range(0, len(items), BATCH):
        chunk = items[i:i+BATCH]
        for attempt in range(4):
            try:
                for b in query(chunk, prop, keyvar):
                    iata = resolve(b[keyvar]["value"])
                    if not iata:
                        continue
                    s = cities.setdefault(iata, set())
                    for v in QVARS:
                        val = b.get(v, {}).get("value")
                        if val:
                            s.add(val)
                break
            except Exception as e:
                print(f"  {label} batch {i} attempt {attempt} failed: {e}")
                time.sleep(5 * (attempt + 1))
        print(f"{label} batch {i//BATCH+1}/{(len(items)+BATCH-1)//BATCH}  with-city={len(cities)}")
        time.sleep(2)

# 第一遍：IATA
run_pass(codes, "P238", "iata", lambda v: v, "cities(iata)")
# 第二遍：对仍无城市别名的机场，用 ICAO 兜底（同 fetch_names：空集也算缺，覆盖桩实体情形）。
missing_icaos = [icao_of[c] for c in codes if not cities.get(c) and c in icao_of]
print(f"ICAO fallback for {len(missing_icaos)} airports with no city via IATA")
run_pass(missing_icaos, "P239", "icao", lambda v: iata_of_icao.get(v), "cities(icao)")

out = {k: sorted(v) for k, v in cities.items() if v}
json.dump(out, open("/tmp/cities.json", "w"), ensure_ascii=False)
print(f"DONE city aliases: {len(out)}/{len(codes)} airports have >=1 localized city name")
