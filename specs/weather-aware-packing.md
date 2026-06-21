# 天气感知的打包建议与天气提醒（Weather-aware Packing & Alerts）

> **Status: Draft（设计已定，待上线接 Apple Weather 时落地）** — 本 spec 把设计固化，不含实现。WeatherKit 数据层（`WeatherManager`）与 7 天预报展示（`DestinationInfoView`）**已存在**；本功能是「把真实天气喂进打包/提醒」的连接 + 升级，不是从零造。
>
> **依赖现状（实现时直接复用，勿重造）**：
> - `WeatherManager`(WeatherKit)：已拉 7 天日预报（日期+图标+高温），3 小时缓存、失败回退、署名已处理。免费档限制：≤10 天行程、出发 >10 天暂不显。
> - `ClimateInference.inferredSceneKeys(countryCode:departureDate:)`：**只看国家+月份**的粗推断，仅产出 `tropical/winter/high_altitude`，**不推 rain**。
> - `SceneItemMap`：场景→物品库（含 `rainy_city`/`winter`/`tropical`/`high_altitude`）。
> - nudge 范式：场景气候 chip（ScenePicker）、Surprise Item 可消除卡（PackingList）、电压内联 nudge（DestinationInfo）。
> - `NotificationManager`：`collectXxx`→`Candidate` + 64 全局预算 + Settings「行程提醒」分模块。

## 动机

行程的打包该带什么，**很大程度由那几天的真实天气决定**——尤其"用户大概率没料到、但该带"的：临时一场雨、突然降温、热浪、暴雪、极端天气。Carry 已能拿到目的地预报，却还没用它指导打包；驱动打包的 `ClimateInference` 只有国家+月份的粗猜测、且**完全不管下雨**。把真实天气接进来，是一个"app 替你盯着、关键时刻提醒一句"的高价值、强体验、低成本的点——契合 Carry「made with love」与克制。

## 核心设计原则

1. **粗 → 精分层**：远期（WeatherKit 拿不到，免费档 ~10 天外）用 `ClimateInference` 季节性兜底（已在做）；近期（进 10 天窗口）用**真实预报**精修。行程刚建先给个气候底，临近出发真实预报进来再补一句。
2. **例外驱动，不日常播报**：普通/预期之内的天气**不出声**（DestinationInfo 摆着即可）。只在**显著且可行动**（雨/雪/高温/低温/极端）、且**用户大概率会漏**时才提示。这是克制的核心。
3. **建议，不静默自动加**：一切天气物品都是「一点即加」的建议，**绝不**替用户自动写入清单——延续 Carry opt-in nudge 哲学，保住信任。
4. **去重**：已在清单里的物品（手动 / 场景带入）不再建议（照搬电压 nudge「先查已有清单」）。
5. **文案是灵魂**：具体到「哪天·哪城·什么天气」，像朋友替你看过预报，而非系统播报。
6. **优雅降级**：天气拉取失败 / 无网 / 无日期行程 → 静默跳过天气逻辑，其余功能不受影响（`WeatherManager` 已有缓存+回退）。

---

## 第一部分：天气感知的打包建议

### 1. 信号提炼（trip 那几天的预报 → 显著天气）

输入：`WeatherManager` 已加载的、覆盖**行程日期窗口**的日预报（按目的地，多目的地各算）。
提炼为离散信号（阈值为初稿，落地时按真机校准）：

| 信号 | 触发条件（行程窗口内） | 映射场景 / 物品 |
|---|---|---|
| `rain` | 任一天降水概率 ≥ 60% 或状况为雨 | `rainy_city`（伞 / 雨衣 / 防水鞋） |
| `snow` | 任一天为雪 | `winter`（雪靴 / 保暖 / 手套） |
| `heat` | 任一天高温 ≥ 32℃（设备单位换算） | `tropical` 相关（防晒 / 帽 / 墨镜 / 补水） |
| `cold` | 任一天低温 ≤ 5℃ | `winter`（保暖层 / 外套 / 围巾） |
| `bigSwing` | 窗口内高低温跨度 ≥ 12℃ | 提示「早晚温差大」→ 加一件外套 |

> 需要降水概率/低温/状况——`WeatherManager.DayWeatherInfo` 目前只带 `highTemp`，需扩展为带 `low / precipChance / condition`（WeatherKit 已有这些字段，只是没透出）。这是本功能的前置小改动。

### 2. 例外判定（关键：只提"该带却没带"的）

对每个信号，仅当**同时满足**才生成建议：
- 该信号映射的物品**当前不在**清单（去重）；且
- 该信号**不在用户已选/已被气候 nudge 覆盖的场景**内（预期之内不重复出声。例：用户已选 winter 或目的地本就 `ClimateInference`→winter，则 `cold/snow` 不再单独提）。

→ 真实天气的**独立价值**主要落在 `ClimateInference` 覆盖不到的：**rain（它根本不推）**、反季节的 heat/cold、临时极端。这正是该功能的差异点。

### 3. 呈现（贴着已有天气卡，不另起一块）

- **首选**：在 `DestinationInfoView` 的天气卡下方挂**可点行动 chip**：「3/15 有雨 · 加雨具」。天气信息 + 天气行动同处，最连贯；点击经 `TripStore` 把对应物品加入清单（命中既有"加物品"漏斗）。
- **次选**（天气卡太挤时）：复用 Surprise Item 的**可消除卡片**放 `PackingListView`，每行程可 dismiss（记到 `trip.dismissedSurpriseNames` 同类机制，避免重复打扰）。
- **多目的地**：按目的地分别判定与呈现（与天气卡 per-destination 一致）。

### 4. 文案规范（made with love）

- 必含「具体日期 + 城市 + 天气 + 可行动」。
- ✅「看了下你出发那几天 — 3/15 多伦多有雨，带把伞？」
- ❌「检测到降雨，建议添加雨伞。」
- 9 语言文化适配；中文全角标点；日期按 `Locale` 格式化（随设备语言）。

---

## 第二部分：天气预报 / 提醒 / 预警

### 1. 预报展示（已有 → 小增强）

`DestinationInfoView` 已展示 7 天高温。增强：把**降水/天气状况/低温**一并带出（同时喂第一部分的信号提炼）。署名（WeatherKit attribution）继续保留。

### 2. 天气提醒模块（新增，严格例外驱动）

挂进 Settings「行程提醒」作为新模块「天气提醒」，走现成范式：
- 在 `NotificationManager` 加 `collectWeatherAlerts(trip:weather:now:into:)`，产出 `Candidate`；纳入 `reschedule` 主循环与 64 预算；id 命名空间 `carry.trip.{id}.weather.{type}`（确定性）。
- `ReminderPreferences` 加开关（默认**开**，但只在例外触发→平时几乎不响）。
- **触发门槛高**，仅两类：
  1. **显著天气**：行程窗口内的暴雨 / 暴雪 / 高温 / 寒潮（阈值同上、从严）。
  2. **官方极端天气预警**：接 **WeatherKit Severe Weather Alerts**（台风/风暴等政府级预警）——这是"极端天气预警"的正解，免费且权威。
- **时机**：出发前 1–2 天一条，回扣打包：「出发前提醒：目的地这几天有暴雨，行李里有雨具吗？」
- **绝不做**：每日天气播报式推送（噪音，违背克制）。

### 3. 为什么不做"日常天气推送"

普通天气：DestinationInfo 看得到 + 第一部分的打包 nudge 已覆盖。再加日常推送只会变成噪音、拉低信任。推送这条高价值通道只留给「极端/可能打乱行程」的事。

---

## 约束（设计时必须绕开）

- **WeatherKit 免费档**：~10 天内、≤10 天行程、出发 >10 天暂不显 → 天气类能力天然只在临近期生效；远期由 `ClimateInference` 兜底（正好是粗→精分层，不是缺陷）。
- **署名**：WeatherKit attribution 必须展示（已处理，勿丢）。
- **无日期「规划中」行程**：无日期 → 跳过全部天气逻辑。
- **64 通知预算**：天气提醒是近期高价值事件、按 fireDate 排序天然靠前，且例外驱动量小，不挤占其它提醒。
- **时区**：预报按目的地当地日期对齐行程窗口；大陆目的地经 `TimeZoneCanonicalizer` 归一（与全 App 一致）。
- **坐标**：用 `TripBundle.latitude/longitude`（+ `additionalDestinations`）喂 WeatherKit；geocoding 未完成时无坐标 → 暂无天气（降级）。

## 本地化 / 埋点

- 所有文案进 `Localizable.xcstrings`，9 语言、中文全角、日期随 `Locale`。
- 埋点（闭环、同次接线）：`weatherNudgeShown` / `weatherNudgeAccepted`（采纳率，验证价值）、`weatherAlertScheduled` / `weatherAlertFired`；失败类入 `errorEvents`（如 `weatherFetchFailed` 若新增）。

## 测试 Checklist

- [ ] 雨：`ClimateInference` 不推、真实预报有雨 → 出现「加雨具」建议；已有伞则不出现。
- [ ] 预期之内不重复：去北海道冬季（已 winter）→ 不再单独提 cold/snow。
- [ ] 反季节：热带雨季的反常凉 / 温带的反常热 → 正确提示。
- [ ] 一点即加：建议点击后物品正确进清单、chip/卡消失、可 dismiss。
- [ ] 出发 >10 天 / 无日期 / 无网 / 无坐标 → 天气逻辑静默跳过，其它不受影响。
- [ ] 天气提醒：仅极端触发、出发前 1–2 天、文案回扣打包；普通天气不推送。
- [ ] WeatherKit Severe Alert → 正确生成预警通知。
- [ ] 多目的地各自判定。
- [ ] 64 预算下天气提醒与既有提醒共存、不挤掉近期项。

## 产品决策（PM/UX 已定 · ADA 标准）

1. **呈现 = 「天气贴士卡」，放打包页、紧贴 DestinationInfo 天气卡下方**（接在现有 `destinationInfoContent` 插槽内、DestinationInfoView 之后）。不塞进横滚天气卡的 chip——会挤、违背 ADA 呼吸感。卡复用 Surprise Item 的视觉语言（一致、用户已熟），但用**真实预报背书**（点名具体天气，体现"为你看过"）。天气卡保持纯信息、行动层独立成卡，职责清晰。
2. **阈值上线初值**：高温 32℃ / 低温 5℃ / 降水 60% / 温差 12℃。合理保守（防过敏感）；上线接真实预报后真机微调——唯一尾部调参，不阻塞建设。
3. **「天气提醒」默认开**（例外驱动、平时几乎不响）；顾虑通知许可则首单引导。
4. `ClimateInference` **始终作远期底、与真实天气分层共存**（不退场）：远期季节兜底、近期真实精修。
5. **加物品走 `addSurpriseItem` 漏斗**（自动落对类目 + 记 dismiss + Live Activity/通知刷新）；天气物品复用 `SceneItemMap` 场景库，note 用真实天气背书文案。
6. **两层去重**：`notableSceneKeys` 剔除"已选/气候已推断"场景；卡内再按"已在清单"过滤物品；两层都空 → 整卡不显。

## 关联

- 复用：[[scene-climate-nudge]]（场景 nudge 范式与气候推断）、[[destination-info]]（天气卡 / 电压 nudge 范式）、[[notification-center]]、[[notification-budget]]（提醒模块 + 64 预算）、[[notification-preferences]]。
- 物品来源：`SceneItemMap`（场景→物品库，weather 复用其 `rainy_city`/`winter`/`tropical`/`high_altitude`）。
- 数据层：`WeatherManager`(WeatherKit)、`ClimateInference`、`TripBundle`（坐标/日期/多目的地/isDateless）。
