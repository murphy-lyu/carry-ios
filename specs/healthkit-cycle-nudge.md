# HealthKit Cycle Nudge（经期预测轻推）

> **Status: Implemented** — 代码已落地并通过 simulator build，待真机验证经期预测与审核文案定稿

## 问题

「🌸 On / near period」场景 chip 当前已存在（`Scene.swift` 的 "About you" 分组），点选后推荐
`Feminine hygiene products` + `Painkillers`。但它完全依赖用户**主动想起来去点**。

真实痛点是：用户出发前往往**没意识到行程那几天正好赶上经期**——等到了目的地才发现没带卫生用品/止痛药。
手动 chip 解决不了"没想到"这件事，只有结合周期数据**预测行程与经期是否重叠**才有增量价值。

## 方案

复用 ScenePickerView 现有的 **nudge（轻推）机制**（与 `ClimateInference` 完全同构）：
读取 HealthKit 的 Cycle Tracking 数据，预测**出发日期 ~ 返程日期**这段区间是否与经期/经期附近重叠；
若重叠且用户尚未选择该场景，则把 `personal_period` chip 加入 `nudgeSceneKeys`，
在场景选择界面上方轻提示，用户点一下即加入。

**核心原则：HealthKit 只做"轻推"，不做强制、不替代手动选择。**
读不到数据、无权限、无周期记录 → 一律静默降级为现状（chip 仍在默认分组里可手动选）。

## 为什么只做经期，不做用药 / 性别

| 数据 | 决策 | 原因 |
|------|------|------|
| 经期（Cycle Tracking） | ✅ 做 | 唯一能产生"预测重叠"这种动态增量、手动替代不了的场景 |
| 用药（Medications） | ❌ 不做 | 物品库只有笼统的 `Daily medication`，拿到精确药名无处落地；维持手动 chip |
| 生理性别（biologicalSex） | ❌ 不做 | 唯一用途是"男性不推经期"，用 onboarding 让用户点一下「男/女」更轻、更准、无 `.notSet` 兜底与审核成本，且 100% 拿得到 |

接 HealthKit 的固定成本（权限弹窗掉授权率、健康数据最高敏感等级合规、App Store 审核用途说明）是一次性大头，
只有经期一个场景的收益盖得过它。把性别/用药塞进去只会摊薄收益、放大审核风险。

## 可用信号

| 信号 | 来源 | 说明 |
|------|------|------|
| 经期样本 | HealthKit `HKCategoryType(.menstrualFlow)` | 历史经期记录，用于推断周期长度与上次经期起始 |
| 出发 / 返程日期 | `TripBundle.departureDate` / `returnDate` | 行程区间，用于判断是否与预测经期重叠 |

> 不读 `biologicalSex`、不读 `medications`。授权请求里**只**申请 `.menstrualFlow` 的读权限，
> 用途说明聚焦"经期打包提醒"，审核理由自洽。

## 入口与开关（显性 opt-in）

经期预测以**设置内的显性开关**为总闸，默认关闭：

- 设置 → 通用 → **「经期提醒」**（`settings.cycle.entry`，仅 `CycleInference.isAvailable` 的设备显示）→ 进入 `CycleReminderSettingsView`
- 页面内「经期打包提醒」开关（`cycleNudgeFeatureEnabled`，`@AppStorage`，默认 `false`）
- 开启时 → 调 `CycleInference.requestAuthorization()` 触发系统 HealthKit 授权弹窗
- Apple 约束：自定义开关**不能**直接授予 HealthKit 权限，只能触发系统弹窗；读权限授予状态不可查询，故开关 ON 但用户实际拒权时，预测层静默降级（不回退开关、不报错）
- 关闭开关 → 完全不跑预测、不触碰 HealthKit

## 生效范围

总闸开启后，**所有创建/编辑入口都跑预测**（关键修正见下）：

| Mode | 是否启用预测 | 日期来源 |
|------|------|------|
| `.create(TripInfo)` | ✅ | `TripInfo.departureDate` / `returnDate` |
| `.autoPack(TripInfo, _)` | ✅ | 同上 |
| `.edit(tripId)` | ✅ | `TripBundle.departureDate` + `days` |
| `.suggest(tripId)` | ✅ | 同上 |

> **关键修正**：经期预测**只需日期**，不需要 `countryCode`。早期版本照抄 `ClimateInference`
> 把 `.create`/`.autoPack` 排除了——但 climate 排除它们是因为 `countryCode` 靠地理编码异步回填、
> 创建当下没有；cycle 没有这个依赖。把预测前移到新建流程才是正确时机（用户填完日期、
> 进场景选择即推荐），而非"打开已有行程后才推"的后置体验。日期区间由 `tripDateRange` 跨 mode 统一提取。

## 权限与降级（必须严格遵守）

HealthKit 授权状态对"读"是不可查询的（Apple 隐私设计：query 永远成功，无权限时返回空）。
因此**不依赖授权状态分支**，统一走"读到就用、读不到就静默降级"：

| 情况 | 行为 |
|------|------|
| 用户从未授权 / 拒绝授权 | query 返回空 → 不 nudge，无任何提示或报错 |
| 已授权但无经期记录 | 返回空 → 不 nudge |
| 设备不支持 HealthKit（如部分 iPad） | `HKHealthStore.isHealthDataAvailable() == false` → 整个能力短路，不申请权限 |
| 周期数据不足以预测（样本 < 2） | 不 nudge（不做不可靠的单点外推） |
| 预测经期与行程区间无重叠 | 不 nudge |

**何时申请权限**：不在 App 启动时申请。仅当进入 `.edit` / `.suggest` 的 ScenePicker、
且 `HKHealthStore.isHealthDataAvailable()` 为真时，首次惰性申请 `.menstrualFlow` 读权限。
请求一次即可，系统弹窗只弹一次；用户拒绝后不再重复弹（依赖系统行为，不自建状态）。

## 预测逻辑（CycleInference）

新增 `Carry/Models/CycleInference.swift`，与 `ClimateInference` 并列、同为纯推断层（但需异步读 HealthKit）。

1. 查询最近 ~6 个月的 `.menstrualFlow` 样本（按起始日聚合成"经期段"）。
2. 至少 2 段才继续；取相邻经期起始日之差的中位数作为**周期长度**（缺省回退 28 天，仅当样本≥2 时启用）。
3. 以最近一次经期起始日 + N×周期长度，外推到行程区间附近的预测经期窗口。
4. 预测窗口 = 预测起始日 ± 缓冲（默认经期持续按 5 天 + 前置缓冲 2 天，覆盖"on / near"语义）。
5. 若预测窗口与 `[departureDate, returnDate]` 有交集 → 返回需要 nudge 的 `personal_period`。

> 全部为**本地推断**，不上传任何数据。预测仅用于驱动一个 UI chip，不存储、不写回 HealthKit。

接口（异步，因 HealthKit query 异步）：

```swift
enum CycleInference {
    /// 行程区间是否预计与经期重叠。读不到/不足以预测时返回 false。
    static func tripOverlapsPredictedPeriod(start: Date, end: Date) async -> Bool
}
```

## ScenePickerView 接入

与 climate nudge 同一出口，合并到 `nudgeSceneKeys`：

- climate nudge 是同步计算属性；cycle 预测是异步，需用 `@State private var cycleNudge: Bool` + `.task`/`onAppear` 触发，
  读到结果后再并入 nudge 列表（避免阻塞首屏）。
- 合并后仍走现有过滤：已在 `selectedItems` 里的场景不重复 nudge。
- chip 复用 `SceneChip`，点击 → 加入 `selectedItems` → chip 消失，与 climate 行为一致。
- nudge section 标题、空则隐藏的逻辑沿用现有 `climateNudgeSection`（如标题需区分来源，见下）。

## UI 文案

- 经期 nudge 与 climate nudge 共用同一 section 时，标题沿用 `scenepicker.nudge.title`。
  若希望经期单独给一句更贴心的提示（如"看起来这趟可能赶上经期"），新增结构化 key
  `scenepicker.nudge.cycle.title`，并补全 9 种语言。**最终文案上线前与作者确认语气**（敏感话题，需克制、不冒犯）。
- 不新增面向用户的硬编码文案；所有提示走 `Localizable.xcstrings`。

## 工程接入清单

- [ ] Xcode 开启 **HealthKit** Capability（主 app target）
- [ ] `Info.plist` 增加 `NSHealthShareUsageDescription`（中英及其余语言通过 InfoPlist 本地化）——
      用途文案聚焦"读取经期记录，用于在行程可能赶上经期时提醒你打包相关物品"
- [ ] 不申请 `NSHealthUpdateUsageDescription`（本功能不写 HealthKit）
- [ ] `CycleInference.swift` 新增，封装所有 `HKHealthStore` 调用，HealthKit import 只此一处
- [ ] `ScenePickerView` 接入异步 nudge
- [ ] 埋点（闭环）：`CarryLogger.Event` 视情况新增
      `cycleNudgeShown` / `cycleNudgeAccepted`，并在同一改动里接上调用点；
      **不记录任何健康数据本身**，只记录"是否展示/是否被采纳"这类无关隐私的交互事件

## 隐私 / 合规

- 健康数据全程**仅在设备本地**用于一次性预测，不持久化、不上传、不进备份（`DataBackupManager` 不涉及）。
- 隐私政策需补一句：读取 HealthKit 经期数据的用途与"仅本地、不上传"承诺
  （中英 + PIPL 版 `carry-legal/privacy/zh.html` 同步，注意第 14 条 PIPL 声明不得删）。
- 大陆 storefront 无特殊差异化（经期推荐不涉及地缘政治）。

## 不在此版本范围内

- 用药、生理性别、过敏的 HealthKit 接入（见上"为什么只做经期"）
- 把预测结果写回 HealthKit 或做经期追踪功能（Carry 不做健康追踪，只做打包）
- 基于经期预测自动发系统通知（先只做 ScenePicker 内的 nudge；通知留待验证采纳率后再议）
- 周期不规律用户的高级模型（仅做中位数外推，样本不足即不预测）
