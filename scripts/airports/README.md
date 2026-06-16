# 机场数据库构建（airports.json）

`Carry/Resources/airports.json` 的可复现构建脚本。spec: `specs/itinerary-airport-search.md`。

## 重建步骤

```bash
cd /tmp
curl -s -o ourairports.csv https://davidmegginson.github.io/ourairports-data/airports.csv
curl -s -o openflights.dat https://raw.githubusercontent.com/jpatokal/openflights/master/data/airports.dat
python3 <repo>/scripts/airports/build_airports.py   # 产出 airports.json（不含中文名）
python3 <repo>/scripts/airports/fetch_cn.py          # 从 Wikidata 抓机场简繁中文名 → /tmp/cn_names.json
python3 <repo>/scripts/airports/fetch_city_cn.py     # 从 Wikidata(P931) 抓服务城市中文名 → /tmp/city_cn.json
python3 <repo>/scripts/airports/build_airports.py    # 再跑一次，并入中文名 + 城市别名
```

## 裁剪规则

- 排除 closed / heliport / balloonport。
- 保留有定期航班（`scheduled_service == yes`）的机场，并入所有大型机场（`large_airport`）。
- 必须有 3 位 IATA 码。
- 当前产出：约 4100+ 机场，~850KB，时区覆盖 ~92%，中文名覆盖 ~76%。

## 时区

OurAirports 不含时区 → 用 OpenFlights 按 IATA/ICAO 补 IANA 时区。仍缺失的，
仅当某国「已知时区的机场全部同一时区」时用该时区兜底（多时区国家如 US/RU/AU 保持空，不猜）。

## 中文名与城市别名

- 机场中文名：Wikidata（`P238` = IATA）取 `zh-hans` / `zh-hant` 标签（带 `zh` 兜底）。缺失则显示回落英文原名。
- 城市中文别名（字段 `cs`）：Wikidata `P931`（机场服务城市）的简繁中文名，**仅供搜索匹配**（如「纽约」→ JFK），不用于显示。覆盖 ~2800 机场。

## 数据来源与许可（App 内需署名）

- **OurAirports** — Public Domain（机场列表/坐标/IATA/ICAO/城市/国家）。
- **OpenFlights** — ODbL（仅取 IANA 时区）。**ODbL 要求署名**，需在 App 的「关于/致谢」处标注。
- **Wikidata** — CC0（中文名）。

> 待办：在设置内「关于 / 致谢」补一条数据来源署名（至少 OpenFlights，ODbL 要求）。
