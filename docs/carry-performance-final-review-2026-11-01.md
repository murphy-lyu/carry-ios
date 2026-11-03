# Carry 性能最终检查（2026-11-01）

## 结论与证据范围

本轮修复了首页冷封面加载时可达的主线程读图路径。文件读取与像素解码已移到后台串行 actor；列表 body 只读已准备图片或内存缓存。封面菜单和分享海报中的同类同步入口也一并移除。没有改行程数据结构、账号流程或列表 identity。

这些是代码与模拟器功能证据，不能据此宣称同事的 iPhone 12 点击无响应反馈（TF-001）已复现或解决。目前没有该设备的卡顿轨迹、对应崩溃报告或可稳定复现的步骤。真实设备冷启动、滚动和封面替换的可视验收由主任务继续完成。

## 已确认并修复的调用链

`HomeView.tripRow → TripCard.featuredPhoto → BackgroundImageStore.image(named:)` 原先在 SwiftUI body 求值时执行 `UIImage(contentsOfFile:)`。暖缓存能避开一部分重复读取，但首次加载仍需同步读文件，UIImage 延迟解码还可能把像素准备推迟到首次绘制。

- `TripBackground.swift`：增加后台串行 ImageIO thumbnail 解码，使用既有 1400px 长边规格并烘焙方向；限定输入为普通非符号链接文件且不超过 50MiB。NSCache 记录像素成本，设置 32MiB / 32 项驱逐预算；这是缓存建议值，不是进程内存上限。
- `HomeView.swift`：body 仅读已准备状态或缓存。异步任务按文件名管理；取消/离屏释放视图持有的图片，更换或移除封面及时清除旧状态。冷读期间保留最终卡片几何与浅色文字对比，损坏/缺失图片回到原有普通卡面。
- `PackingListView.swift`：菜单根据封面元数据决定是否显示移除入口，不再为判断菜单解码整张图；缺失文件仍可移除残留封面记录。
- `TripSharePoster.swift` / `SharePreviewSheet.swift`：先异步准备封面，再传入 ImageRenderer，海报 body 不直接读文件；保留既有图片格式、裁剪、地图开关和分享行为。
- 删除、原名覆盖都会使正在进行的旧读取失效，防止旧像素迟到后重新进入缓存。缓存读取和异步完成时均重查账号文件访问；撤销访问后不可从暖缓存绕过授权。

有效改动集限定为这条冷读根因。首页现有包含打包计数的 `.id` 保持原样；移除它需要独立验证状态观察和重排序，没有把未经证实的改动混入本次修复。

## 自动验证

新增 `CarryAutomationTests/BackgroundImagePreparationTests.swift`，使用合成图片，不读取用户照片：

1. 冷 JPEG 按既有长边规格准备为正确尺寸，暖读取复用缓存。
2. 同名替换与删除失效旧像素。
3. 已取消、缺失、损坏和越界文件名不发布图片。
4. 冷读期间删除，完成后不能复活缓存。
5. 账号访问撤销后，暖缓存和异步读取都拒绝访问。

独立 DerivedData：`/tmp/CarryCoverPerformanceQA`。独立无界面模拟器：`Carry Cover Performance QA`（`AB1A743C-39A0-4CB0-9B01-05954720D3FC`，iOS 26.5，iPhone 12 屏幕配置）。该模拟器运行在 Mac 上，不能代表 iPhone 12 的 A14 性能。

首轮 5/5 通过，扩展至 BackgroundImagePreparationTests、BackupPerformanceTests、AccountFileAccessTests、BackupFileStageTests 共 23 项，前两轮均通过。自行 Review 随后补充更换/移除封面的旧状态释放；最终同源码 r3、r4 再次各 23/23 通过，编译 warning/error 为 0。结果分别为 `/tmp/CarryCoverPerformanceFinal-r3.xcresult`、`/tmp/CarryCoverPerformanceFinal-r4.xcresult`，完整日志为 `/tmp/carry-cover-performance-final-r3.log`、`/tmp/carry-cover-performance-final-r4.log`。23 项覆盖图像准备、备份性能与文件访问/暂存回归；没有用通过项数量替代真实交互验收。

构建均使用 `SWIFT_EMIT_LOC_STRINGS=NO`。首次新模拟器启动的 CoreData 默认目录缺失日志已自动恢复；未登录 iCloud 的运行时提示与编译告警、测试失败分别记录，不归为产品崩溃。

## 仍须分别保留的验收证据

- 原 Carry：多个真实封面的冷启动首页、快速滚动离屏再返回；封面替换、移除、缺失文件的正常卡面降级。
- 保持原裁剪与卡片比例，Light/Dark、大字号下无文字对比或布局跳动；分享预览有封面/无封面、包含/关闭地图均正确。
- 真正的 iPhone 12：带对应数据量的 Time Profiler / Hangs、滚动帧和内存轨迹；若复现无响应，再关联具体主线程栈。模拟器通过和其他型号真机通过均不能替代这项证据。

## 已发现、未在本轮改变的长图风险

现有产物路径：`PackingListView` 分享入口 → `SharePreviewSheet.render/rerenderPoster` → `TripShare.renderPoster` → `TripSharePoster.daysBody` 全部计划日 → `ImageRenderer.uiImage` → `TripShare.writeTempPoster` 的 `pngData()` → 临时目录 PNG URL → ShareLink。

`TripSharePoster.width` 为 390pt，renderer.scale 为 3；高度由全部行程内容决定，没有总像素/字节预算。整图渲染、PNG 编码与临时文件写入仍在主 actor 的当前调用路径内。行程足够长时，单张位图和编码中间内存会增长，并可能长时间占用主线程。像素存储粗略按宽×高×每像素字节增长，但本轮未采集真实峰值，不能给出测量结论或把它认定为 TF-001 根因。

更稳妥的后续修法是先定义完整保留行程的分页导出规格：按页预算渲染、分页预览和分享多图，或提供多页 PDF。每页应独立设置像素预算，编码/写盘可后台执行；仍需在主 actor 使用的 SwiftUI 渲染对象应保持其隔离。需要同时验证跨页标题、日期、地点、地图与分享接收端体验。禁止通过静默截断行程或仅限制最终图片高度掩盖问题。

本轮按主任务要求未改变单张 PNG 格式、分页方式或内容长度；此风险应留作明确后续项，不能计为已修复。
