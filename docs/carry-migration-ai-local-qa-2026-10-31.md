# 旧数据迁移与 AI 本地验收

分支 `codex/carry-integration`，独立工作区 `Carry-codex-integration`。本轮按用户要求只推进不依赖云端及手机的工作，所有运行数据均为合成夹具。原本地/iCloud 行程未迁移或上传。

## 实现范围

- 旧数据迁移为显式选择操作，登录及启用同步不会自动迁入。精确选择行程与可选物品库，创建不可变批次前冻结本机源写入，先生成独立恢复备份和原始文件，再上传与发布。
- 批次保存稳定请求 ID、分页 ACK 进度、源指纹及恢复证据。对全部选中实体的字段、父关系和文件 manifest 读回核验，确认原生模型物化后才发布活动归属；旧源继续只读保留。未开始发布的批次可取消；结果不确定的批次只能续传或复核。
- 源在其他旧设备发生变动会产生复核流程，保留两版不重置打包状态、不丢费用/预订/关系/文件；源删除不会伪造空行程复活。恢复文件独立于普通缓存保留。
- AI 机场目录、境内高德/境外地点、航班代理、固定端点路线预览和打包规则接入真实运行时。路线明确为大圆估计，不伪造道路时间；打包规则来自原生源及九语言目录并校验源摘要。
- 私有文件按当前授权、当前活跃实体槽位、verified ledger、不可变 provider version 分块读取并检查字节/SHA。完整备份保留原图/附件/封面/费用/时区/打包；分享排除私人文件及预订资料。生成、第一方批准、私人下载与对外发送分开授权，取消立即终止上游。

迁移的服务端整批提交与手机活动归属切换分属两步：服务器提交后，其他已授权客户端可读到用户最初明确选择的完整快照。本机仍会等待读回、源复核和原生物化，期间保留旧源可读；旧设备后续变动通过“保留两版”单独处理，不宣称已提交云快照仍被所有客户端隐藏。

## Review 发现及修复

- 导出 Response 建立后撤销授权，普通 JSON metadata 仍可能继续输出：逐块复核授权，包括第一次读取前后；缩小 trip scope 同时阻断摘要和下载。
- 上游 read 挂起时仅调用 generator.return 不能中止：保存活动 reader 并先 abort/cancel，再结束迭代，新增挂起取消回归。
- 多目的地证件规则遗漏次目的地；含港澳台即移除护照导致混合国际行程漏证件：统一读取结构化目的地，并以全部目的地判断是否保留护照。
- 国内国家标签与真实坐标辖区不一致：CN/HK/MO分别验证；大写合法 UUID 统一规范化。
- 迁移恢复原先仍依赖普通缓存：改为读取独立、已核验的不可变恢复文件，覆盖缓存被清理的续传。
- 空缩略图在 codec prepare/restore 不对称：保留空预览语义，迁移仍强制收集每张照片原图，绝不把缩略图当原图。
- 共享行程可能夹带收件方照片本地标记：清除全部照片及设备照片来源标记，和附件/背景一样隔离；完整备份还原另走校验文件 stage。
- 大文件完整备份不再静默遗漏不可用文件，文件预算上限128 MB；超限或缺文件明确失败。迁移原图流式保存在独立 sidecar，每份上限50 MiB。
- R7 共281项有两项失败：导出合成夹具未设置时区但断言 Tokyo，已从真实本地 SQL 源显式设置后重新生成；空照片缩略图的 codec 不对称如上修复。R8 为新增测试缺少两处 try 的编译失败，均已修，不能计为验收通过。

- 异步文件 stage 与普通沙盒孤儿回收竞争：改为独立私有暂存目录，完成目标/租约复核后，在同一主线程事务中仅执行 rename 和业务 save；后台完成大文件哈希/读写。恢复前还保存完整自包含安全备份，旧沙盒文件清理后仍能回退。
- 恢复准备期间新保存的数据被覆盖：完整目标 DTO 在开始和最终提交前通过 fresh Context 比较，关系按 UUID 规范排序，脏 Context、替换后的 Context、撤销租约及取消均拒绝提交。
- 旧 iOS 的 ISO8601 默认解析与新 Foundation 对小数秒容忍度不同：显式解析整秒与小数秒格式；参考 [Swift Foundation 源码](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/Formatting/Date%2BISO8601FormatStyle.swift)。
- R9 新测试有一处排他访问编译错误，已修。R10共310项，仅一项旧测试仍假定暂存即发布文件；实际产品路径已改为独立stage，该测试会调整为验证发布前不可见、原子发布和失败清理。其余309项通过，包括异步安全备份9项及启动回收。此轮也不计为最终全绿。

## 最终验证

2026-11-01，最终代码已冻结，验证结果如下：

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 原生完整回归第一轮 | 336/336；27.409秒 | `/tmp/CarryMigrationIntegrationQA-R15/round-1.xcresult` |
| 原生完整回归第二轮 | 336/336；32.091秒 | `/tmp/CarryMigrationIntegrationQA-R15/round-2.xcresult` |
| 账户服务两轮 | 每轮117/117 | `/tmp/carry-migration-service-verified-r{1,2}.log` |
| AI两轮 | 每轮96/96 | `/tmp/carry-ai-envelope-final-r{1,2}.log` |
| 账户网站两轮 | 每轮23/23 | `/tmp/carry-migration-web-final-r{1,2}.log` |
| 真实本地workerd | 4/4，无出站流量 | `/tmp/carry-migration-web-workerd-final-r2.log` |
| Release/严格签名 | BUILD SUCCEEDED；strict codesign通过；Swift编译告警/错误0 | `/tmp/carry-migration-ai-release-final.log` |
| Deno实际函数入口与导入映射 | check通过；机场JSON动态导入及NRT查询通过 | `/tmp/carry-ai-function-lock-verified.log`、`/tmp/carry-ai-function-query-runtime-r2.log` |
| 九语言目录 | 新增54键；0错误/0警告，既有条目语义未变 | `/tmp/carry-migration-ai-i18n-final.log` |

R13及R14两轮均336/336；随后继续检查日志，发现新测试在容器仍被SQLite使用时删除了临时目录。无需持久化的测试改用内存数据库，真实启动测试改由XCTest teardown在容器已释放时清理；仍被框架持有的临时数据库留在专用模拟器临时目录，绝不unlink活跃存储。R15两轮不再出现vnode unlinked或unable to open database日志。合成损坏图像/网络失败负测和无iCloud账号的宿主日志不代表真机验收。

R12的4个失败断言同属一个测试：测试把第二次synchronize误当成一定已拉到新事件，实际可能join仍在进行的旧pass。夹具改为等待旧pass完成后追加事件，采用前先断言raw cursor、原生名称和物化版本均已更新；原来的陈旧复核拒绝、零新增副本和归属断言全部保留，R13起通过。

新增跨设备重号复核不伪造迁移proof：验证已物化的账户版本及全部资源，先归档本机完整源，再保留可编辑副本、切换归属。恢复UUID使用本机账户缓存持久随机namespace，避免两台iCloud设备创建相同业务UUID。重试复用首次不可变备份，仅忽略备份生成时间及不在迁移范围内的全局偏好；所选字段、图片/文件SHA仍必须一致。详见 `migration-ownership-review.md`。

Release产物的CarryAccountReleaseReady仍为false；ACCOUNT_WEB_ENABLED=false，Deno新入口ACCOUNT_AI_ENABLED缺省关闭。本轮未部署、未安装、未上传真实行程。

## 本轮未执行的外部验收

本节为本地交付时快照。2026-11-01后续已完成部分云端部署并安装实体机验收包，最新状态见 `carry-account-hosted-acceptance-2026-11-01.md`。

托管迁移20—24、域名及服务部署、上游查询凭据/网络、真实 Apple 原生与网页同身份、Storage 实际 Range/version行为、双设备与断网真机、视觉/无障碍、iPhone12帧率及最终安装均需外部环境。查询及 Storage 的本地 HTTP/SQL 夹具不证明真实供应商可达。原生 Release、网站及新 AI 发布入口保持关闭。

资产回收接入账户开启时的独占写门：旧工作区已停止并等待全部 I/O，新 factory、导入租约和 Store 尚未公开时执行保留扫描与回收。保留根包括当前原生图、日志、待确认请求、历史记录及迁移批次；不在可编辑工作区启动删除。历史墓碑与未确认批次继续保留，不根据设备时钟推测安全清理。启动先回收再公开 Store 的实测回归已通过，不能等同服务端文件生命周期验收。
