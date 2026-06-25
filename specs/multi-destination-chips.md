# Spec：多目的地输入（chip 标签 · 创建/编辑统一）

Status: Shipped（2026-06-25 实现，编译绿、i18n [E]=0，待真机验收）
Owner: —
Created: 2026-06-25

## 实现说明（2026-06-25）

- 新 `ResolvedDestination`（`TripInfo.swift`）= name + countryCode + lat/lon；`TripInfo` 用
  `resolvedDestinations: [ResolvedDestination]` 取代旧的单 `resolvedCountryCode/Lat/Lng`。
- 新共享组件 `DestinationChipsField`（`Carry/Views/`）：flow chips（复用 `ViewModifiers.FlowLayout`，
  新增 `stretchLastSubview` 让输入框填满行尾大命中区）+ 紧随输入框 + `StopSearchCompleter` 城市模式 +
  建议列表（兄弟视图，IME 安全）。选中→追加 chip、清空输入、保持聚焦；× 删除（删首项靠数组顺序晋升）；
  残留自由文本失焦/回车固化为「未解析 chip」。`text` 为父持有 binding → 组装 destinationCity 不依赖失焦时机。
- 创建页 `TripInfoView`、编辑页 `EditTripView` 均替换目的地字段为该组件；编辑页 onAppear 经
  `TripStore.resolvedDestinations(forTripId:)` 从 `destinationCity` 文本 + 已存码回填 chips。
- `createTrip`/`updateTripInfo` 经 `applyResolvedDestinations` 写首=主 + 其余=additionalDestinations；
  **全部已解析且无残留文本**才走结构化、跳过文本反查，否则回落 `updateCountryCode` 文本路径（全或无，避免半结构化半文本不一致）。
- 无新增 localization key（复用 `e.g. Florence` 占位 + `common.remove` 无障碍标签）。

关联：[[destination-country-resolve-at-input]]（resolve-at-input，已 Shipped）；本 spec 在其结构化选中基础上把「单目的地」扩成「多目的地」。

## 背景与根因

`TripBundle` 的目的地数据**早已支持多个**：
- `countryCode` / `latitude` / `longitude` = 主目的地；
- `additionalDestinations: [DestinationEntry]`（`{countryCode, latitude, longitude}` 的 JSON）= 第 2、3… 个目的地。
- 已贯通：地图点亮（`HomeView`）、Trip Book 统计（`TripBookStats+Trips`）、打包推荐
  （`generatePackingSections(destinationCodes:)`）、目的地信息（`DestinationInfoView`）、备份/还原、复制行程。
- `splitCities` 已支持 `& , / 、 ／ ＋ + 和 and` 等分隔符；`updateCountryCode(for:city:)` 把
  `destinationCity` 文本拆分逐 token 解析 → 填 `countryCode` + `additionalDestinations`。

**缺口在输入 UI，不在数据层（无 SwiftData migration）：**
1. **创建页 `TripInfoView`**：目的地搜索补全（`destinationCompleter`）选中一条后，
   `selectDestination` 把整段 `destinationCity` 文本**整体替换**成那一个解析名、且只暂存一个
   `resolvedPrimary`（`TripInfoView.swift` ~401）→ 选第二个城市直接覆盖第一个，无法累加。
2. **编辑页 `EditTripView`**：目的地是纯静态 `TextField`，**完全没有**搜索补全
   （仅靠保存时 `updateCountryCode` 的文本反查兜底）。

> 用户场景：一次旅行偶尔跨国（荷兰阿姆斯特丹 & 奥地利维也纳），更常见是一省内多城。需要能逐个**结构化**
> 选中累加，每个都拿到权威 ISO 码与坐标。

## 目标

把目的地输入从「单值文本 + 替换式 autocomplete」升级为**多目的地 chip 标签输入**，
**创建页与编辑页共用同一个组件**：
- 已选目的地渲染为可删除的胶囊 chip（带 `×`），自动换行（flow layout）；
- 输入框紧随最后一个 chip；打字即检索（复用现有 `StopSearchCompleter` 城市模式 + Worker）；
- 选中一条建议 → **追加**一个 chip + 清空输入框等下一个（不替换已选）；
- 第一个 chip = 主目的地（`countryCode`/`lat`/`lon`），其余 → `additionalDestinations`，顺序 = 添加顺序；
- 每个 chip 携带其结构化结果（`countryCode` + 坐标），不再依赖事后文本反查。

## 交互细节

- **添加**：输入框聚焦 → 建议列表（兄弟视图，IME 安全，沿用 resolve-at-input 已确立的预编辑态规则）→
  点一条 → resolve 拿权威码 → 追加 chip、清空输入框、保持聚焦继续输入下一个。
- **删除**：点 chip 上的 `×` 移除该目的地；删第一个时，原第二个**自动晋升为主目的地**。
- **自由文本兜底**：用户直接打字不走建议（或粘贴「阿姆斯特丹、维也纳」），失焦/保存时仍走
  `splitCities` + `updateCountryCode` 文本路径解析为多 chip（已有逻辑，保留为兜底，不回归）。
- **空态**：无 chip 时输入框显占位符（沿用现有 `e.g. Florence` 等 key）。
- **键盘/IME**：沿用 `TripInfoView` 已踩平的中文输入法选词不丢字方案（建议列表为兄弟视图、
  预编辑态不增删 TextField 视图树）。

## 数据映射

- 组件对外暴露一个**有序的结构化目的地数组** `[ResolvedDestination]`（name + countryCode + lat/lon）。
- `destinationCity` 文本 = 各 chip 显示名用主分隔符（`、` 或 ` & `，定一个）拼接，**保持人类可读 +
  与 `splitCities` 可逆**（仍是 Trip 卡片/通知/分享展示用的字符串真相）。
- 创建：`createTrip` 已接受 `resolvedCountryCode/Lat/Lng`（主）；扩成接受**整个数组**，
  直接写 `countryCode`(首) + `additionalDestinations`(其余)，跳过文本反查。
- 编辑：`updateTripInfo` 同样接受结构化数组，直接覆盖 `countryCode` + `additionalDestinations`；
  仅当用户改的是**纯文本**（无结构化选中）才回落 `cityChanged → updateCountryCode` 文本路径。
- **复制行程 / 备份还原 / 统计**：已读 `additionalDestinations`，零改动。

## 设计（ADA 视角）

- chip = 胶囊（`Capsule`），填充用语义 token、文字主色、`×` 次级色；点 `×` 命中区足够大。
- 自动换行用 SwiftUI flow（`Layout` 协议自定义 FlowLayout，或 iOS16+ 现成方案），不硬算偏移。
- chip 字体按双字形系统：城市名是「短突出标签」→ 可圆体；与表单其它 label 协调。
- 颜色全 token、暗色自适应；不为多目的地引入新强调色（守表单克制）。
- 单目的地（最常见）观感**不应比现在更重**：一个 chip + 输入框，视觉接近原单字段。

## 共享组件

- 新建 `DestinationChipsField`（或类似），输入：`@Binding [ResolvedDestination]` + 占位符 + focus 绑定；
  内部持有 `StopSearchCompleter`（城市模式）+ 建议列表 + flow chips。
- `TripInfoView`（创建）与 `EditTripView`（编辑）都替换各自的目的地 `fieldGroup` 为该组件 → 消除两页
  目的地输入的重复，且编辑页一并获得搜索能力。

## 非目标（本期不做）

- chip 拖拽重排（主目的地靠首位即可，后续需要再说）。
- 每个目的地单独挂日期/天数/住宿（那是「按段行程」的范畴，与本输入解耦；行程内时间轴已承担）。
- 重写 `splitCities` / 城市表（保留为自由文本兜底）。

## 验收

- 创建页：搜索选「阿姆斯特丹」→ chip①；再搜「维也纳」→ chip②（不覆盖）；建行程后地图点亮**荷兰+奥地利**、
  Trip Book 国家数 +2、打包按两国推荐。
- 编辑页：打开既有行程见目的地已渲染为 chips；可增/删；删主目的地后次目的地晋升、地图随之更新。
- 单目的地路径无回归；自由文本「A、B」兜底仍解析为两 chip。
- 中文输入法选词不丢字（创建 + 编辑都验）。
- 9 语言占位/文案齐、`i18n-audit` [E]=0；暗色自适应。
