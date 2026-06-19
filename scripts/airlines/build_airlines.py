#!/usr/bin/env python3
# 从 OpenFlights airlines.dat 构建精简 airlines.json（IATA 二字码 → 航司名）。
# 用途：添加航班时按航班号前缀即时识别航司（MU → China Eastern Airlines）。spec: itinerary-flight-search-first.md。
#
# 裁剪：active=="Y" 且有合法 2 位 IATA 码。
# 名称策略：英文名也优先 Wikidata（OpenFlights 英文名过时，如 9C 在 OpenFlights 叫 "China SSS"，
#   实际为 Spring Airlines / 春秋航空）；Wikidata 无 en 时回落 OpenFlights name。多语言名同机场库范式。
import csv, json, os

# OpenFlights airlines.dat 字段：ID,Name,Alias,IATA,ICAO,Callsign,Country,Active
rows = []
with open("/tmp/airlines.dat", newline="", encoding="utf-8") as f:
    for r in csv.reader(f):
        if len(r) < 8:
            continue
        name, _alias, iata, icao, _call, _country, active = r[1], r[2], r[3].strip(), r[4].strip(), r[5], r[6], r[7].strip()
        if active != "Y":
            continue
        iata = iata.upper()
        # 合法 IATA 航司码 = 2 位字母数字（如 MU / 9C / U2）；排除占位符。
        if len(iata) != 2 or iata in ("-", "\\N", "N/A") or not iata.isalnum():
            continue
        icao = "" if icao in ("", "\\N", "N/A") else icao.upper()
        rows.append({"iata": iata, "icao": icao, "name": name.strip()})

# 同一 IATA 历史上可能被多家复用；保留首个有 ICAO 的活跃条目（OpenFlights 大致按 ID 排序，
# 早注册的多为现役主航司），无 ICAO 的仅在该 IATA 尚无条目时占位。
by_iata = {}
for a in rows:
    cur = by_iata.get(a["iata"])
    if cur is None:
        by_iata[a["iata"]] = a
    elif not cur["icao"] and a["icao"]:
        by_iata[a["iata"]] = a

airlines = list(by_iata.values())

# 并入 Wikidata 多语言名 nm（含 en）。en 命中则覆盖 OpenFlights name（更准更新）；
# 其余语言 zh-Hans/zh-Hant/de/es/fr/ja/ko/pt-BR 进 nm，缺失显示回落英文。
nm_with = 0
try:
    names = json.load(open("/tmp/airline_names.json", encoding="utf-8"))
    for a in airlines:
        m = names.get(a["iata"]) or (names.get(a["icao"]) if a["icao"] else None)
        if not m:
            continue
        if m.get("en"):
            a["name"] = m["en"]
        nm = {k: v for k, v in m.items() if k != "en"}
        if nm:
            a["nm"] = nm
            nm_with += 1
    print(f"localized names merged: {nm_with}")
except FileNotFoundError:
    print("airline_names.json not found — skipping localized names (en from OpenFlights)")

airlines.sort(key=lambda a: a["iata"])

# 不变式硬断言：iata 2 位字母数字、全局唯一（客户端 Airline.id = iata）。
_iatas = [a["iata"] for a in airlines]
assert all(len(i) == 2 and i.isalnum() for i in _iatas), "bad IATA airline code present"
assert len(_iatas) == len(set(_iatas)), "duplicate IATA airline codes present"
assert all(a["name"] for a in airlines), "airline with empty name present"

out = "/Users/murphy/Documents/Projects/Carry/Carry/Resources/airlines.json"
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    json.dump(airlines, f, ensure_ascii=False, separators=(",", ":"))

total = len(airlines)
size_kb = os.path.getsize(out) / 1024
print(f"airlines: {total}  with_localized: {nm_with}  size: {size_kb:.0f} KB")
print("sample MU:", json.dumps(by_iata.get("MU", {}), ensure_ascii=False))
print("sample 9C:", json.dumps(by_iata.get("9C", {}), ensure_ascii=False))
