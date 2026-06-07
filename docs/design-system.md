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

### Tab Bar 背景（已实现）
- Dark：Color(red: 0.09, green: 0.09, blue: 0.10)
- Light：Color(UIColor.systemBackground)

## Typography
使用 SF Pro（系统默认），通过 Font 语义级别调用：
- .largeTitle：页面主标题
- .title / .title2 / .title3：层级标题
- .headline：列表项标题、卡片标题（semibold）
- .body：正文（17pt regular）
- .subheadline：辅助说明（15pt）
- .footnote：时间戳、标注（13pt）
- .caption / .caption2：最小标注

自定义 weight 示例：.font(.headline).fontWeight(.semibold)

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
