# 原生迁移、离线与双客户端验收

日期：2026-11-01。仅合成数据；没有读取、迁移或上传用户现有 13 趟真实行程。工作树 `Carry-codex-integration`。

## 本轮证据范围

- 新增 `NativeTwoClientAcceptanceTests`，通过真实 loopback URLSession → 原生 graph HTTP handler → PostgreSQL core（PGlite）→ 两份独立磁盘 SQLite / SwiftData store 完成用户流程。
- 每个用例调用既有 `POST /__fixture` 获取独立合成账户历史，没有正式 Apple 会话、生产凭据或用户文件。完整 native runner 默认使用既有 8891 夹具；本轮选定回归用独占 8981，不影响其他并行任务。
- 这是两个原生客户端/数据库的同步证据，不能替代两台物理设备、真实 Apple 会话、手机断网界面或系统文件预览。当前 Mac Catalyst ↔ iPhone 物理设备验收由主任务独立执行。
- 用户已说明第二台 iOS 设备暂不可用；iOS ↔ iOS 专项验收记待办，不作为本轮可继续开发和验收的阻塞。

## 新增场景

1. 两端从同一已确认版本分别修改名字和目的地；第一端暂停同步、保存、重建磁盘客户端后，待发送日志与本地编辑仍在，联网后两端字段收敛且没有重复行程。
2. 两端同时修改同一字段；第一次同步响应即进入冲突复核，选择另一端已发布的名字时，保留自己独立修改的目的地；最终两端收敛。
3. 另一端删除行程，第一端有离线草稿；第一次同步即可复核删除，保留本机草稿，明确选择恢复后以原稳定 ID 在另一端恢复。
4. 通过实际 Controller 迁移一份包含打包状态/数量的合成旧行程；第二份 store 拉到完整原生模型并继续修改，第一端收到修改，旧源快照保持不变且受只读保护。

## Review 发现及修复

- 原生 Workspace 把 HTTP 409 业务冲突、422 `deleted_entity` 与网络故障都落到 `.failed`。同字段冲突首响应显示通用服务错误；远端删除还需要第二次人工重试才能读回删除状态、出现可用复核。
- 修复落在 Workspace 的编排层：SyncEngine 已原子持久化阻断被拒绝的请求后，对 409、422 `deleted_entity` / `invalid_parent` 立即执行一次它的只读同步阶段，取得最新字段/删除状态，再按现有 pendingFailure 机制进入 `.conflict`。低层 transport / SyncEngine 的抛错契约不变，未自动选择冲突值或重发被拒绝的 mutation。
- 新测试分别记录发送次数，要求业务拒绝只多一次写请求；只读收尾不得变成网络写入重试。会话失效、网络不可用、非法响应仍传播，取消仍经 workspace lease 屏障处理。
- 新测试辅助 Client 初版缺少实际 Controller 已有的 `store.refresh()`，使磁盘重开时列表尚未载入，已修夹具；该项不是产品冷启动丢数据。初版辅助类缺显式 MainActor 的编译失败也已修正；流式代理通过显式 MainActor 回调闭包转发，消除非 Sendable 参数直传告警，没有压制并发诊断。

## 运行记录

- 基线 `/tmp/CarryNativeTwoClientBaseline-20261101.xcresult`：迁移用例通过，3 个用例失败。其中两项确认上述业务冲突状态缺陷，一项为辅助 Client 缺 refresh。
- 修复后首轮新场景 4/4 与原 Workspace 11/11 共 15/15 通过：`/tmp/CarryNativeTwoClientFixed1-20261101.xcresult`。随后加入拒绝请求不重发的计数断言，随后完成选定回归两轮：每轮 69/69、零失败，包括新双客户端 4、Replica 28、Controller 14、Workspace 11、冲突复核 7、同步屏障 5。结果分别为 `/tmp/CarryNativeTwoClientFinalR1-20261101.xcresult`、`/tmp/CarryNativeTwoClientFinalR2-20261101.xcresult`。
- 最后 Review 加强迁移用例时序：先显式暂停第一端自动同步，再由第二端发布编辑，恢复第一端后读取，确保断言不会偶然等待在第二端发布之前启动的旧同步。该版补充回归结果见下。
- 时序加强后：新双客户端 4 项 + Controller 14 项再次连续两轮 18/18、零失败；`/tmp/CarryNativeTwoClientResumeR1-20261101.xcresult`、`/tmp/CarryNativeTwoClientResumeR2-20261101.xcresult`。最终构建日志 `/tmp/carry-native-two-client-final-build4-20261101.log` 无 warning/error，`git diff --check` 通过。

## 本轮保留项

- 第一端真实 Apple 会话、Mac Catalyst ↔ iPhone 同步及真实设备文件预览由主任务验收，本报告不代替其结果。
- 第二台 iOS 设备专项同步、锁屏/后台恢复/系统网络切换的双 iOS 场景仍待用户后续提供设备；按用户要求记录待办，不作为本轮本地实现交付阻塞。
- 本轮没有对真实旧行程执行迁移，也没有自动替用户选择冲突值。所有新增测试为合成数据。

## Mac Catalyst 地点详情崩溃追加排查

- 主任务在真实 Mac Catalyst 首次 Apple 登录、同步成功后，两次点击合成地点均崩溃。仅检查 `Carry-2026-11-01-170206.ips` 与 `170224.ips` 的异常类型和符号栈，没有复制账号或行程内容。
- 两次都是 `EXC_BREAKPOINT`，主线程 `EnvironmentObject.error → StopDetailView.store.getter → stopScheduleSubtitle → header`。可确定详情缺少 `TripStore` 环境对象，与登录/同步接口无关。
- `ItineraryView` 统一 sheet 内容此前依赖外层导航环境的继承。改为在统一呈现根显式注入当前 `store` 和 `router`，覆盖地点、交通、住宿详情及添加/编辑/路线等所有分支，并保留账户行程所属 store。
- 本地编译和主任务 Mac 实际点击回归另行记录；代码通过编译仍不代表 Catalyst 呈现问题已验收。
