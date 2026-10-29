# 原生日志与并行审查记录
日期：2026-10-30。范围：账户同步接入的本地组件与两处原有性能路径；不代表完整产品验收。

## 分工与发现
主线负责 observed-version 副本、同步日志门、统一构建和回归。并行任务分别审查原生日志、排序/附件性能、网页身份与交付依赖；各自限定文件，未并行运行 Xcode 或操作真实设备。
- P1：备份还原先删旧实例、再按原 UUID 插入新对象时，日志原先仅记录删除。改为按最终存活实例归并，保留跨类型替换与多活身份拒绝。真实 restoreFromData 回归同时检查业务重开、字段差异和无删除日志。
- P2：先写 Journal、后建 Replica 时缺少反向账户校验。Replica 在创建 checkpoint 前检查 Journal owner，错误账户不能写入新 checkpoint。
- 排序：六个普通/自动化入口循环中反复排序或线性查找，改为一次建立 ID 字典，仅更新变化的 sortOrder。保留未知 ID 占位、重复 ID 最后赋值和遗漏对象不变的原行为。
- 附件：原 fileImporter 完整读取文件后才检查 25MiB，缩略图与写入也在 UI actor。新增 utility worker，资源作用域覆盖读取，预检后逐块限读，后台生成缩略图和原子写入；Photos 使用临时文件传输。新文件由 lease 持有，只有元数据保存/表单接收成功才转交所有权，取消或失败清理。相机回调提供的 Data 仍由现有相机组件生成，未宣称所有相机工作均离开主线程。
- 保存门：失败 Context 的弱引用隔离按对象指针身份比较，避免 ModelContext 的 Swift equality 进入没有对应 hash 的 Objective-C 路径；未改变回滚和重建策略。
- 网页：限流、超时及未知身份查询错误不能证明用户已退出。登录和回调统一仅接受明确的无效会话错误，其余返回 503，保留已有身份绑定，不继续发布新 Cookie。

## 已落实的同步组件
十种业务模型以实际变更实体捕获，打包勾选不遍历整行程、不读取外部文件。业务状态与不可变 NativeChangeJournal 同次保存；缩略图单独以二进制保存。字段差异使用实际显示基线，保留未展示的远端字段；只允许本机已接受值推进对应已知字段版本，外部未展示更新不能冒充用户已知版本。

准备资产绑定、写副本意图和消费原生日志共享一个副本事务，准备后的验证或保存失败均回滚。同步器在冻结请求、ACK、pull、补基线后先执行可注入的有界日志门；未排空返回待续，保留冻结 requestID 和回执 offset，不把它写成服务端拒绝。该门尚未连接实际日志消费者，默认回调不能被当成产品已接通。

## 测试与失败记录
- 定向首轮 42/42：`/tmp/carry-parallel-native-fixes.log`。附件与门初轮 8/8：`/tmp/carry-parallel-attachment-barrier.log`。
- 测试编写期间曾把空 pull 当作一定触发投影，断言失败；空页应不投影，随后改用真实非空字段页验证门未放行时游标/数据均不推进。
- 首次完整回归 156/157，新增分页夹具第 2 项错误使用 subtreeVersion=1，违反 sequence=2 的协议约束，被 invalidReceipt 正确拒绝。修正合成回执的子树序号；未放宽产品校验。最终日志另列，早期失败不计入通过。
- 网页身份错误注入先失败后修复，最终两轮各 23/23，dry-run 和禁止外部 IO 的 workerd 检查 4/4。日志 `/tmp/carry-web-identity-binding-final-*`。
- 最终两轮原生各 **157/157**：`/tmp/carry-parallel-integration-final-r1.log`、`/tmp/carry-parallel-integration-final-r2.log`，结果包 `/tmp/CarryParallelIntegrationFinalR1.xcresult`、`/tmp/CarryParallelIntegrationFinalR2.xcresult`。包含真实本地 HTTP/数据库检查；旧 relay 独立网络夹具未启动，明确排除 `RelayRoundTripTests`，未将其计作通过。
- 服务端最终两轮各 **94/94**：`/tmp/carry-parallel-service-r1.log`、`/tmp/carry-parallel-service-r2.log`。网页整合复跑 **23/23**：`/tmp/carry-parallel-web-r1.log`。
- Release 真机目标构建 `/tmp/carry-parallel-release.log` 与 `codesign --verify --deep --strict` 通过；本次源文件无编译器 warning/error。九语言审计 `/tmp/carry-parallel-i18n.log` 主 App/Widget 均 errors=0、warnings=0。模拟器仍有无 iCloud 账号及 Xcode 系统工具日志，不作为真实 CloudKit 验收。

## 交付边界
原生日志消费桥接、完整原子投影、删除/恢复、账户资产下载与保留、账户子库路由、迁移归属、网页登录部署及真实双端同身份、新账户 OAuth/MCP 仍须完成。现有 MCP 仍属于旧配对前台链路，不能宣称手机关闭也已可用。上述缺口接通后才进行最终两轮产品验收与物理 iPhone 安装；当前门禁保持关闭，没有上传真实行程或覆盖手机。
