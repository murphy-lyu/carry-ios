#!/usr/bin/env python3
# 从 Wikidata 抓航司名的多语言标签 → /tmp/airline_names.json {iata: {langKey: name}}。
# 先按 IATA 航司码(P229) 匹配；未命中的再按 ICAO(P230) 兜底。
# langKey：en + zh-Hans / zh-Hant / de / es / fr / ja / ko / pt-BR（航司英文名也抓，OpenFlights 名过时）。
import json, time, urllib.parse, urllib.request

airlines = json.load(open("/Users/murphy/Documents/Projects/Carry/Carry/Resources/airlines.json"))
codes = [a["iata"] for a in airlines]
icao_of = {a["iata"]: a["icao"] for a in airlines if a.get("icao")}
iata_of_icao = {v: k for k, v in icao_of.items()}

ENDPOINT = "https://query.wikidata.org/sparql"
HEADERS = {"Accept": "application/json", "User-Agent": "CarryApp/1.0 (airline data build; murphy.lyu@hotmail.com)"}

QVARS = ["en", "hans", "hant", "zh", "de", "es", "fr", "ja", "ko", "ptbr", "pt"]
WLANG = {"en": "en", "hans": "zh-hans", "hant": "zh-hant", "zh": "zh", "de": "de", "es": "es",
         "fr": "fr", "ja": "ja", "ko": "ko", "ptbr": "pt-br", "pt": "pt"}

def query(values, prop, keyvar):
    """prop=P229(IATA 航司码)/P230(ICAO 航司码)；keyvar 标识航司的变量名。"""
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
    for key, val in [("en", g("en")), ("zh-Hans", g("hans") or g("zh")), ("zh-Hant", g("hant") or g("zh")),
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

# IATA 可能被多家航司历史复用，P229 在 Wikidata 也可能匹配到多个实体；
# absorb 用 setdefault「首次命中保留」，配合 build 脚本的现役优先，足够日常识别。
run_pass(codes, "P229", "iata", lambda v: v if v in set(codes) else None, "names(iata)")
# 仍无任何本地化名（含 en）的，用 ICAO 兜底。
missing_icaos = [icao_of[c] for c in codes if not names.get(c) and c in icao_of]
print(f"ICAO fallback for {len(missing_icaos)} airlines with no name via IATA")
run_pass(missing_icaos, "P230", "icao", lambda v: iata_of_icao.get(v), "names(icao)")

out = {k: v for k, v in names.items() if v}
json.dump(out, open("/tmp/airline_names.json", "w"), ensure_ascii=False)
print(f"DONE airline names: {len(out)}/{len(codes)} airlines have >=1 label")
