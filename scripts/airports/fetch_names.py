#!/usr/bin/env python3
# 按 IATA 从 Wikidata 抓机场名的多语言标签 → /tmp/names.json {iata: {langKey: name}}。
# langKey 用客户端键：zh-Hans / zh-Hant / de / es / fr / ja / ko / pt-BR（en 用 OurAirports 原名，不抓）。
import json, time, urllib.parse, urllib.request

airports = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"))
codes = [a["iata"] for a in airports]

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airport data build; murphy.lyu@hotmail.com)"}

# Wikidata 标签语言 → 客户端 langKey。带 zh / pt 兜底。
QVARS = ["hans", "hant", "zh", "de", "es", "fr", "ja", "ko", "ptbr", "pt"]
WLANG = {"hans": "zh-hans", "hant": "zh-hant", "zh": "zh", "de": "de", "es": "es",
         "fr": "fr", "ja": "ja", "ko": "ko", "ptbr": "pt-br", "pt": "pt"}

def run(values):
    opt = "\n".join(f'OPTIONAL {{ ?a rdfs:label ?{v}. FILTER(LANG(?{v})="{WLANG[v]}") }}' for v in QVARS)
    q = f'SELECT ?iata {" ".join("?"+v for v in QVARS)} WHERE {{ VALUES ?iata {{ {" ".join(chr(34)+c+chr(34) for c in values)} }} ?a wdt:P238 ?iata . {opt} }}'
    url = ENDPOINT + "?" + urllib.parse.urlencode({"format": "json", "query": q})
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=90) as r:
        return json.load(r)["results"]["bindings"]

names = {}
BATCH = 250
for i in range(0, len(codes), BATCH):
    chunk = codes[i:i+BATCH]
    for attempt in range(4):
        try:
            for b in run(chunk):
                code = b["iata"]["value"]
                g = lambda v: b.get(v, {}).get("value")
                m = names.setdefault(code, {})
                # 简繁带 zh 兜底；pt-BR 优先 pt-br 再 pt。
                for key, val in [("zh-Hans", g("hans") or g("zh")), ("zh-Hant", g("hant") or g("zh")),
                                 ("de", g("de")), ("es", g("es")), ("fr", g("fr")),
                                 ("ja", g("ja")), ("ko", g("ko")), ("pt-BR", g("ptbr") or g("pt"))]:
                    if val and key not in m:
                        m[key] = val
            break
        except Exception as e:
            print(f"  batch {i} attempt {attempt} failed: {e}")
            time.sleep(5 * (attempt + 1))
    print(f"names batch {i//BATCH+1}/{(len(codes)+BATCH-1)//BATCH}  with-name={len(names)}")
    time.sleep(2)

out = {k: v for k, v in names.items() if v}
json.dump(out, open("/tmp/names.json", "w"), ensure_ascii=False)
print(f"DONE airport names: {len(out)}/{len(codes)} airports have >=1 localized name")
