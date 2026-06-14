# Carry Design System

## 设计原则
Apple 原生风格，极简、克制、优雅。
优先使用系统语义色（自动适配 Dark Mode），品牌色仅用于强调。
如果旧规范本身不适合现在这套产品气质，那就应该升级并重新统一，而不是继续照着旧的用。

## Color Tokens

### 语义色（优先使用）
- Background Primary：Color(.systemBackground)
- Background Secondary：Color(.secondarySystemBackground)
- Background Grouped：Color(.systemGroupedBackground)
- Surface Card：Color(.secondarySystemBackground)
- Label Primary：Color(.label)
- Label Secondary：Color(.secondaryLabel)
- Label Tertiary：Color(.tertiaryLabel)
- Separator：Color(.separator)
- Destructive：Color(.systemRed)

### 品牌色 / Accent（2026-06-07 定稿：单一「烟蓝」）
- **唯一强调色：烟蓝（Smoky Blue）** —— 定义在代码 `CarryAccent`（`AppearanceMode.swift`），明暗自适应：
  - Light：`#5B7A96`（sRGB r=0.357, g=0.478, b=0.588）
  - Dark：`#7A9CB8`（sRGB r=0.478, g=0.612, b=0.722）
- **两层注入,缺一不可**（见 `docs/decisions.md` 2026-06-07）：
  - SwiftUI 层：`ContentView` 根 `.tint(CarryAccent.color)` → FAB / 进度 / Toggle / 选中态 / 日期选择器等所有读 `Color.accentColor` 的元素。
  - UIKit 层：`CarryApp.init` 设 `UIWindow.appearance().tintColor = CarryAccent.uiColor` → 系统组件（`.confirmationDialog`/`.alert`/上下文菜单/导航栏按钮）——这些**不跟随** SwiftUI `.tint()`。
- **开关（Toggle）启用态**：继承全局 tint（烟蓝），不单独指定。
- **禁止**硬编码 `.tint(.blue)` / `systemBlue` / 其它强调色;新增彩色交互元素一律继承全局 tint 或显式用 `CarryAccent.color`。
- **无用户可见主题切换**;旧的 `ThemeAccent`(多色备选)/`toggleTint` 环境键已删除。
- 注：`Assets.xcassets/AccentColor.colorset`（旧「海湾青」）已被 `.tint()` 覆盖,不再是有效来源。

## 按钮颜色规范（三档 · 2026-06-13 定稿）

> **同一类按钮必须同色。** 按「这颗按钮在信息层级里是什么角色」选档，不靠手感随意上色。依据：north-star §1（chrome 退后）/ §4（彩色=意义）。来源：用户发现关闭 X 在不同界面出现蓝/黑/灰三色不一致，借此统一全 App 按钮配色。

**Tier 1 · 主操作 CTA（每屏 ≤ 1）** —— 实心 `Color(.label)`（黑/白自适应）+ `Color(.systemBackground)` 文字。
- 用于：空状态主行动（创建第一个行程 / 添加第一天）、底部 Save·确认·主 CTA。
- 为什么不用烟蓝：label-黑对比最强、最「压得住场」；把烟蓝让给彩色控件，避免主按钮与一堆彩色控件抢色。

**Tier 2 · 强调 / 可点的彩色** —— 烟蓝 `CarryAccent`。
- 用于：FAB、Toggle 开启态、选中 / 分段选中、进度填充、日期选择器、链接、「采用优化」类彩色动作。
- **工具栏的「提交 / 确认」动作**（Save · Done · ✓ · Add）= 烟蓝 + `.fontWeight(.semibold)`——它是该屏主操作、要跳出来；Apple 惯例即「工具栏主操作 = tint + bold」。实现：`Label(..., systemImage: "checkmark")` 继承 sheet/根的 `.tint(CarryAccent)`，不必显式设色。
- 依据：彩色 = 意义（可点 / 选中 / 强调）。

> **「选中 vs 完成」铁律：选中用强调色，完成则退后变灰，方向相反，别混。**
> - **选中（selection）** = 用户正在「挑」要包含什么（ItemPicker 勾选、场景、顺手考虑、分段切换）→ 前进/激活 → **烟蓝跳出来**。
> - **完成（completion）** = 这件已搞定（打包清单 `isPacked`）→ 应**退后**：灰圆（`systemGray2`）+ 文字置灰 + 删除线 + 降透明度，让注意力落到**还没完成的**项。
> - 反例（禁止）：把打包「已打包」勾改成烟蓝——会把视线吸到已完成项上，与「还差什么没打包」的目标相反。

**Tier 3 · Chrome / 工具图标（退后）** —— 中性 `.secondary` 灰 + 玻璃 / 材质圆底。
- 用于：设置齿轮、**关闭 X**、「…」更多菜单。这些是「离开 / 导航」，不提交，显式 `.secondary`。
- **返回 `<` 例外：用系统返回（NavigationStack 自带），不手动改色**——iOS 26 自动渲染成玻璃圆 chevron，顺平台纹理（north-star §9 native-first），别自造 chevron 按钮去硬调色。
- 依据：chrome 退后；与 Apple 原生一致（齿轮 / 关闭 / 更多从不染 app 强调色）。
- 实现：工具栏关闭用 `SheetCloseButton`（已显式 `.tint(Color(.secondaryLabel))` 盖掉 sheet 的 accent tint）；自定义头部关闭用 `glassCircleButton()` + xmark `.foregroundStyle(.secondary)`；更多菜单 `ellipsis` 显式 `.secondary`。

> **工具栏分色铁律：按「提交 vs 离开」分，不是「凡图标都灰」。**
> - 提交 / 确认（Save · Done · ✓ · Add）→ Tier 2 烟蓝 + semibold。
> - 离开 / 导航（关闭 X · 返回 · 更多）→ Tier 3 中性灰。
> 同一条工具栏上两者并存正常：右上 ✓ 蓝、左上返回灰。

**有意区分（非违规）**：「创建行程」在空状态是 Tier 1 黑（该屏主操作），在首页是 Tier 2 蓝 FAB（常驻悬浮、足迹地球上唯一一抹彩色）——语境不同、分属不同档，颜色不同是对的。

**禁止**：同类按钮混用多色（如关闭 X 一处蓝、一处黑、一处灰）；给工具 / chrome 图标染强调色。

### Tab Bar 背景（已实现）
- Dark：Color(red: 0.09, green: 0.09, blue: 0.10)
- Light：Color(UIColor.systemBackground)

## Typography（字体系统 · 2026-06-13 定稿：角色制双字形）

> **背景**：design-north-star §3 定「Carry 的声音 = SF Rounded」。但「同屏统一」**不等于**「全 app 一律圆体」——
> Apple 自家 Rounded 只给**数字 / 短而醒目的标签 / 展示型标题**（健身圆环、钱包、表盘），**密集正文一律用 SF**：
> 大面积圆体在小字号长列表下可读性下降、整体偏重偏童趣，反而偏离原生克制气质。
> 故 Carry 的「圆体声音」落地为一套**按角色分配**的字体系统，而非机械替换。这才是 §3「字形统一」的正确解：
> **统一 = 全 app 一致地遵守同一套角色规则**，不是同一种字形。

两种字形，按**角色**分配（不是按字号）：

### SF Rounded（展示声音）— `design: .rounded`
温暖、有旅行轻盈感，给"被展示、要醒目"的元素：
- **展示型标题**：hero 大标题、sheet 标题、空态标题、`alreadyOptimal` 等态标题
- **数字**：统计数字、序号（时间轴/地图针/列表序号）、距离、计数、价格、节省值
- **结构性短标题**：Day 头、分区标题（section title）、Trip Book 卡标题
- **短而突出的标签**：胶囊 / chip / badge / 浮层标签上的文字（地图 scope 胶囊、saved chip、底部胶囊切换）
- **紧贴展示标题的副标题**：hero 标题正下方那一行副标题（让整个"标题区块"是一个声音）

### SF（默认 / 功能声音）— 不写 `design:`，即系统默认
清晰、密集可读，给"功能性、信息密集"的元素：
- **密集列表正文**：打包物品名、搜索结果行、设置行、提醒列表项
- **表单与输入**：`TextField`、placeholder、`Form` 字段
- **长段落说明**：非紧贴 hero 的成段解释文字、footer 长文案
- **系统原生控件**：`Form` / `Picker` / `Toggle` / `DatePicker` / `navigationTitle` / toolbar / `Section` header·footer——本就该系统体（顺平台纹理，§9），**禁止**强制圆体

### 判定口诀
> **"被展示的、要醒目的、是数字/短标签的 → 圆体；信息密集的正文、表单、系统控件 → SF。"**
> 拿不准时**默认 SF**（保守）——错把正文做成圆体的代价（偏重/糊）大于漏掉一处该圆体的标题。

### 子规则：按钮（避免反复纠结）
- **主 CTA**（一屏/一个 sheet 的主操作，常为实心胶囊/填充按钮）→ **圆体**。例：优化页「采用」、打包「开始打包」、空状态主行动。
- **次级 / 工具性动作**（内联动作、流程推进、列表控件）→ **SF**。例：「Continue」「Select all」「重新选图」、行内「添加地点 / 优化顺序」。
- 同理：**字段标签**（与数据值配对、类表单 label，如日期卡的 Departure / Return）→ **SF**，与其下的数据值同声音、卡内自洽；圆体只留给真正的展示/数字时刻。

### 写法
- 圆体：`.font(.system(.headline, design: .rounded))` / `.font(.system(size: 30, weight: .bold, design: .rounded))`
- 带 weight/monospacedDigit：`.font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())`
- SF Symbol 的 `.font(...)` 只控符号大小、不涉及字形，不算字体系统范畴
- 项目惯例：各处内联写 `design: .rounded`，不另造 Font 封装（可读性优先、避免过度抽象）

### 字号语义级别（沿用，两种字形共用）
- .largeTitle：页面主标题 ｜ .title / .title2 / .title3：层级标题
- .headline：列表项标题、卡片标题（semibold）｜ .body：正文（17pt regular）
- .subheadline：辅助说明（15pt）｜ .footnote：时间戳、标注（13pt）｜ .caption / .caption2：最小标注

### 已对齐范围（2026-06-13）
行程规划三屏（ItineraryView / ItineraryMapView / OptimizeRouteView）整屏按系统对齐；
全 app 自定义界面按本系统走查对齐（详见 progress.md 当次记录）。系统 `Form` 设置页（Settings/About 等）保持 SF，无需改。

## Spacing
基础单位：8pt
常用值：4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48
页面水平边距：16pt（标准）/ 20pt（宽松）

## 圆角
- 大卡片 / 通用 Sheet：16pt
- 标准按钮 / 输入框容器：12pt
- Tag / Chip / 小元素：8pt
- 头像小尺寸：8pt，大尺寸：全圆（.clipShape(Circle())）

### 首页底部缩放 Sheet（CarryBottomSheetFX，独立规格）
首页主 Sheet 是自定义 UIKit 缩放 sheet，不走上面的通用 16pt；视觉对标 Flighty/Tripsy：
- 下拉收起时**整体等比缩小**（内容 + 内边距同步），两侧/底部边距随之拉开（收起态各 8pt）。
- 圆角上下异半径、随状态过渡：顶角 36pt；底角 展开 40 / 收起 56（`cornerCurve = .continuous`）。
- 展开贴屏时底角半径必须 **≤ 设备屏幕物理圆角**，靠屏幕硬件圆角过裁、与屏幕严丝合缝（大于会露月牙地图）。
- 这些是真机调定值，实现/调参锚点见 `CarryBottomSheetFX.swift` 常量 + `docs/home-sheet-debug-playbook.md`；改前必读 playbook。

### 首页行程卡 · 背景照片（feature/home-ui-redesign 分支，实验中）
> 样式尚未定稿（Dev Options 仍可切 1·Plain/2·Map/3·Thumb/4·Map，默认 2·Map）。定稿后转正为正式规范。
- **2·Map 照片卡**：沿用原始紧凑卡布局，有用户照片时照片**铺满整张卡**为背景。
  - 卡片用**固定宽高比 `K=4.0` 作最小高度**（内容更多则自然长高），该 K 与裁剪预览窗口共用同一常量（`BackgroundRepositionView.displayAspect`），保证"所见即所得"。
  - 蒙层：整体 `black 0.16` + 顶 `0.30→透明` + 底 `透明→0.58`（保证白字与顶部 chip 可读，中段最透显照片）。
  - 有图态：标题/城市/日期转**白字 + 轻阴影**，色条与进度填充转白，状态药丸转**深半透明底 + 白字**。无图态完全沿用原始卡(深色文字)。
- **背景图展示统一走 `PositionedImage`**：以用户所选裁剪框中心为焦点居中、按选区大小定缩放并钳制铺满——主体永不被切，不同尺寸/机型只多露周边（非破坏式，原图+归一化 `BackgroundCrop`）。
- 3·Thumb / 4·Map 的 56pt 小图同样走 `PositionedImage`；无图兜底分别为墨色字母块 / 实时地图（地图仅实验，见 decisions）。

## 阴影（仅 Light Mode 使用，Dark Mode 禁用阴影）
- 卡片：shadow(color: .black.opacity(0.06), radius: 8, y: 2)
- 浮层：shadow(color: .black.opacity(0.12), radius: 16, y: 4)

## 动画
- 标准弹簧：.spring(duration: 0.3, bounce: 0.2)
- 快速响应：.spring(duration: 0.2, bounce: 0.1)
- 页面转场：.easeInOut(duration: 0.25)
- 禁止使用 .animation(.default) 或无参数动画

## 组件规范

### 主按钮（Primary Button）
- 高度：50pt
- 圆角：12pt
- 背景：使用语义色，必须 100% 不透明；优先 `Color(.label)` 或 `Color(.primary)` 这类会随 Dark Mode 翻转的实心色
- 字体：.body .fontWeight(.semibold)，使用 `Color(.systemBackground)` 形成高对比
- 水平内边距：24pt
- 按压状态：只做轻微缩放，不使用 opacity 或 material 反馈
- 禁用状态：使用另一档实心语义色降一阶，Light Mode 选更可辨识的系统灰阶（例如 `Color(.systemGray3)` + `Color(.secondaryLabel)`），Dark Mode 选更稳的深色语义背景（例如 `Color(.secondarySystemBackground)` + `Color(.secondaryLabel)`），不得透底
- 组件实现建议：不要依赖 `.disabled(...)` 触发系统半透明效果；用明确的背景、前景和命中控制来表达可点/不可点

### 卡片（Card）
- 背景：Surface Card
- 圆角：16pt
- 内边距：16pt
- Light Mode 加阴影，Dark Mode 不加阴影

### 输入框（TextField）
- 背景：Background Secondary
- 圆角：10pt
- 内边距：水平 12pt，垂直 10pt
- 字体：.body

### 搜索框（Search Field · CarrySearchField）
全 App 搜索框统一走 `CarrySearchField`（`ViewModifiers.swift`），**单一形态**，禁止各页另起炉灶——历史上首页用过 24pt、其余 12pt，靠组件收成单一真源。
- **形状**：圆角 **12pt** `.continuous`、高度 **44pt**、水平内边距 12pt、字体 `.body`；放大镜 + 清除按钮（`xmark.circle.fill`，`common.clear` 无障碍）+ 清除动画 `.spring(0.2, 0.1)`。
- **表面（描边主导，唯一）**：`systemBackground.opacity(0.84)` + 细描边（`primary.opacity` Dark 0.12 / Light 0.08，线宽 1）。描边让它在**任何底色**上都立得住——灰底是白底+描边、白底是描边定界、暗色是深底+描边，因此不按上下文分多种填充。注意：纯实心填充（如 `secondarySystemBackground`）才会有「衬在同灰分组背景上整框隐形」的坑，描边主导式不受此影响。
- 尾部可选 slot（`trailing`）：放类别菜单等紧凑控件（见 AddStopView）。

### 创建/编辑行程输入容器统一（TripInfoView / EditTripView）
- 输入框与日期框采用“描边主导”视觉，不使用厚重实心填充块。
- 容器背景：`Color(.systemBackground).opacity(0.64~0.66)`。
- 描边：Dark `primary.opacity(0.11)`；Light `primary.opacity(0.07)`；线宽 1。
- 圆角：12；内容内边距：14（日期）/ 水平 12（文本输入）。
- 标签与辅助文案：使用 `.secondary.opacity(0.82~0.86)` 层级，与 `New trip` 保持一致。

### Sheet / Modal
- 优先用系统 .sheet()
- 内容顶部留 20pt padding
- 有标题栏时用 .navigationTitle + .navigationBarTitleDisplayMode(.inline)

#### Carry Modal Convention（呈现方式按「语义」选，2026-06-14）
一屏该用 push / sheet / cover，取决于**它和当前内容的关系**，而非"看起来顺手"：

1. **创建新对象、且完成后「进入/成为」它** → `fullScreenCover`（自包含任务 + 专注 + 落进新对象的动量）。当前仅**创建行程**（`router.beginCreation` → cover 内独立 `NavigationStack(creationPath)` 跑 TripInfo→ItemPicker→PackingList，`finishCreation` 关 cover 并把根 path 落到新行程）。
2. **对「当前对象」的自包含子任务（编辑/挑选/配置），完成后回到原处** → `.sheet`。绝大多数属此类：编辑行程、编辑/推荐场景、编辑分类·分区、行程提醒、上传背景图、**快速添加物品**、日期选择、My Item 添加。
3. **单字段输入/确认** → `alert`（如新建分区）。
4. **层级浏览（点进一个已存在的对象看详情）** → push。仅「行程列表 → 行程详情」「设置 → 设置子页（关于/图标/法务等）」。
5. **chrome 语义铁律**：
   - 模态（cover/sheet）离开 = **取消 / Done / Save / X**，**禁止用返回 chevron**当离开（chevron 只表达"层级内返回上一级"）。
   - cover/sheet 的**根步**无系统返回，必须自带「取消」（语义=放弃草稿，如创建流 TripInfoView、快速添加 ItemPicker merge 模式）；其内部 push 出的子步沿用系统返回 chevron（正确）。
   - 脏数据（已输入）时模态加 `interactiveDismissDisabled` + 放弃确认（按需）。
   - drag indicator：用**导航栏 Cancel/Done** 的 sheet 不显示抓手；用**自定义头部**（Roadmap/场景等）的显示抓手——两类各自自洽。
   - Mac Catalyst 例外：创建流仍走 push（`#if targetEnvironment(macCatalyst)`），`pushCreation`/`finishCreation` 在 `showCreation==false` 时自动退化为根 path 行为，一套代码两平台。

### 导航框架（2026-06-12，feature 分支：app-navigation-framework）
- **根级无 Tab Bar**：根=行程首页（足迹地球 + Sheet）。上文「Tab Bar 背景」token 现仅历史参考，根级已不再使用 TabView。
- **设置入口**：首页 hero 右上 gear（圆形，`secondary` 色）→ 以 sheet 打开（带「完成」关闭）；空状态另置一枚 gear（零行程也可达）。
- **创建 FAB**：右下悬浮，56pt 圆，`CarryAccent` 实心 + 白 `plus`，阴影 radius 10 / y 4，按压缩 0.92。
- **底部胶囊切换（行程 ｜ 打包）**：居中悬浮于安全区底部；`.regularMaterial` 胶囊 + `primary.opacity(0.06)` 描边 + 阴影；选中段 `CarryAccent` 实心胶囊 + 白字、未选 `.secondary`；切换用 `.spring(duration:0.3, bounce:0.2)` + light 触感。

### 行程规划组件（2026-06-12，feature 分支：itinerary-route-planning）

> ⚠️ **按天分色 = 单一强调色原则的唯一破例（2026-06-13 定，仅限行程规划）**：见 `decisions.md`。`ItineraryDayPalette`（`AppearanceMode.swift`）按 `ItineraryDay.sortOrder` 取色：7 色循环、明暗自适应、克制低饱和，**第 1 天＝烟蓝（CarryAccent）**，其余陶土/鼠尾草绿/梅紫/赭黄/暮蓝/玫灰。**只**用于行程的「数据节点」（地图针/路线、时间轴序号圆点/连线/类别图标、Day 头部色点）；行程内的**控件**（按钮 tint）仍用 `CarryAccent`。`ItineraryDayPalette` 禁止在行程规划之外引用。

- **时间轴行（TimelineStopRow）**：leading 24pt 序号圆点（`dayColor.opacity(0.15)` 底 + `dayColor` 数字）+ 上下 1.5pt 连线（`dayColor.opacity(0.25)`，首/末点对应半段隐藏）。**序号圆点垂直居中于整条内容**（上下两段对称连线撑出）——使相邻两圆点间连线对称，连接段（固定 `legGap`）里的**直线距离**标签（9pt secondary，systemBackground 垫底）落在两点正中。内容=类别 SF Symbol（`dayColor`）+ 名称 + 地址（caption secondary）；设了时间显示 `pin.fill`+时间，无坐标显示 `mappin.slash`（tertiary）。rail 以 `.overlay` 贴合内容高度（不反向撑高内容，避免自适应 cell 的幽灵高度）。水平内边距 16，行内分隔线隐藏（连线即分隔）。
- **Day 头部**：leading 8pt 当天色点（图例）+ 主行「Day N」或自定义标题；有日期行程次行「周几 月/日」（`Date.formatted` 本地化）；右侧 `ellipsis.circle`（secondary）菜单重命名/删除。吸顶（`systemBackground` 垫底，与 cv 背景一致）。
- **停靠点类别图标（StopCategory）**：sightseeing=camera · food=fork.knife · lodging=bed.double · transport=tram.fill · flight=airplane · activity=figure.walk · other=mappin。
- **停靠点行交互**：**点击整行不触发编辑**（避免误触）；编辑改由**向左滑动**出现的「✏️ 编辑」按钮触发（与「🗑 删除」并列，删除在最外侧）。长按仍为拖拽重排。
- **地图按天编号 + 按天分色**：地图针 label = **当天**序号（每天从 1 重置，与列表一致，非全程连号）+ 类别图标；针 tint 与路线 `MapPolyline` 按天取 `ItineraryDayPalette` 色。

### 创建流程视觉统一规范（2026-05）
- 适用范围：
- 一级页面：`New trip`（TripInfoView）、`Add item`（ItemPickerView）、`List preview / Packing list`（PackingListView）。
- 二级页面：`Choose scenes`（ScenePickerView）、`Suggested extra items`（SuggestionPreviewView）、`Select Dates`（TripDateRangePickerSheet）、`Reminder`（TripReminderSheet/ReminderPickerSheet）、`Edit trip`（EditTripView）、`Edit sections`（ReorderSectionsView）。

- 一级页面背景：
- 根背景统一使用 `Color(.systemBackground)`，必须实心不透明。
- 禁止使用 `CarrySubtleBackground()` 作为一级页面基底。

- 二级页面背景：
- 根背景统一使用 `CarrySubtleBackground()`。
- 二级页面内局部 surface（卡片、输入容器、提醒块）使用同色系实心层，不使用半透明雾化层：
- Dark：优先 `Color(.secondarySystemBackground)`。
- Light：优先 `Color(.systemBackground)`。

- 底部主按钮容器（`safeAreaInset(.bottom)`）：
- 一级、二级页面都必须实心不透明。
- 一级页面统一 `Color(.systemBackground)`。
- 二级页面使用弹层 chrome 同色系实心底（Dark：`Color(red: 0.08, green: 0.08, blue: 0.09)`；Light：`Color(.systemBackground)`）。
  - 在 `CarrySubtleBackground` 背景上的钉条优先用命名色 **`CarrySubtleBackground.baseColor`**（= 该背景渐变**底端**色、明暗自适应，封装上述 Dark 值）——与背景底端同色故无缝，避免散落硬编码 hex。
- 禁止透明、半透明或渐变透出列表内容（包括“按钮下方到屏幕底边”区域）。

- 主按钮统一（Primary CTA）：
- 背景必须实心不透明，禁用态同样实心（不可通过 opacity 降级）。
- 可用态：`Color(.label)` + 文本 `Color(.systemBackground)`。
- 禁用态：Dark 用 `Color(.secondarySystemBackground)`，Light 用 `Color(.systemGray3)`；文字 `Color(.secondaryLabel)`。
- 统一高度 50~52pt、圆角 14pt、描边 `separator` 低透明度。

- 吸顶分类标题（Section Header）：
- 使用实心遮挡层，颜色跟随当前页面基底（一级：`systemBackground`；二级：弹层 chrome 同色系）。
- 禁止 header 透明导致内容穿透。

- 间距与节奏：
- 首个分类与非首个分类吸顶间距必须一致。
- 顶部信息区到底部列表起点的空白保持同一节奏，不允许首段“额外大留白”。

- 禁止项：
- 禁止同一层级页面混用多套背景体系。
- 禁止“纹理背景 + 透明 header/footer + clear row”组合造成条带、透视或脏块。

## Icon 使用
- 全部使用 SF Symbols
- 尺寸与文字对齐时用 .imageScale(.medium)
- 独立展示图标用 font(.system(size: N)) 控制大小

## Mac Catalyst 专项规范

### 浮层卡片（NavigationStack 容器）
- 宽度：360pt（固定，`.frame(width: 360)`）
- 圆角：18pt，`.continuous` style
- 背景：Dark `Color(red: 0.09, green: 0.09, blue: 0.10)`；Light `Color(UIColor.systemBackground)`
- 阴影：Dark `shadow(color: .black.opacity(0.45), radius: 32, x: 0, y: 8)`；Light `shadow(color: .black.opacity(0.18), radius: 32, x: 0, y: 8)`
- 与窗口边缘的间距：leading 32pt、top 24pt、bottom 48pt

### 背景
- `MacGlobePanel().ignoresSafeArea()` 铺满整个窗口
- Tab Bar 在 Mac 上不显示；Settings 通过 toolbar 齿轮按钮打开 sheet

### List 内容区
- `HomeView.macBody` 使用 `.listStyle(.plain)` + `.scrollContentBackground(.hidden)` 实现透明背景
- List row 内容区背景用 `.listRowBackground(Color.clear)`，分隔线用 `.listRowSeparator(.hidden)`
