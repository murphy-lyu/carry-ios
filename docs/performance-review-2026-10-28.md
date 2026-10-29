# 性能代码复核 · 2026-10-28

## 范围与结论
针对 TF-001（iPhone 12 / iOS 17.1.1 / 1.0 build 2 的偶发点击无响应）检查实际可达代码。已修复打包保存、自动备份、备份信息读取、图片列表及账户 HTTP 接收的确定性额外工作。尚无该用户的具体操作步骤/符号化报告，也没有 A14 真机帧率、峰值内存或主线程采样，不能把这些修复称为 TF-001 已定位或已解决。

## 发现、修复与 Review
| 路径 | 代码证据与处理 | 验证 |
| --- | --- | --- |
| 打包勾选/全部完成/全部取消 | 原 `save → fetchTrips` 每次重新查询全部行程及物品库，并同步启动全库备份。保持 SwiftData 立即保存；仅标记变化的入口不重取集合，通知观察者并调度备份。集合成员/顺序变化继续原刷新路径 | 独立 ModelContext 验证保存立即可见、持有同一观察对象；打包计数覆盖空名字及 nil 关系 |
| 进度计数 | `safeSections.flatMap.filter` 为与顺序无关的计数反复排序和分配数组；改为原关系上的 reduce，不增加易失效的计数缓存 | 排序无关、标记/名字变化实时计数 |
| 自动备份 | `backup` 的 JSON/base64 编码原来仍在主 actor；含照片/附件缩略图，不能据旧注释假定数据很小。改为 250ms 合并、连续编辑最多一秒后采样；Sendable 镜像在 utility 串行 worker 编码/写盘，只保留当前及最新待写快照 | 100 次调度只读一次模型、后台编码、旧写入不覆盖新值、缩略图往返完整 |
| 备份抹除 | 自检发现同步等待后台编码会引入 QoS 优先级倒置。改为 generation 失效 + 同目录 staging + 短锁最终原子 rename；抹除不等待大编码/写盘，晚完成不能重建备份。实际抹除错误向调用者传播 | 人工阻塞编码时抹除仍可返回；排队/在途写均不能复活文件；中断进程遗留 staging 被清理 |
| 备份信息 | 设置/恢复页在主 actor 读完整 JSON；恢复页还解码两次。改为后台一次只解码日期/行程 ID 的 metadata，页面有本地化检查状态并取消过期结果 | 含实际缩略图字节的合成备份信息读取；九语言审计 |
| 图片列表 | `UIImage(data:)` 在 body 里创建惰性解码图；详情 HStack 提前处理所有照片。四处入口共用 `PreparedThumbnail`，utility ImageIO 目标像素解码，任务随字节/显示密度变化而取消，详情改 LazyHStack | 合成 JPEG 的像素/比例、损坏输入；Review 修正 square fill 短边像素不足，按短边计算并限制异常宽高比的分配 |
| 账户 HTTP | 原先接收完整响应后才检查 16MiB。改为后台流式累积、声明长度提前拒绝、无长度流超限即取消。Review 追工厂发现 AccountService 注入 sender 绕过默认实现；已把默认 sender 同样接到流式接收器 | 真实 URLSession → AccountService.graphTransport → 本地 HTTP；声明/分块两种 64MiB 响应均在完整下载前取消 |

备份 DTO 仍需在所属 actor 读取 SwiftData；这里只合并重复采样，没有用不可靠的逐行程缓存跳过 CloudKit 远程更新。入后台 flush 是尽力补齐自动 JSON 备份，SwiftData 保存仍立即执行，不声称强制结束进程前 JSON 一定写完。自动备份不携带沙盒原文件，与既有语义一致；便携导出仍携带原文件。

## 失败记录
- 初版 worker 抹除同步等待引出优先级倒置，已结构性修复并复跑；未压制诊断。
- `/tmp/CarryAccountBoundedHTTPBaseline.xcresult` 使用旧 QA 服务进程，响应夹具 404；重启本任务的 loopback 服务后复跑，不把失败算通过。
- `/tmp/CarryPerfProductionPathRound1.xcresult` 首次工厂路径测试返回 sessionExpired；原因是合成会话缺必填用户日期，改为官方 SDK Session/User 编码，不放宽生产校验。
- 模拟器没有 iCloud 身份，启动日志有 CKAccountStatusNoAccount；没有据此声称 CloudKit 验收通过。编译诊断与这些运行环境日志分别记录。

## 最终证据与剩余门禁
最终两轮结果与构建签名补记在下方。自动化验证使用合成数据，未上传已有真实行程。模拟器 CPU/系统不能代替 iPhone 12 / iOS 17.1.1；仍需具体页面复现、主线程/帧率/内存采样及界面验收。完整账户、迁移、AI 和双设备验收独立进行，保持入口关闭和草稿 PR。

- 最终同一源码两轮原生自动化均 **86/86**：`/tmp/CarryPerfVerifiedRound1.xcresult`、`/tmp/CarryPerfVerifiedRound2.xcresult`；日志 `/tmp/carry-perf-verified-round{1,2}.log`。两轮均包含实际 AccountService 工厂的有界 HTTP 测试。旧 RelayRoundTripTests 依赖另一服务，明确未选入，不能计为通过。
- Release build 通过：`/tmp/carry-perf-verified-release.log`，编译 warning/error 为零；strict/deep codesign 通过。签名团队 `25RAM7275Z`、原应用 ID、Sign in with Apple Default、CloudKit Production，发布入口仍为 false。
- 九语言审计 **0 errors / 0 warnings**：`/tmp/carry-perf-verified-i18n.log`；`git diff --check` 通过。
- 此次服务端生产逻辑/数据库未改，既有 47/47 两轮记录保留；仅修改 loopback QA 的流式夹具，不把它描述成新的云端验收。
