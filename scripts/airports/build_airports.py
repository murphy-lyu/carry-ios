#!/usr/bin/env python3
# 合并 OurAirports（机场列表，更新及时）+ OpenFlights（补 IANA 时区）→ 精简 airports.json
# 裁剪：large/medium airport，有 IATA 码，且（有定期航班 或 large）。
import csv, json

# OpenFlights：IATA/ICAO -> IANA tz
of_iata, of_icao = {}, {}
with open("/tmp/openflights.dat", newline="", encoding="utf-8") as f:
    for row in csv.reader(f):
        if len(row) < 12:
            continue
        iata, icao, tz = row[4].strip(), row[5].strip(), row[11].strip()
        if tz in ("", "\\N"):
            continue
        if len(iata) == 3 and iata != "\\N":
            of_iata[iata.upper()] = tz
        if icao and icao != "\\N":
            of_icao[icao.upper()] = tz

airports = []
with open("/tmp/ourairports.csv", newline="", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        t = r["type"]
        if t in ("closed", "heliport", "balloonport"):
            continue
        iata = r["iata_code"].strip().upper()
        if len(iata) != 3:
            continue
        scheduled = r["scheduled_service"].strip() == "yes"
        # 有定期航班的机场为准（不限机场规模等级），再并入所有大型机场。
        if not scheduled and t != "large_airport":
            continue
        icao = (r["icao_code"].strip() or r["gps_code"].strip()).upper()
        tz = of_iata.get(iata) or (of_icao.get(icao) if icao else None) or ""
        try:
            lat = round(float(r["latitude_deg"]), 5)
            lon = round(float(r["longitude_deg"]), 5)
        except ValueError:
            continue
        airports.append({
            "iata": iata,
            "icao": icao,
            "name": r["name"].strip(),
            "city": r["municipality"].strip(),
            "country": r["iso_country"].strip(),
            "lat": lat,
            "lon": lon,
            "tz": tz,
            "large": t == "large_airport",
        })

# 时区兜底：仅当某国所有「已知 tz」的机场共用同一时区时，才用它补该国空缺；
# 多时区国家（US/RU/AU 等）一律保持空，不猜。
from collections import defaultdict
country_tzs = defaultdict(set)
for a in airports:
    if a["tz"]:
        country_tzs[a["country"]].add(a["tz"])
single_tz = {c: next(iter(s)) for c, s in country_tzs.items() if len(s) == 1}
filled = 0
for a in airports:
    if not a["tz"] and a["country"] in single_tz:
        a["tz"] = single_tz[a["country"]]
        filled += 1
print(f"tz backfilled from single-tz country: {filled}")

# 并入中文名（zh-Hans / zh-Hant），由 fetch_cn.py 从 Wikidata 抓取；缺失则省略，显示回落英文。
cn_with = 0
try:
    cn = json.load(open("/tmp/cn_names.json", encoding="utf-8"))
    hans, hant = cn["hans"], cn["hant"]
    for a in airports:
        h, t = hans.get(a["iata"]), hant.get(a["iata"])
        if h: a["hans"] = h
        if t: a["hant"] = t
        if h or t: cn_with += 1
    print(f"cn names merged: {cn_with}")
except FileNotFoundError:
    print("cn_names.json not found — skipping Chinese names")

airports.sort(key=lambda a: a["iata"])
out = "/Users/murphy/Documents/Projects/Carry/Carry/Resources/airports.json"
import os
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    json.dump(airports, f, ensure_ascii=False, separators=(",", ":"))

total = len(airports)
with_tz = sum(1 for a in airports if a["tz"])
large = sum(1 for a in airports if a["large"])
size_kb = os.path.getsize(out) / 1024
print(f"airports: {total}  large: {large}  with_tz: {with_tz} ({with_tz*100//total}%)  size: {size_kb:.0f} KB")
print("sample:", json.dumps(airports[0], ensure_ascii=False))
