#!/usr/bin/env python3
# 重建 airlines.json（IATA 二字码 → 航司名 + 多语言名），权威源 = Wikidata 实体自身的 label。
# spec: itinerary-flight-search-first.md / itinerary-flight-name-localization.md。
#
# 为什么是这套方案（2026-06-26 重写，根治旧版数据错误）：
#   旧版从 OpenFlights airlines.dat 取列表、再按 IATA/ICAO 去 Wikidata「langlink」抓多语言名。
#   两处都会错：① 同一 IATA 码历史上被多家航司复用（现役/前身/货运子公司/同名废航司），
#   OpenFlights 的「取首个有 ICAO 的」启发式会选错正主（CA 选成 Dalian、BA 选成 BOAC、
#   QR 选成 Paraense…）；② langlink 抓取会把译名关联到错的实体（~15% 条目译名指向别的航司）。
#   ICAO 也并非唯一（前身/子公司共用同一 ICAO），按 ICAO 合并 label 会跨实体污染。
#
# 本版做法（唯一可靠口径）：
#   1. 列出当前 airlines.json 里的 IATA 清单（沿用既有成员集，不擅自增删航司）。
#   2. 对每个 IATA，查 Wikidata 所有持有该 P229 的航司实体，按「未注销优先 → 维基百科
#      sitelinks 最多」选**正主单一实体**（sitelinks 强区分 Air China vs 前身/货运/同名小航司）。
#   3. 取**该单一实体**的多语言 label（绝不跨实体合并 → 无污染）。
#   4. zh-Hans/zh-Hant 槽无条件过 OpenCC 归一（simp 槽必简、trad 槽必繁），根治繁简泄漏。
#   5. 英文名缺失时用拉丁语 label（de/es/fr/pt，航司专名通常不翻译）兜底，绝不回退旧错名。
#   6. 清掉飞不进航班号解析的垃圾码（纯数字 / 非 ASCII）。
#
# 依赖：curl（直连 query.wikidata.org）、opencc（pip install opencc-python-reimplemented）。
# 用法：python3 scripts/airlines/build_airlines.py  → 原地覆写 Carry/Resources/airlines.json。
import json, subprocess, time, sys, os
from collections import defaultdict
from opencc import OpenCC

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "Carry/Resources/airlines.json")
UA = "CarryAirlineAudit/1.0 (murphy.lyu@hotmail.com)"
LANGS = ["en", "zh-hans", "zh-hant", "zh", "zh-hk", "zh-tw", "de", "es", "fr", "ja", "ko", "pt-br", "pt"]
LANG_FILTER = ",".join(f'"{l}"' for l in LANGS)
t2s = OpenCC("t2s").convert
s2t = OpenCC("s2t").convert


def sparql(query):
    for attempt in range(3):
        out = subprocess.run(
            ["curl", "-s", "--max-time", "120", "-G", "https://query.wikidata.org/sparql",
             "--data-urlencode", f"query={query}",
             "-H", "Accept: application/sparql-results+json", "-H", f"User-Agent: {UA}"],
            capture_output=True, text=True).stdout
        try:
            return json.loads(out)["results"]["bindings"]
        except Exception:
            time.sleep(3)
    raise RuntimeError("SPARQL failed after retries")


def valid_iata(code):
    # 能被 FlightNumberParser 命中的前提：2 位 ASCII 字母数字，且至少含一个 ASCII 字母。
    return len(code) == 2 and code.isascii() and code.isalnum() and any(c.isalpha() for c in code)


def main():
    current = json.load(open(OUT, encoding="utf-8"))
    inventory = sorted({a["iata"] for a in current if valid_iata(a["iata"])})
    cur_name = {a["iata"]: a["name"] for a in current}
    print(f"inventory: {len(inventory)} IATA codes", file=sys.stderr)

    # 1) 所有 IATA 航司实体的元数据（iata / icao / sitelinks / 是否注销）。
    meta = sparql("""SELECT ?a ?iata ?icao ?n (BOUND(?dis) AS ?dissolved) WHERE {
      ?a wdt:P229 ?iata . ?a wikibase:sitelinks ?n .
      OPTIONAL { ?a wdt:P230 ?icao } OPTIONAL { ?a wdt:P576 ?dis } }""")
    cands = defaultdict(list)
    for b in meta:
        cands[b["iata"]["value"]].append({
            "qid": b["a"]["value"].rsplit("/", 1)[-1],
            "icao": b.get("icao", {}).get("value", ""),
            "n": int(b["n"]["value"]),
            "dissolved": b["dissolved"]["value"] == "true"})

    # 2) 每个码选正主：未注销优先 → sitelinks 最多。
    principal = {}
    for iata in inventory:
        cs = cands.get(iata)
        if cs:
            principal[iata] = max(cs, key=lambda r: (0 if r["dissolved"] else 1, r["n"]))
    qids = sorted({p["qid"] for p in principal.values()})
    print(f"principals resolved: {len(principal)} / {len(inventory)}", file=sys.stderr)

    # 3) 取正主实体的多语言 label（逐实体，绝不跨实体合并）。
    labels = defaultdict(dict)
    B = 150
    for i in range(0, len(qids), B):
        values = " ".join(f"wd:{q}" for q in qids[i:i + B])
        for b in sparql(f"SELECT ?a ?label WHERE {{ VALUES ?a {{ {values} }} "
                        f"?a rdfs:label ?label . FILTER(LANG(?label) IN ({LANG_FILTER})) }}"):
            labels[b["a"]["value"].rsplit("/", 1)[-1]][b["label"]["xml:lang"]] = b["label"]["value"]
        print(f"  labels {min(i+B, len(qids))}/{len(qids)}", file=sys.stderr)
        time.sleep(1)

    # 4) 组装。
    def build_nm(L):
        zhs = L.get("zh-hans") or L.get("zh-hant") or L.get("zh-hk") or L.get("zh-tw") or L.get("zh")
        zht = L.get("zh-hant") or L.get("zh-hk") or L.get("zh-tw") or L.get("zh-hans") or L.get("zh")
        m = {"zh-Hans": t2s(zhs) if zhs else None,   # 无条件归一：simp 槽必简体
             "zh-Hant": s2t(zht) if zht else None,    # trad 槽必繁体
             "de": L.get("de"), "es": L.get("es"), "fr": L.get("fr"),
             "ja": L.get("ja"), "ko": L.get("ko"), "pt-BR": L.get("pt-br") or L.get("pt")}
        return {k: v for k, v in m.items() if v}

    def en_name(L, fb):
        if not L:
            return fb
        return L.get("en") or L.get("de") or L.get("es") or L.get("fr") or L.get("pt-br") or L.get("pt") or fb

    out = []
    for iata in inventory:
        p = principal.get(iata)
        L = labels.get(p["qid"]) if p else None
        entry = {"iata": iata, "icao": (p["icao"] if p else ""), "name": en_name(L, cur_name[iata])}
        if L:
            nm = build_nm(L)
            if nm:
                entry["nm"] = nm
        out.append(entry)
    out.sort(key=lambda x: x["iata"])

    # 不变式硬断言（同客户端 Airline.id = iata）。
    ia = [x["iata"] for x in out]
    assert all(len(i) == 2 and i.isalnum() for i in ia), "bad IATA code"
    assert len(ia) == len(set(ia)), "duplicate IATA code"
    assert all(x["name"] for x in out), "empty name"

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(f"airlines: {len(out)}  size: {os.path.getsize(OUT)/1024:.0f} KB")


if __name__ == "__main__":
    main()
