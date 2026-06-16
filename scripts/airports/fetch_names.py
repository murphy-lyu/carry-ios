#!/usr/bin/env python3
# 从 Wikidata 抓机场名的多语言标签 → /tmp/names.json {iata: {langKey: name}}。
# 先按 IATA(P238) 匹配；未命中的再按 ICAO(P239) 兜底（部分实体只设了 ICAO 没设 IATA）。
# langKey 用客户端键：zh-Hans / zh-Hant / de / es / fr / ja / ko / pt-BR（en 用 OurAirports 原名，不抓）。
import json, time, urllib.parse, urllib.request

airports = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"))
codes = [a["iata"] for a in airports]
icao_of = {a["iata"]: a["icao"] for a in airports if a["icao"]}
iata_of_icao = {v: k for k, v in icao_of.items()}

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airport data build; murphy.lyu@hotmail.com)"}

QVARS = ["hans", "hant", "zh", "de", "es", "fr", "ja", "ko", "ptbr", "pt"]
WLANG = {"hans": "zh-hans", "hant": "zh-hant", "zh": "zh", "de": "de", "es": "es",
         "fr": "fr", "ja": "ja", "ko": "ko", "ptbr": "pt-br", "pt": "pt"}

def query(values, prop, keyvar):
    """prop=P238(IATA)/P239(ICAO)；keyvar 是返回里标识机场的变量名。"""
    opt = "\n".join(f'OPTIONAL {{ ?a rdfs:label ?{v}. FILTER(LANG(?{v})="{WLANG[v]}") }}' for v in QVARS)
    vals = " ".join(chr(34) + c + chr(34) for c in values)
    q = f'SELECT ?{keyvar} {" ".join("?"+v for v in QVARS)} WHERE {{ VALUES ?{keyvar} {{ {vals} }} ?a wdt:{prop} ?{keyvar} . {opt} }}'
    url = ENDPOINT + "?" + urllib.parse.urlencode({"format": "json", "query": q})
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=90) as r:
        return json.load(r)["results"]["bindings"]

names = {}

def absorb(b, iata):
    g = lambda v: b.get(v, {}).get("value")
    m = names.setdefault(iata, {})
    for key, val in [("zh-Hans", g("hans") or g("zh")), ("zh-Hant", g("hant") or g("zh")),
                     ("de", g("de")), ("es", g("es")), ("fr", g("fr")),
                     ("ja", g("ja")), ("ko", g("ko")), ("pt-BR", g("ptbr") or g("pt"))]:
        if val and key not in m:
            m[key] = val

def run_pass(items, prop, keyvar, resolve, label):
    BATCH = 250
    for i in range(0, len(items), BATCH):
        chunk = items[i:i+BATCH]
        for attempt in range(4):
            try:
                for b in query(chunk, prop, keyvar):
                    iata = resolve(b[keyvar]["value"])
                    if iata:
                        absorb(b, iata)
                break
            except Exception as e:
                print(f"  {label} batch {i} attempt {attempt} failed: {e}")
                time.sleep(5 * (attempt + 1))
        print(f"{label} batch {i//BATCH+1}/{(len(items)+BATCH-1)//BATCH}  with-name={len(names)}")
        time.sleep(2)

# 第一遍：IATA
run_pass(codes, "P238", "iata", lambda v: v, "names(iata)")
# 第二遍：对仍无任何本地化名的机场，用 ICAO 兜底。
# 注意用 `not names.get(c)`（空 dict 也算缺）——IATA 可能匹配到「无标签的桩实体」（如 HSR/Rajkot），
# 此时富标签实体挂在 ICAO 上；若只判 `c not in names` 会把这些桩当成已抓而跳过、造成漏网。
missing_icaos = [icao_of[c] for c in codes if not names.get(c) and c in icao_of]
print(f"ICAO fallback for {len(missing_icaos)} airports with no name via IATA")
run_pass(missing_icaos, "P239", "icao", lambda v: iata_of_icao.get(v), "names(icao)")

out = {k: v for k, v in names.items() if v}
json.dump(out, open("/tmp/names.json", "w"), ensure_ascii=False)
print(f"DONE airport names: {len(out)}/{len(codes)} airports have >=1 localized name")
