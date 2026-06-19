# 航司数据库构建（airlines.json）

`Carry/Resources/airlines.json` 的可复现构建脚本。spec: `specs/itinerary-flight-search-first.md`。
用途：添加航班时按航班号前缀即时识别航司（`MU5431` → China Eastern Airlines / 中国东方航空）。

## 重建步骤

```bash
cd /tmp
curl -s -o airlines.dat https://raw.githubusercontent.com/jpatokal/openflights/master/data/airlines.dat
python3 <repo>/scripts/airlines/build_airlines.py   # 产出 airlines.json（en 暂用 OpenFlights 名）
python3 <repo>/scripts/airlines/fetch_names.py       # 从 Wikidata 抓多语言名(含 en) → /tmp/airline_names.json
python3 <repo>/scripts/airlines/build_airlines.py    # 再跑一次，并入 nm + 修正 en
```

## 裁剪规则

- `active == "Y"`，且有合法 2 位 IATA 航司码（字母数字，如 MU / 9C / U2）。
- 同一 IATA 历史复用 → 保留首个有 ICAO 的活跃条目。
- 当前产出：约 986 航司，~225KB，多语言名覆盖 ~95%。

## 名称策略

OpenFlights 英文名**过时**（如 9C 在 OpenFlights 叫 "China SSS"，实际为 Spring Airlines / 春秋航空）。
故**英文名也优先用 Wikidata**，命中则覆盖 OpenFlights name；Wikidata 无 en 时才回落 OpenFlights。

## 多语言名 nm

`nm` 键为客户端语言：`zh-Hans / zh-Hant / de / es / fr / ja / ko / pt-BR`（en 用顶层 `name`）。
缺失语言显示回落英文。Wikidata 多语言标签 CC0，无需署名（与机场库一致）。

## 来源与许可

- OpenFlights `airlines.dat`：ODbL（与机场库同源，`AboutView` 已署名）。
- Wikidata 标签：CC0。
