# Scene Climate Nudge

## 问题

用户填写目的地后，可能没有选择与目的地气候强相关的场景（比如去泰国没有选"☀️ Tropical"），导致清单漏掉关键物品。

## 方案

在 ScenePickerView 的场景选择界面上方，根据目的地国家 + 出发日期推断出"隐含场景"，将用户尚未选择的那些场景以轻提示形式展示，用户点击即可将其加入选择。

## 可用信号

| 信号 | 来源 | 说明 |
|------|------|------|
| 目的地国家代码 | `TripBundle.countryCode` | 由 geocoding 异步写入，初次创建时尚未完成 |
| 出发日期 | `TripBundle.departureDate` | 用于季节推断 |

## 生效范围

| Mode | 是否显示 | 原因 |
|------|----------|------|
| `.create(TripInfo)` | ❌ | TripInfo 不含 countryCode，geocoding 尚未发生 |
| `.autoPack` | ❌ | 同上 |
| `.edit(tripId)` | ✅ | TripBundle 已有 countryCode |
| `.suggest(tripId)` | ✅ | TripBundle 已有 countryCode |

若 countryCode 为空，不显示任何提示。

## 气候推断逻辑（ClimateInference.swift）

### Tropical（热带/海滩）

目标国家几乎全境属于热带气候，无论季节均适合推荐热带场景物品。

```
SE Asia: TH, ID, PH, MY, SG, VN, KH, LA, BN
Indian Ocean: MV, LK
Pacific islands: FJ, WS, TO, VU, PF, SB, PW, FM, MH, KI
Caribbean: CU, DO, JM, BS, BB, TT, LC, VC, GD, KN, AG
Central America: CR, PA, GT, BZ, HN, NI, SV
African islands: MU, SC, CV
```

### Winter（冬季/寒冷）

分两类：

**全年寒冷**（任意出发日期均推荐）：
```
IS (Iceland), GL (Greenland)
```

**季节性寒冷**（北半球冬季 = 11/12/1/2 月出发时推荐）：
```
East Asia: JP, KR, MN
Scandinavia: NO, SE, FI, DK
Baltics: EE, LV, LT
Central Europe: PL, CZ, SK, HU, AT, CH, DE
Eastern Europe: RU, UA, BY
North America: CA
```

### High Altitude（高海拔）

全境以高海拔著称的国家，无论季节均推荐：
```
NP, BT (Himalayas)
PE, BO, EC (Andes)
CO (Bogotá 2600m)
```

## 推断结果过滤

`inferredSceneKeys(countryCode:departureDate:)` 返回场景 key 列表。
ScenePickerView 用 `nudgeSceneKeys` 过滤掉已选中的场景，只显示尚未选择的建议。

## UI

- 位置：heroSection 下方，defaultSceneGroups 上方
- 仅在 `nudgeSceneKeys` 非空时显示
- Section 标题：`scenepicker.nudge.title`（"Based on your destination"）
- 复用 SceneChip 组件，点击 → 加入 selectedItems → 该 chip 消失（因为已选）
- 整个 nudge 区域当 nudgeSceneKeys 为空时自动隐藏，无需手动关闭按钮

## 本地化 keys

- `scenepicker.nudge.title`（结构化 key）

## 不在此版本范围内

- 大型多气候带国家的城市级推断（如 CN、US、AU、RU）—— 国家级信号太模糊
- 首次创建流程的实时 geocoding（留待 TripInfo 扩展时处理）
- Rainy 场景推断（季风区需要城市级数据，准确性低）
