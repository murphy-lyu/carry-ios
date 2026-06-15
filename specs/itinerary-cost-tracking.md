# Itinerary Cost Tracking（费用记录 + 本位币 + Trip Book 花费沉淀）

> **Status: Implemented（2026-06-16，编译绿·待真机验收）。** Phase 1–5 全部落地：数据地基 / 本位币设置 / 三处录入 + 详情展示 / Trip Book 花费卡 + 明细 / 9 语言本地化。
> **遗留**：① 交通/住宿时间轴行的行内费用展示（仅地点详情已加，交通/住宿待补）；② `TripSpendStats`/`CostResolver` 单测（项目暂无 test scheme，待补）；③ 真机验收（录入→快照→Trip Book 折算、改本位币重算、备份还原带费用）。
>
> **本轮已拍板的产品决策（用户确认）：**
> 1. **每笔费用可单独带币种**（出国时航班记 CNY、酒店记 JPY 都真实），Trip Book 折算回本位币汇总。
> 2. **Trip Book 花费呈现 = 每趟总花费 + 分类目**（交通 / 住宿 / 地点三项）。
>
> **决策反转记录**：`trip-book.md` 与 `progress.md` 此前明确「My Trip Book **不做花费**」（理由：无数据 + 越界定位）。本需求推翻该结论——前提已变：本 spec 让费用成为用户**主动录入**的行程数据，「无数据」不再成立；记账是「数据沉淀 → 黏性」的核心一环，属正确演进。落地时同步更新 `trip-book.md` 的「不做」清单。

## 动机

出去玩（尤其出国）几乎都会关注「这趟花了多少」。把费用记录进 Carry 有三重价值：
1. **当下记账**：在已经存在的航班 / 住宿 / 地点上顺手记一笔，不用另开记账 App。
2. **分享参考**：和朋友聊旅行、分享行程时，费用是高频谈资（"机票多少""那家酒店几晚多少钱"）。
3. **数据沉淀 → 黏性**：花费数据随行程越积越厚，沉淀在 Carry 里成为用户的「旅行资产」，越用越离不开。

## 现状盘点（地基已就位）

- **`CurrencyCatalog.swift`**：静态「国家码 → 币种（ISO code + 符号）」映射，覆盖 ~110 目的地。已服务「目的地实用信息」屏。
- **`ExchangeRateManager.swift`**：`ObservableObject`，按天缓存汇率（`https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api`），`baseCurrencyCode` 目前 = `Locale.current.currency?.identifier ?? "USD"`。已服务目的地汇率展示。
- **行程三类实体均无费用字段**：`ItineraryStop` / `TransportSegment` / `LodgingStay`（`Carry/Models/Itinerary.swift`）。
- **`TripBookStats`**（纯函数 + 单测）：当前统计国家 / 大洲 / 国内外 / 季节，**显式不含花费**。

→ 费用功能不用重造币种 / 汇率轮子；主要工作是「加字段 + 录入 UI + 设置本位币 + Trip Book 汇总」。

## 核心设计原则

1. **真相是「金额 + 币种」，本位币等值是派生展示**：每笔费用永久存 `amount + currencyCode`（用户实际付的），不存「已折算成本位币的数」——因为本位币可改、汇率会变。Trip Book 里的本位币总额是**用当前汇率派生**出来的展示值。
2. **本位币 = 单一真源，统一到设置**：新增 `@AppStorage("preferred_currency_code")`，设备 locale 默认、可改。`ExchangeRateManager.baseCurrencyCode` **改为读它**（不再各自读 Locale）——目的地汇率与费用折算口径统一。
3. **币种名不进 xcstrings**：用 `Locale.current.localizedString(forCurrencyCode:)` 本地化币种名（CurrencyCatalog 注释已建议此法），避免手维护 9 语言 × 上百币种。只有结构化 UI 文案（"费用""货币""总花费"等）进 xcstrings。
4. **克制录入**：费用是**可选**字段，默认折叠 / 轻量，不在录入页喧宾夺主。一笔 = 一个金额 + 一个币种，**不做**单价 ×数量 / 多人分摊 / 明细拆分（越界、违克制）。
5. **汇总诚实**：多币种且某币种汇率不可得（离线 / 不支持）时，不静默漏算——明确标注或按币种分组展示，不假装精确。
6. **向后兼容、轻量迁移**：新增字段带默认值（加列属轻量迁移）；`DataBackupManager` 同步带上（发布前新增可选字段不升 backup 版本）。

## 数据模型

给三类实体各加三个字段（同构）：

```swift
// ItineraryStop / TransportSegment / LodgingStay 各加：
var costAmount: Double = 0          // 金额（用户实付，原币种）；与 costCurrencyCode 同空 = 未记录
var costCurrencyCode: String = ""   // ISO 4217，空 = 未记录（即「有无费用」的判据）
var costHomeAmount: Double = -1     // 录入时折算成本位币的快照；-1 = 未捕获 → 实时折算兜底
```

- **判据 `hasCost`（计算属性）= `!costCurrencyCode.isEmpty`**。用「币种非空」而非「金额 >0」判定，允许记录「0 元 / 免费」这类真实条目（如免费景点、朋友请客）。
- `costAmount` 用 `Double`：与项目现有数值字段一致，避免引入 `Decimal` 带来的 SwiftData / 备份序列化分歧；金额精度对「记录用途」足够。
- **🔴 存汇率快照（`costHomeAmount`）——我推翻了 spec 初稿的「不存快照」默认**。理由（按「根因 / 最佳设计」原则，非「够用即可」）：
  - 本功能你定位为「**旅行资产沉淀**」= 长期记忆。汇率非小幅噪声——近年 JPY 对 CNY 波动超 30%，纯实时折算会让「我 2024 年那趟日本花了多少」**算出明显错误的历史值**，违背记录的本意。
  - 真相永远是 `costAmount + costCurrencyCode`（用户实付，永不丢）；`costHomeAmount` 是录入当时按当时汇率折算的本位币快照，反映「当时大致花了多少本位币」，更贴近现实。
  - 复杂度有界（仅 1 列 + 录入时捕获 + 改本位币时重算），符合最小必要集。
  - **单一不变式**：`costHomeAmount` 永远以「**当前**本位币」计。维护方式见下。

### 本位币变更时的快照维护（单一不变式）

用户在设置里改本位币时，跑一次性重算：对每笔已有快照的费用，从**原始** `costAmount + costCurrencyCode` 按当前汇率重新折算成新本位币、覆盖 `costHomeAmount`；当前汇率取不到的（离线 / 不支持）→ 置回 `-1`，Trip Book 对这笔退回实时折算兜底。这样：① 始终保持「快照 = 当前本位币」的不变式；② 永不基于「快照折快照」（始终从原始金额折，无累计误差）；③ 原始事实从不丢失。改本位币是低频操作，重算成本可接受。

### 迁移

- 三处加列 = 轻量迁移，沿用单一 `SchemaV1`（参照 `itinerary-transport-lodging.md` 的加表迁移先例，加列更轻）。
- `DataBackupManager`：序列化 / 反序列化 / 复制行程 / 导入 全链路带上三个新字段（可选、向后兼容）。

## 本位币设置（设置一级页「货币」）

- **存储**：`@AppStorage("preferred_currency_code")`，默认 `Locale.current.currency?.identifier?.uppercased() ?? "USD"`。
- **入口**：`SettingsView` 新增「货币」行（`NavigationLink` 推入选择器，右侧显示当前币种 code + 符号）。位置建议靠近「外观」等通用偏好 Section。
- **选择器形态（已定：全屏可搜索 + 建议分区）**：候选上百币种，短弹窗放不下、找起来累 → 用**全屏可搜索列表**。但绝大多数人只在「自己国家 + 去过/要去的国家」这几个币种里选，所以列表顶部加一个**「建议」分区**：本位币（设备 locale）+ 用户所有行程目的地国家对应的币种（经 `CurrencyCatalog` 反查、去重），让高频选择一眼可达；下方「全部」按本地化名字母序铺全量。搜索框可按 code / 本地化名 / 国家过滤。每项显示「`Locale.localizedString(forCurrencyCode:)` 本地化名 + code + 符号」，选中项打勾（烟蓝，对齐选中态规范）。
  > 这是「当下我认为最好的形态」：复用 north-star「内容为王 + 减少选择成本」，把长列表的认知负担用「建议分区」收掉，而非简单堆一个百项列表。
- **联动**：`ExchangeRateManager` 初始化 / 重置 base 改为读 `preferred_currency_code`；用户改本位币 → 汇率重新 fetch、目的地实用信息屏与 Trip Book 折算同步刷新。

## 录入 UI

三处编辑页各加一个「费用」录入：金额输入框（数字键盘）+ 币种选择（默认本位币、可改为任意币种）。

- **`StopEditView`**（地点）：在「详情」段加费用行。
- **`TransportEditView`**（航班 / 火车 / 通用）：加费用行（如机票价）。
- **`LodgingEditView`**（住宿）：加费用行（如 N 晚总价）。
- **形态**：可选字段，留空 = 不记。金额数字用圆体（typography：数字 → rounded），币种符号 / code 紧随。空时显示轻量「添加费用」入口，不强占视觉。

## 展示

- **时间轴行 / 详情**：有费用的项在合适位置显示「符号 + 金额」（如 `¥1,280` / `JPY 50,000`），用 `costCurrencyCode` 自身的符号 + locale 数字格式（`NumberFormatter` currency 风格、用该币种）。**不在行内做折算**（行内显真实付款币种，折算只在 Trip Book 汇总层）。
- 字体 / 配色按 design-system：金额数字圆体；费用是次级信息，配色 secondary，不抢地点名。

## Trip Book 花费（参考 Tripsy「总花费」卡片）

Tripsy 截图的「总花费」卡片很对：大号总额 + 分类目逐行（图标 + 名称 + 右对齐金额）+ Show All Expenses。我据此定版式，但有两点按 Carry 自己的口径调整：

### 版式（已定）

Trip Book 是**全时段回顾**（与国家 / 大洲 / 季节卡同为聚合，截图里 Tripsy Book 那张「总花费」也是全部行程聚合）。所以「花费」卡片 = **全部已发生行程的聚合**：

- **卡头**：「总花费」+ 分享图标（沿用 Trip Book 卡片惯例）。
- **主数字**：本位币聚合总额（圆体大号、accent 色；多币种含近似时前缀「≈」）。
- **分类目三行**：图标 + 名称 + 右对齐金额：
  - ✈️ 交通（所有 `TransportSegment` 费用之和）
  - 🛏 住宿（所有 `LodgingStay`）
  - 📍 地点（所有 `ItineraryStop`）
  > 注：Tripsy 按「消费类别」（住宿/航班/汽车租赁/艺术与乐趣/其他）细分——那需要每笔打类别标签，越界，本轮不做。我们按**实体类型**（交通/住宿/地点）天然聚合，与你 Q2 选的「交通/住宿/地点」一致、且零额外录入成本。
- **底部**：「查看全部花费」入口（对标 Show All Expenses）→ 推入**按行程分组**的明细列表（每趟一个总额 + 可展开看该趟分类目）——**这里承接你 Q2 选的「每趟总花费」**：聚合卡给全局总览，明细页给每趟粒度，两层互补、不冲突。

### 口径

- **统计范围**：只算「已发生」行程（`countsAsVisited`，与 Trip Book 其它卡同口径，排除未来 / 无日期）。
- **折算**：优先用每笔 `costHomeAmount` 快照（稳定）；快照缺失（`-1`）的退回实时折算。
- **多币种诚实**：若有费用因汇率不可得无法计入近似总额，明确脚注「部分外币暂无汇率，未计入」，不静默漏算。
- **不做**跨趟「今年共花费 / 人均 / 每天」全局聚合（Q2 未选更大档）。

### 数据层

`TripSpendStats`（纯函数）：输入 trips + 汇率表（+ 各笔快照）→ 输出全局总额 + 三分类目 + 每趟明细；补单测（多币种折算、快照优先、汇率缺失降级三类用例）。

## 埋点

- `costAdded` / `costRemoved`（带 `category` = stop/transport/lodging）：衡量费用功能使用率。
- `preferredCurrencyChanged`：衡量本位币改动。
- 错误类（如折算因汇率缺失降级）按需，纳入 `errorEvents`（若新增错误 Event）。

## 本地化

- 结构化 key（待补全 9 语言、含显式 en）：`cost.field.label`（费用）、`cost.add`（添加费用）、`settings.currency.title`（货币）、`settings.currency.footer`、`tripbook.spend.title`（总花费）、`tripbook.spend.transport/lodging/places`、`tripbook.spend.approx_note`（部分外币未计入提示）等——最终清单实现时定。
- 中文全角标点；币种名走 `Locale` 不进 xcstrings。

## 明确不做（范围边界 · 克制）

- ❌ 单价 × 数量 / 人数 / 多人分摊（AA 制）——越界成记账 App。
- ❌ 跨趟「今年共花费 / 人均 / 每天」全局聚合（本轮档位未选）。
- ❌ 消费类别细分标签（餐饮 / 购物 / 门票等，Tripsy 式）——需每笔打标签，越界；按实体类型聚合已够。
- ❌ 预算 / 超支提醒——未来再议。
- ❌ 银行 / 账单导入。

## 实现阶段

1. **数据地基**：三实体加 3 字段 + 迁移 + `DataBackupManager` + 复制 / 导入链路。
2. **本位币设置**：`preferred_currency_code` + 设置页「货币」+ 全屏可搜索 + 建议分区的币种选择器 + `ExchangeRateManager` 接入 + 改币种重算快照。
3. **录入 UI**：三处编辑页费用行（金额 + 币种，默认本位币）+ 录入时捕获 `costHomeAmount` + 时间轴 / 详情展示原币种。
4. **Trip Book 花费**：`TripSpendStats` 纯函数 + 单测 + 「总花费」聚合卡片 + 「查看全部花费」每趟明细页；同步更新 `trip-book.md` 决策反转。
5. **埋点 + 本地化（9 语言）+ 编译验证**；交真机验收。

## 三个开放问题 — 已定（2026-06-15）

1. **汇率快照 vs 实时折算** → **存快照**（`costHomeAmount`），推翻初稿默认。理由见「数据模型」：长期记忆 + 高波动币种下，实时折算会给出错误历史值；真相 `amount+currency` 永不丢，快照随改本位币重算。
2. **设置「货币」选择器形态** → **全屏可搜索 + 顶部「建议」分区**（本位币 + 行程目的地币种），收掉百项列表的认知负担。
3. **Trip Book 花费卡片版式** → 参考 Tripsy「总花费」：**全局聚合卡（大号总额 + 交通/住宿/地点三分类目）+「查看全部花费」推入每趟明细**（聚合总览 + 每趟粒度两层互补）。
