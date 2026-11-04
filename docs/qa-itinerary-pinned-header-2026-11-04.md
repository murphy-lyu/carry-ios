# 行程日期吸顶修复与验收
## 范围
独立工作树 `Carry-header-occlusion`，分支 `codex/itinerary-header-occlusion`，基于手机原功能基线 `5fff33f`；已核对后续账户分支的日期头源码相同。未修改账户/AI、行程数据、日期与时区计算，未合并 main、安装手机或发布。
## 定位与实现
入口为 `PackingListView` → `ItineraryView.dayList` → `ItineraryReorderCollection` → supplementary provider → `dayHeaderRow/dayHeader`。
旧实现混用 plain-list 系统表头、`UIView.backgroundColor` 与 SwiftUI 内容内背景，hosting configuration 没有声明 enclosing-cell 背景；内容内 `zIndex` 也不管理 UIKit cell 之间的层级。本次将自绘日期头的布局、吸顶层级和背景配置收敛到列表容器。
- 保留原生 list 行、左滑与重排；关闭自动系统表头，使用独立 kind 的 boundary supplementary，原生 `pinToVisibleBounds` 与 layout zIndex 管理吸顶和遮挡。
- 首次配置与 `refreshVisibleHeaders` 共用 `configureHeader`，通过 `UIHostingConfiguration.background(systemBackground)` 统一提供背景，保留零 margins。日期内容只负责排版与自然高度。
- 注册、刷新、定位与末日补偿使用同一个 header kind；日期文本显式保留 VoiceOver 标题语义，尾部操作按钮独立可访问。
- 未加入滚动时改 alpha、反写 layout attributes 或固定高度补丁；没有 xcstrings 修改。
旧注释声称“提升到 decoration layer 后重置背景”，缺乏证据，已删除。本次确认了实现中的背景/层级归属问题，但原机 27.2 的灰色透叠未取得可靠的同机前后对照，不能宣称已经证明系统内部触发机制。
依据：[plain supplementary header](https://developer.apple.com/documentation/uikit/uicollectionlayoutlistconfiguration-swift.struct/headermode-swift.enum/supplementary)、[UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration)。
## 日期条定位补充修复
检查自定义表头的日期条入口时，目标 UUID 已更新，滚动却停在偏移 986pt、仍显示前一天；后续实测目标日期自然起点为约 1158pt。旧代码把屏幕外的估算行高当成最终坐标，“等待连续两帧稳定”的注释与实现也不一致。
改用 `scrollToItem` 让 UIKit 按目标首行定位，动画完成后使用实测首行位置及日期头高度对齐；用户抓住列表时取消待完成定位。没有固定延迟或重试循环。空白末日另有 8pt 补偿误差，现以实际 `contentSize` 计算滚动上限，并在目标行测量完成后更新补偿。
## 最终验证
前台 XCTest UI 工程直接编译最终 `ItineraryReorderCollection.swift`，与产品源码逐字比较一致。iOS 26.5 上 1 项测试循环覆盖明暗两色，35.517 秒通过：
- 真实慢拖、连续滑动和停稳后的日期吸顶。
- 滚动后刷新内容，再切换中文长日期及最大辅助功能字号；日期仍可访问和点击。
- 行背景设为亮红色，在日期文本下方、日期头底部留白处取样，每个 RGB 通道与实心黑/白误差不超过 2，遮挡断言通过。
- 切回常规字号后，原生左滑动作按钮可达。
截图已检查，常规字号没有航班文字透入日期头。大字号截图是合成压力用例，用于验证自然高度和遮挡，不作为产品排版样稿。
结果包：`/tmp/carry-header-gesture-qa/verified-foreground26.xcresult`。
证据目录：`/Users/murphy/.codex/visualizations/2026/11/03/01a1a1da-815f-7051-b210-e6ce13ebaa3f/header-occlusion/2026-11-04-final/verified/foreground26`，包含截图、日志、运行状态探针和完整手势工程源码。
既有 `ReorderLookupTests` 独立测试项通过，省略对象与重复 ID 的排序事务行为未变。日期条首日、跨日、空白末日及返回的定位断言在 26.5 诊断中通过；该诊断组另有窗口渲染失败，不将整组计为通过。
Release 通用 iOS 设备 arm64 构建成功（仅构建，关闭签名），编译 warning 为 0；日志：`/tmp/carry-header-qa/verified-release.log`。`git diff --check` 通过。
## 未计为通过的诊断与剩余边界
- 原生 XCTest 新窗口在跨日/字号切换、真实页面的组合序列中出现表头 alpha/呈现层异常，部分断言失败。替换 reusable view、关闭顶部边缘效果、关闭 UIKit 动画、跳过同结构 snapshot 动画均未消除；这些产品实验全部撤回。前台手势对照通过，不能用失败窗口推断“cell 当 header”或“topEdgeEffect”就是产品根因。该窗口诊断未作为稳定测试加入仓库，源码保存在 `/tmp/carry-header-qa/ItineraryHeaderRenderingTests.diagnostic.swift`。
- 本轮最终前台验收为 26.5；27.0 手势 runner 有系统 shell 故障，未完成，不计通过。模拟器曾记录渲染、iCloud 未登录和辅助服务日志，没有宣称运行时零告警。
- 手机为 iPhone 17 Pro / iOS 27.2；只读截图请求返回设备连接断言不可用。未覆盖手机安装，仍需后续集成后确认原始症状。
- 未修改父任务 progress 或账户验收文档；集成交接以本文为准。
