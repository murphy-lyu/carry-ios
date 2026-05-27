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

### 品牌色 / Accent
- Accent（全局 tint）：.primary（ContentView 中已设置 .tint(.primary)）
- 如需彩色强调，优先从 Assets.xcassets/AccentColor 扩展

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
- 大卡片 / Sheet：16pt
- 标准按钮 / 输入框容器：12pt
- Tag / Chip / 小元素：8pt
- 头像小尺寸：8pt，大尺寸：全圆（.clipShape(Circle())）

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

### Sheet / Modal
- 优先用系统 .sheet()
- 内容顶部留 20pt padding
- 有标题栏时用 .navigationTitle + .navigationBarTitleDisplayMode(.inline)

### 背景与底部主按钮容器一致性（2026-05 更新）
- 页面背景分层：
- 一级页面（如清单预览）：使用 `Color(.systemBackground)` 实心基底。
- 弹层页面（如 `Choose scenes`、`Suggested extra items`）：统一使用 `CarrySubtleBackground()` 作为页面基底。
- 同一层级页面不得出现多套不同底色体系。
- 底部主按钮容器（`safeAreaInset(.bottom)`）：
- 必须使用实心不透明背景，不使用透明/半透明渐变透出列表内容。
- 背景色需与当前页面基底同色系（一级页跟随 `systemBackground`，弹层页使用统一的深色实心 chrome）。
- 分类标题吸顶（Section Header）：
- 使用实心遮挡层（`background` 为不透明色），避免内容穿透。
- 该遮挡层颜色需与当前页面基底一致，不可用纹理背景直接贴在 header 上，避免条带感。

### 分层背景规范（Light / Dark）
- 一级创建流程页面（`New trip` / `Add item` / `List preview`）：
- 背景统一使用 `CarrySubtleBackground()`（Light 与 Dark 都走同一套语义背景组件）。
- 吸顶分类标题背景统一使用 `Color(.systemBackground)` 实心遮挡层。
- 二级弹层页面（`Choose scenes` / `Suggested extra items`）：
- 背景统一使用 `CarrySubtleBackground()`。
- 分类标题背景使用“弹层 chrome 实心底色”（Dark: `Color(red: 0.08, green: 0.08, blue: 0.09)`，Light: `Color(.systemBackground)`）。
- 底部主按钮容器：
- 一级页面：`Color(.systemBackground)` 实心不透明。
- 二级弹层：与弹层 chrome 同色系实心不透明（Dark 同上，Light `Color(.systemBackground)`）。
- 禁止项：
- 禁止同一界面内混用“纹理背景 + 透明 header/footer”导致穿透或条带。
- 禁止一级流程页面中出现与同流程其它页面不同的基底组件。

## Icon 使用
- 全部使用 SF Symbols
- 尺寸与文字对齐时用 .imageScale(.medium)
- 独立展示图标用 font(.system(size: N)) 控制大小
