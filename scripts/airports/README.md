# 机场数据库构建（airports.json）

`Carry/Resources/airports.json` 的可复现构建脚本。spec: `specs/itinerary-airport-search.md`。

## 重建步骤

```bash
cd /tmp
curl -s -o ourairports.csv https://davidmegginson.github.io/ourairports-data/airports.csv
curl -s -o openflights.dat https://raw.githubusercontent.com/jpatokal/openflights/master/data/airports.dat
python3 <repo>/scripts/airports/build_airports.py   # 产出 airports.json（先不含本地化名）
python3 <repo>/scripts/airports/fetch_names.py       # 从 Wikidata 抓 8 语言机场名 → /tmp/names.json
python3 <repo>/scripts/airports/fetch_cities.py      # 从 Wikidata(P931) 抓 8 语言服务城市名 → /tmp/cities.json
python3 <repo>/scripts/airports/build_airports.py    # 再跑一次，并入 nm（本地化名）+ cs（城市别名）
```

## 裁剪规则

- 排除 closed / heliport / balloonport。
- 保留有定期航班（`scheduled_service == yes`）的机场，并入所有大型机场（`large_airport`）。
- 必须有 3 位 IATA 码。
- 当前产出：约 4100+ 机场，~1.6MB，时区覆盖 ~92%。

## 时区

OurAirports 不含时区 → 用 OpenFlights 按 IATA/ICAO 补 IANA 时区。仍缺失的，
仅当某国「已知时区的机场全部同一时区」时用该时区兜底（多时区国家如 US/RU/AU 保持空，不猜）。

## 多语言名与城市别名

支持全部 9 种界面语言。`en` 用 OurAirports 原名（`name` 字段）；其余 8 语言从 Wikidata 抓取。
抓取先按 IATA(`P238`)匹配，对仍无标签的（含匹配到「无标签桩实体」的）再按 ICAO(`P239`)兜底。
仍缺失的为长尾（全新机场 Wikidata 仅英文 / 源间编码不一致 / 微型机场无实体），一律回落英文——
**不做模糊匹配或机器翻译**，避免贴错机场名或音译出错（正确性优先于覆盖率）。

- 本地化机场名（字段 `nm`，`{langKey: name}`）：Wikidata（`P238` = IATA）的 `zh-hans`/`zh-hant`/`de`/`es`/`fr`/`ja`/`ko`/`pt-br`(带 `pt`/`zh` 兜底) 标签。**用于显示 + 搜索**。某语言缺失则省略该键、显示回落英文。覆盖率（占总数）：fr 91% / ja 82% / zh 75% / de 61% / es 54% / ko·pt-BR 24%。
- 城市别名（字段 `cs`，全语言字符串列表）：Wikidata `P931`（机场服务城市）各语言名，**仅供搜索匹配**（如「纽约」/「뉴욕」/「ニューヨーク」→ JFK），不用于显示。覆盖 ~85%。

> langKey 与客户端 `AirportLocale.languageKey` 一致：zh 按 Hant/TW/HK/MO 区分简繁，pt 归 pt-BR。

## 数据来源与许可（App 内已署名，见 AboutView「数据来源」卡）

- **OurAirports** — Public Domain（机场列表/坐标/IATA/ICAO/城市/国家）。
- **OpenFlights** — ODbL（IANA 时区）。**ODbL 要求署名**。
- **Wikidata** — CC0（多语言机场名与城市名）。
