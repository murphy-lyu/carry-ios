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

### 不同字号文字「读成同一行」用 `.center` 垂直居中（2026-06-16）
一对**字号不同、需读成同一行**的文字（如列表行「名称(body) ——— 时间(caption)」、「标题 — 值」），用 `HStack(alignment: .center)` 让两者**视觉中心**对齐。
- **不要用 `.firstTextBaseline`**：共享基线时，小字号文字的视觉中心会落在大字号中心**之下**，看着「偏下／没居中」。基线对齐只适合**同级排版的连续文字流**（如正文里夹注），不适合大小悬殊的「标签—值」对。
- 实例：`TimelineStopRow` 名称行（地点名 + 右对齐开始–结束时间）。

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
- **搜索态保留来源页大标题**（2026-06-14）：临时筛选式搜索（如首页「搜索行程」`HomeView.searchSheet`）不另起冗余标题——**让来源页的大标题延续进搜索态**（标题在上、搜索框在下，与首页 `home.title` 同 30pt rounded），顶部不空、有归属感、接近原生大标题搜索。禁止加与 placeholder 重复的标题（如标题又写「搜索行程」）。对比：独立任务模态（如「添加地点」）该有自己的 `navigationTitle`，二者语境不同。

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
- **整屏底色要一致时，铺一层统一背景，别让两块区域各自上色赌一致**（2026-06-14）：典型坑——`.insetGrouped` 的 `List` **在 sheet 里默认渲染白底**（`systemBackground`），若上方另有一块涂了 `systemGroupedBackground` 的条（如搜索 band），交界会出现割裂硬边。解＝`List` 加 `.scrollContentBackground(.hidden)` + `.background(Color(.systemGroupedBackground).ignoresSafeArea())`，让前景条只负责遮挡滚动内容、不依赖控件隐式底色对色（见 `AddStopView`）。

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
- **Day 头部**：leading 8pt 当天色点（图例）+ 主行「Day N」或自定义标题；有日期行程次行「周几 月/日」（`Date.formatted` 本地化）。吸顶（`pinToVisibleBounds`，`systemBackground` 垫底，与 cv 背景一致）。**尾部 tool accessory（2026-06-16）**：作用于「整天」的工具操作放 header 尾部（对齐 Apple section-header accessory），当前承载「Optimize order」（坐标点 ≥4 才显示、排序模式隐藏）。规范：① 中性 **secondary** 色 = 工具，不用 `CarryAccent`（强调色留给主 CTA / 选中态）；② 垂直内边距压到最小，使有/无 accessory 的天 header **等高**（§Spacing 节奏），点击区靠横向铺开补回（矮而宽，对齐「See All」式附属按钮）；③ 图标 `accessibilityHidden`、按钮带完整 a11y 标签。
- **停靠点类别图标（StopCategory）**：sightseeing=camera · food=fork.knife · lodging=bed.double · transport=tram.fill · flight=airplane · activity=figure.walk · other=mappin。
- **停靠点行交互**：**点击整行不触发编辑**（避免误触）；编辑改由**向左滑动**出现的「✏️ 编辑」按钮触发（与「🗑 删除」并列，删除在最外侧）。长按仍为拖拽重排。
- **地图按天编号 + 按天分色**：地图针 label = **当天**序号（每天从 1 重置，与列表一致，非全程连号）+ 类别图标；针 tint 与路线 `MapPolyline` 按天取 `ItineraryDayPalette` 色。

### 行程交通段 + 住宿 + 地图空态（2026-06-15，已上线 main · spec: itinerary-transport-lodging）

- **统一「+」入口**：每天底部 `addStopRow` 由单一 Button 改 **Menu**：地点（mappin）/ 航班（airplane）/ 火车（train.side.front.car）/ 住宿（bed.double）。次级动作仍 secondary 灰（不抢色）。
- **交通连接行（TransportTimelineRow）**：与 TimelineStopRow 同两列网格（rail 30 + spacing 12）。rail 列放 **mode 图标的当天色实心圆**（**28pt + 13pt 图标，与停靠点完全同款** `systemBackground` 垫底 + `dayColor.opacity(0.15)` 轻染 + 图标；尺寸统一，类型靠图标 plane/pin + 行内容区分）；详情列主行 = 班次（圆体 semibold「承运方 · 班次号」，皆空退化 mode 名）、次行 = 起讫站/时间（圆体 footnote secondary，如 `KMG 09:00 → PEK 12:30`，跨天加 `+N`）。点击整行编辑。
  > **2026-06-18 改**：原为「描边空心圆」（区分边/节点）。空心描边显悬空/像按钮、与停靠点不成一家 → 改实心，与停靠点统一为「实心彩圆」家族。于是时间轴 marker 收为**两档**：实心彩圆 = 离散事件（到达/停留的停靠点 + 交通），裸图标 = 跨度（住宿，最轻）。类型靠图标+颜色区分、不靠容器形状变花样。**地图端点**仍用「白底描边圆」（地图瓦片上需高对比、属另一语境，不并入）。
- **住宿常驻条（LodgingBannerRow）**：覆盖天顶部的轻量 `secondarySystemBackground` 圆角条。三态——**入住日**实心床 +「入住 · 名称」(+时间)；**退房日**「退房 · 名称」(+时间)；**过夜中间天**最淡（床轮廓 + 名称 + 晚数，`opacity 0.4` 退到背景）。点击编辑。
- **航班地图弧线 + 端点**：交通段起讫两端都有坐标时画**大圆弧虚线**（`MapPolyline contourStyle: .geodesic`，dash `[2,7]`，当天色）区别市内步行/驾车实线路程；两端各放轻量端点标记（白底圆 + 当天色描边 + mode 图标，18pt，比序号针轻——端点是「过路」非「停留」）。
- **🔴 地图预览「永不为空」（替代灰盒占位）**：四档——① 当天有地点→正常路线图；② 当天空、整趟别处有地点→整趟真地图、其它天针/线淡化（marker 0.4 / line 0.3）+「这天还没安排地点」material 胶囊；③ 整趟空、目的地已解析→居中目的地真地图（复用 `TripBundle` 坐标）+「添加第一个地点」邀请；④ 兜底（整趟空且目的地未知）→ 才用原灰渐变盒。仅 ①② 可点开全屏。理由见 north-star §1/§9（Apple Maps 地图永不是灰盒）。

### 交通段日期/时间「融合 chip」（2026-06-19 · spec: itinerary-flight-search-first）

- **范式**：交通段编辑表单（`TransportEditView`）每个起降段的日期/时间合成**一行两个 chip**——`📅 [日期 chip] [时间 chip]`（取代旧「day Picker 行 + 时间开关行」）。chip = 圆体短标签（subheadline rounded medium）+ `tertiarySystemFill` 胶囊底；**未设值显示占位文字（secondary 色）、已设显示值（primary）**。
- **日期 chip**：显示该段所在**行程天**（如「周一 7/20」/「Day 1」）；多天行程点它弹 `Menu` 换天，单天仅作信息展示（日期当前**锚定在天上**，「真正可选」是单独立项）。
- **时间 chip**：可选——点开**弹出滚轮选择器 sheet**（Done 设定、编辑既有时间时出现「清除时间」回未设）。
- **为什么不用「Toggle + 内联 DatePicker」**：iOS compact `.hourAndMinute` DatePicker 比 Toggle 高，条件性塞进开关行会**撑高行、开关一切就跳变**。融合 chip 无开关、选择器移弹出层、chip 普通行高 → 行高恒定、信息量也压缩。**通则**：表单里「可选的日期/时间」一律用 chip + 弹出选择器，不要 toggle + 内联高控件。
- **全行程表单统一（2026-06-19 续 4）**：抽出共享组件 `FormChip`（胶囊 chip）+ `ItineraryTimePickerSheet`（弹出滚轮 + 完成/清除）+ `itineraryTimeString`（`ItineraryFormControls.swift`）。**交通 / 地点 / 住宿三处编辑表单的时间一律用此 chip+弹出**：地点的「开始/结束」改成两个时间 chip（`时间 09:00 – 11:00`，原 Toggle+内联两 DatePicker 已废）；住宿「入住/退房时间」改成时间 chip（原 `timeRow` Toggle+内联已废）。弹出层都用 `.sheet(item:)` 挂在 Form 稳定祖先（勿挂列表行，否则随行回收被销毁）。日期/天的选择因结构不同（交通=天 chip、地点=锚定在天上无独立日期、住宿=入住天 Picker+晚数 Stepper）保留各自控件，不强行统一。
- **搜索优先交互（`FlightSearchSheet`）**：渐进式单框——输航班号→识别航司→竖排日期列表（本行程的天，**点日期即触发查询**，对齐 Flighty「选择动作即触发」、不预填、不加查询按钮）→结果确认卡→点卡进预填表单；底部常驻低权重「手动输入」兜底。**通则**：搜索/查询类交互优先「选择动作本身即触发」，别预填默认值再找触发点。

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

- **底部栏 / 浮动元素下的内容过渡**（2026-06-14 重写，超越原「一律实心、禁渐变」）：统一原则——**滚动内容在底部元素下永不硬切，而是柔和消隐**。按底部元素是「实心整宽栏」还是「浮动元素」分两套，**单一真源**在 `ViewModifiers.swift`：

  - **① `BottomBarScrim`** —— 用于**整宽实心底栏**（`safeAreaInset(.bottom)` 里的 Save/继续/采用等 CTA）。背景 = 顶部定高「透明→实心」渐变条 + 其下实心填满（`ignoresSafeArea(.bottom)` 延到屏幕底边）。内容在栏上沿淡出，**按钮坐实心、其下到屏幕底边不透出内容**。淡出到**该页背景色**（无缝）：一级 `systemBackground`；二级弹层 chrome 同色系（Dark `Color(red:0.08,green:0.08,blue:0.09)`/Light `systemBackground`）；`CarrySubtleBackground` 上用 `CarrySubtleBackground.baseColor`。**已落地**：SuggestionPreview、ScenePicker、TripInfo、TripDateRange、OptimizeRoute、新建预览 Save。

  - **② `bottomContentFade`** —— 用于**浮动元素**（玻璃胶囊栏 / 圆角浮卡，**不该被实心遮挡**），**叠在滚动内容上**（overlay）。在内容底部叠一段「透明→页面底色」渐变，内容向背景**消隐**、浮动元素**仍浮于其上、保通透**（**不**在其后垫整块实心）。**已落地**：首页底部 glass 胶囊栏、ItemPicker 智能预览圆角条。

  - **③ `bottomBarFade`（2026-06-19 新增）** —— ②的「背景版」，用于浮动栏**坐在 `safeAreaInset(.bottom)` 里**的场景（如行程/打包切换器）。结构同 `BottomBarScrim`（`.padding(.top, fadeHeight)` + 背景 `ignoresSafeArea(.bottom)`），但填充由「实心」换成「透明→底端半透（`peakOpacity` 0.92）」的**通透**渐变——内容在栏后柔和消隐却**仍透出**，不被整块实心压短可视区。**配合磨砂胶囊**：浮动胶囊背景用 `.regularMaterial`（半透同时**模糊**背后内容，糊成柔光、不透出清晰字 → 「通透却不脏」，对齐 iOS 原生悬浮栏），单靠 `Color.opacity` 平涂只调暗不模糊、会让清晰文字穿透显脏。**已落地**：行程/打包切换器。

  - **⚠️ 目标色判据（2026-06-19 踩坑）：淡出/垫底色必须 == 该页底部「最上层不透明层」实际渲染色，不是页面根色。** 容易判反：行程详情根是 `CarrySubtleBackground`(暗底端 0.08)，但两个 tab 的内容层（ItineraryView / packingContent）都铺 `systemBackground`(纯黑) + `.ignoresSafeArea(.bottom)` **盖住了根** → 底部真实是纯黑；按"根"判而用 0.08 baseColor，就在纯黑上显**比背景亮的灰雾**（仅 Dark 可见，浅色 0.98 vs 1.0 近乎无差）。现已两面统一淡出 `systemBackground`。排查同类问题用**实测/截图看真实底色**，别静态读"根背景"。另：UIKit `CAGradientLayer.colors` 的 CGColor 不随 light/dark trait 自适应（`FXBottomFadeView` 深色停白），须 `registerForTraitChanges` 重设；SwiftUI `Color(动态UIColor)` 则自适应。

  - **选型**：① 不透明整宽 CTA 底栏 → `BottomBarScrim`（实底背书主操作）；② 浮动控件**叠在滚动内容上** → `bottomContentFade`（overlay 版）；③ 浮动控件**坐在 `safeAreaInset` 里** → `bottomBarFade`（背景版，通透）。垫实心会杀掉玻璃通透 → 浮动控件一律走 ②/③。

  - **性能**：①②③ 的渐变都是纯 `LinearGradient` + `allowsHitTesting(false)`——**不用 `.mask`/`.blur`**，故不触发离屏渲染、不挡点击、开销极低。**例外**：浮动胶囊**本体**的 `.regularMaterial` 磨砂是有意为之（模糊背后内容、防穿透显脏），仅用在小面积的胶囊上、不铺整条底栏（别把整条 fade 退回 material）。

  - 为何改「禁渐变」：原规则针对 `.regularMaterial` 在深背景上成**色带**——根因是「材质」非「渐变」。淡出到页面色的渐变无色带、且让内容优雅消隐（north-star §3），更近 Apple 浮动栏。仍**禁止**：材质/雾化层；`BottomBarScrim` 的实心区透出列表内容。

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

## 费用 / 货币（2026-06-16，spec: itinerary-cost-tracking.md）

### Trip Book「总花费」卡（数据可视化的克制范式）
对标 Tripsy「总花费」卡做了 Carry 化（north-star §1/§2/§4）：
- **比例带 = 把「一列数字」变成「一眼看懂的构成」**：总额下方一条 8pt capsule，按交通/住宿/地点占比分段。这是内容（这屏要回答「钱花哪了」）、不是装饰；对标 Apple Health / Screen Time。
- **单一色相三档深浅**：比例带与图例点用烟蓝 `CarryAccent` 的 100% / 55% / 28% 透明度编码三类目——守「彩色=意义、不堆色」的单一强调色纪律，深浅本身编码大小。**禁止**给类目分配不同色相。
- **无分隔线**：图例行靠圆点 + 间距 + 右对齐金额成行，不画满宽线（Tripsy 的 chrome 堆叠 = 噪音）。
- **诚实**：多币种折算总额前缀「≈」；汇率不可得的外币不静默漏算，脚注明确标注。
- 金额数字一律圆体（typography：数字 → rounded）；金额为次级信息，配色 secondary，不抢主数字。

### 货币选择器（长列表的认知负担收敛）
- 百项币种 → **全屏可搜索 + 顶部「建议」分区**（本位币 + 行程目的地币种），高频选择一眼可达，而非裸堆全量列表。
- 选中态打勾用烟蓝（对齐「选中=烟蓝」）。币种名走 `Locale.localizedString(forCurrencyCode:)`，不进 xcstrings。
- 一个组件两用：本位币模式（写设置 + 重算快照）与每笔费用的选择模式（回传 code、无副作用）。

## 行程规划：空态 / 对齐 / 菜单 / 日历叠加（2026-06-16 晚）

### dateless（PLANNING）行程
- **单天标题用「想去的地点」**，不用「Day 1」——dateless 永远只 1 天、本质是愿望清单，「Day N」暗示了不存在的多天日程。有日期行程仍显示真实日期。
- **整趟空 → 空态引导**（复用 app 空态范式：图标 → 圆体标题「想去哪些地方?」→ 副标题 → 「添加地点」CTA），替代孤零零的「Day 1 + 添加」。同时**抑制地图自带的「添加第一个地点」邀请**（`ItineraryMapView(suppressEmptyInvite:)`），避免双 CTA。

### 时间轴行对齐：用颜色/字重区分层级，不用盒子
- **同类前导图标须落在同一条 rail 竖线**（north-star §5）。住宿条曾用灰底 pill，其内边距把图标/文字顶离网格 → 去盒子：图标落 rail 列、文字落内容列、与停靠点同列。
- 住宿床图标**染当天色**（接 `ItineraryDayPalette`），与停靠点/交通的**实心彩圆**成「两档」（2026-06-18 由三档收敛，见 §交通连接行）：**实心彩圆 = 离散事件**（停靠点 + 交通，统一 28pt）、**裸图标 = 跨度**（住宿，最轻）。**原则：层级靠字重/配色/marker 形态区分，不靠会破坏对齐的盒子**（借 Tripsy「用颜色」而非「用盒子」）。

### 日历事件叠加行
- 视觉与行程数据**明确区分**：左侧一道该事件所属**日历色竖条** + 标题 + 时间/All-day，整体更轻（recessive）、**不挂 rail 圆 marker**（它来自「你的日历」，非「你规划的行程」）。点击弹 Carry 内只读浮层 `CalendarEventDetailView`，**不跳系统日历**（除导航必需外尽量不跳出 app）。

### 「…」菜单顺序：本面专属操作置顶
- 行程详情两面的「…」菜单，**本面专属操作置顶 → 再放行程级通用操作（编辑行程/提醒/背景）→ 分享/导出 → 删除**。打包面如此（加物品/标记/编辑分区在前）；行程面同构（「地点排序」置顶，≥2 地点时）。

### 活动详情卡：字段排序框架（2026-06-19 定稿）
点开行程里任一活动（交通 / 地点 / 住宿）弹出的详情浮层，字段排序**不按数据模型字段顺序裸排**，统一按「打开这张卡时旅行者最先要看什么」分五档，所有类型一致：

1. **行程骨架（何时·何地）** — 这条安排是什么：交通的出发/到达；地点的时间；住宿的入住/退房/晚数。
2. **随身要用的（定位 / 凭据）** — 现场要找的地址、要出示的座位与确认号。同档内**定位（地址）在前、凭据（座位/确认号）在后**（先找到地方，再出示）。
3. **描述性规格** — 刻画活动本身、"了解一下"性质（时长 / 机型 / 距离）；按有用程度排，距离最次要。
4. **费用** — 财务信息，规划/记账时看，**现场执行时不是首要 → 压在体验性信息之后**。
5. **备注** — 自由补充。
6. **附件**（文件/照片/链接）— 随身材料，最末。

**费用 / 备注 / 附件 = 三个通用项，各自独立成卡（详情）/ 独立 Section（编辑），固定顺序 费用 → 备注 → 附件，不与类型字段混排。** 信息卡只保留「骨架 + 定位/凭据 + 描述规格」。

落地顺序（详情 `body` 卡序；"有值才显"）：
- **交通**（`TransportDetailView`）：**航线 hero 卡**（出发/到达单拎一卡）→ 导航卡（仅租车聚焦）→ 信息卡（座位 → 确认号 →〔租车：车型 → 车牌 → 电话〕→ 时长 → 机型 → 距离）→ **费用卡 → 备注卡 → 附件卡**
- **地点**（`StopDetailView`）：信息卡（时间 → 地址 → 电话）→ 导航卡 → **费用卡 → 备注卡 → 附件卡**
- **住宿**（`LodgingDetailView`）：信息卡（入住 → 退房 → 晚数 → 地址 → 电话 → 确认号）→ 导航卡 → **费用卡 → 备注卡 → 附件卡**
- 电话用 `CallableDetailRow`（点按 `tel:` 拨号）；费用/备注各为单行独立 `DetailRowGroup` 卡。

#### 交通：航线 hero 卡（2026-06-19）
出发/到达是交通段最特别、最有仪式感的信息 → **单拎一张卡**置于头部之下、其余信息卡之上（学 Tripsy 的"登机牌"块），不与座位/费用等平铺混在一张卡里。

- 一条**竖直 rail** 把出发/到达两端 marker 串成「一段旅程」；rail 线与 marker 用**当天色**（`dayColor`），呼应时间轴。marker 圆用不透明 `secondarySystemBackground` 垫底，遮住穿过圆心的连接线。
- **marker 图标随 mode 取最贴切形式**（`markerSymbol`）：飞机/火车/巴士/渡轮 = 通用直达箭头 `↗`/`↘`（点对点位移，飞机正好读成起飞/降落）；**租车 = 钥匙 `key.fill`**（取车/还车是「拿/还车」而非位移，两端常同一地点，箭头会误导——学 Tripsy）。新增交通 mode 时按「是否点对点位移」归类选图标。
- 每端：左侧**机场码放大**为主角（`.title3` rounded semibold，无码退化用站名）、站名+航站楼为次行（footnote secondary）；右侧**时间放大**（同级），与机场码基线对齐成一行。跨天时间加 `+N`。
- rail 用 `Grid` + `GridRow` 实现（`verticalSpacing: 0`，两行 rail 半截线在行边界续上）；只有一个端点时不画线。
- 租车沿用 `pickup`/`dropoff` 标签（marker 的 a11y label），视觉箭头不变。

> 新增任何"可记费用 / 带凭据 / 带规格"的活动字段时，按本框架定档插入，别追加到列表末尾。

### Trip Book 卡片顺序
- 花费卡置于所有「出行习惯/统计」卡（国家/大洲/国际国内/季节）**之后、最末压轴**——花费是记账类数据、性质不同于习惯统计。
