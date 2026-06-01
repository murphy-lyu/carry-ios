# Voltage Converter Nudge（美发电器 × 电压预警）

> **Status: Implemented & Verified（已实现并验证）** — 模拟器实测通过：大陆(220V) → 纽约(120V) + 清单含直发棒/吹风机 → 插头卡片电压行显示橙色「⚡️ 120V · may need a converter」。女性出行视角的第一条落地功能（见记忆 `project_carry_female_user_ideas`）。

## 动机

女性出行普遍携带卷发棒/直发器/吹风机等**电热设备**。真实痛点：把 110V 单电压设备插进 220–240V 国家会**烧坏**；且很多人不知道**转换插头(adapter)只改插头形状、不变电压**，真正变压要**变压器(converter)**。Carry 已有目的地电压数据(`PlugCatalog`)和家乡国家码(`DestinationInfoView.homeCountryCode`)，可零成本做一个智能提醒。

## 核心设计原则

1. **复用现有数据，不新增数据源**：电压来自 `PlugCatalog`，家乡来自 `Locale.current.region`，清单物品来自 `TripBundle.sections → PackingItem.name`。
2. **克制、不新增布局行**：提醒**就地**改造「插头 & 电压」卡片里已有的电压那一行（变橙色 + 加一句短提示），**不新增行、不新增卡片**，单行 + `minimumScaleFactor` → 零布局溢出风险。
3. **不误报、不制造焦虑**：用词是"**可能**需要变压器"（设备可能本就是全电压 100–240V，无需变压），只在真有电热设备 + 真有电压档位差时出现。
4. **条件收敛**：插头卡片本就在 `allDestinationsAreHome` 时隐藏（国内行无电压问题）。预警是其子集，天然不会在国内行出现。

## 触发条件（两者同时满足）

1. **清单含电热设备**：`trip.sections` 任一 `PackingItem.name`（规范化后）命中 `heatingAppliances` 集合。
2. **电压档位不同**：家乡电压档 ≠ 任一目的地电压档。档位定义：`< 160V` 为低压档(100–127V)，`≥ 160V` 为高压档(220–240V)。

## 实现（仅 `DestinationInfoView.swift`）

新增计算属性：
- `heatingAppliances: Set<String>`：电热设备规范英文名集合（`Hair straightener` 等）。
- `hasHeatingAppliance: Bool`：遍历 `trip.sections?.flatMap{ $0.items }` 匹配。
- `homeVoltage: Int?`：`PlugCatalog.info(for: homeCountryCode)?.voltage`。
- `voltageBand(_:) -> Int` + `showConverterWarning: Bool`。

改造 `plugCard` 的电压行：`showConverterWarning` 时——
- 文案：`"{电压}V / {频率}Hz · {destination.plug.voltage_warning}"`——**保留 Hz，与无警示状态信息一致**（迭代结论：先试过去掉 Hz / 两行版，最终定为「单行保留 Hz」最利落且一致）；
- 颜色：整行 `Color.alertOrange`（已存在于 `PackingList.swift`）；
- 前缀 `bolt.trianglebadge.exclamationmark.fill` 图标；
- `lineLimit(1)` + `minimumScaleFactor(0.8)`（德/西语较长时自动缩放，不破版）。

## 本地化

新增结构化 key `destination.plug.voltage_warning`（**须含显式 `en`** + 全 9 语言）。短语，文化适配（德语名词大写、法语避免半角问号、韩语 해요体）：
| 语言 | 值 |
|---|---|
| en | may need a converter |
| zh-Hans | 可能需要变压器 |
| zh-Hant | 可能需要變壓器 |
| de | evtl. Spannungswandler nötig |
| es | puede requerir transformador |
| fr | prévoir un convertisseur |
| ja | 変圧器が必要な場合あり |
| ko | 변압기가 필요할 수 있어요 |
| pt-BR | pode precisar de conversor |

## 已知限制 / 后续

- **物品库电热设备**：已含 `Hair straightener`（其 zh-Hans 译文「直发棒/卷发棒」已涵盖卷发器）；本次**补入 `Hair dryer`（吹风机）**（Personal Care 组 + 9 语言文案）。未加 `Curling iron`——其中文与 straightener 的「/卷发棒」重复，会造成歧义；如要拆分需同步收紧 straightener 译文，属独立小任务。`heatingAppliances` 集合仍预置了 `curling iron` 等规范名以备将来扩库。
- **自定义/他语种物品名**（如用户自建"卷发棒"）当前不命中（集合是英文规范名）。可接受的 v1 限制。
- **视觉须真机/模拟器验收**：单行 + `minimumScaleFactor` 不会破版，但德/西语较长时缩放幅度待观察。
