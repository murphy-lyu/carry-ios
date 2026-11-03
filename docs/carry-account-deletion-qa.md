# Carry 账户删除后台任务验收
日期：2026-10-29。记录组件实现；账户全业务同步、资产迁移与 AI 尚未整体交付。

## 行为与契约
原生完成新鲜 Apple 授权后，先恢复已有删除回执；没有已受理请求时刷新原生身份，核对账户，再将随机 256-bit 回执写入 ThisDeviceOnly Keychain，最后发送删除请求。服务端派生账户与 native session，事务内再次核对会话，设为 deleting 并保存任务。HTTP 202/deleting 仅表示受理，不清空身份或显示成功；断线丢响应通过回执恢复，不重放 Apple 的一次性 code。

独立 `carry-account-status` 使用 Authorization 中的随机回执认证，返回 deleting/deleted，不接受账户 ID、查询参数或正文。该函数需要在 Auth 身份删除后仍能查询，单独使用 `verify_jwt=false` + 回执认证；原账户、数据、文件、后台执行接口的 JWT 网关仍为 true。无回执、用户 JWT、未知回执都不能读到状态或旅行内容。

后台任务依次撤销每份已保存 Apple 凭据、确认 Storage 文件与上传尝试已清理、事务清理当前全部业务图及配额/限流记录、调用 Auth Admin 删除身份。每步持久化租约、进度、重试时间；最后由数据库独立确认 Auth 用户确已不存在，才记录完成。Auth 删除响应丢失时只接受 provider 的 user_not_found 作为可重试的已移除状态，其他 404/401/403/500 不算成功。

新加入的 `carry_private.*.account_id` 数据表必须显式纳入 purge，未知表会阻断删除，防止以后 AI/迁移新增表被遗漏。任务诊断记录 30 天后移除身份映射；保留无账户映射的随机回执摘要，长期离线设备仍可确认已完成删除。私有表全部 RLS 默认拒绝，客户端无 RPC/table 授权。原本地/iCloud 行程未进入此删除范围。

## Review 与修复
- 原先同步串行删除在撤销/清理失败后没有可恢复任务，App 关闭便不能继续；改为独立后台任务，文件回收与账户删除使用不同的 Vault 能力，调用方不能选择账户。
- 接口流式正文复用有大小、取消和总时限的读取器，外部 Auth/Apple 响应同样有界；撤销仅接受 Apple 文档规定的 200。固定官方 Auth API version，并兼容明确的 legacy user_not_found 字段。
- 原生记录“受理”与“完成”分开；离线刷新不把 pending 状态退回普通登录，处理中不允许换身份或丢掉回执。补充无会话完成确认、未知未受理回执、HTTP 丢响应后重启恢复等检查。
- Review 发现普通账户 HTTP 仍会默认跟随重定向，可能转发请求体；新增通用禁止重定向代理，账户/Auth/graph 使用无 Cookie/磁盘缓存的会话，文件接口复用同一代理。实际 loopback 307 夹具验证目标端没有收到 bearer/正文。

## 已执行检查
- 两轮原生完整组件各 116/116：`/tmp/carry-deletion-http-final-native-round{1,2}.log`，结果 `/tmp/CarryDeletionHTTPFinalRound{1,2}.xcresult`。合成身份与本地 HTTP，不是实际 Apple/双设备验收。
- 两轮服务端各 88/88：`/tmp/carry-deletion-final-server-round{1,2}.log`。PGlite 执行数据/权限 SQL，覆盖错误顺序、未清文件、Auth 未移除、旧租约回调、未来未注册表、失败重试及私有回执。provider 网络为受控夹具。
- Deno 2.9.6 检查 account/status/maintenance 三个实际入口通过：`/tmp/carry-deletion-deno-check.log`。
- Release 成功 `/tmp/carry-deletion-http-final-release.log`，strict codesign 通过。构建后从 HEAD 恢复并补齐三条九语言文案，`/tmp/carry-deletion-final-i18n.log` 为 0 error/0 warning。未把 Debug Widget 旧 metadata 提示当作修复。
- 真实 carry-dev 部署十四份迁移。`carry-account` v1 SHA a8ad51cdc4b87e8c2d31e7601d7fb16874037109d236abd02578c24d9976a0ab；`carry-account-status` v1 SHA 9572f8f8ee7c07a256369a6f2dccafefe9842eae55be88111754ea8290015a43；`carry-maintenance` v1 SHA 14519c21754e80a8905cda22ae28212668c68b89c55a55919b9692cd8d993d3c。部署后已读回核对。
- 两轮实际云端合成删除：`hosted-deletion-smoke-setup.sql` 明确模拟 Apple 已撤销，不接触真实 Apple 身份；后台实际执行数据库 purge 和 Auth Admin HTTPS 删除，定时调用 processed=1/deferred=0。真实回执 endpoint 在 Auth 已不存在时返回 HTTP 200/deleted。清理脚本先验证任务完成，不通过手动删除 Auth 用户冒充成功；最终 synthetic_users/jobs/receipts 全为 0。
- 首轮合成 Auth 用户缺 created_at，provider 拒绝扫描，任务保持 deleting_auth 且退避；只读取 DELETE 的错误字段定位，补全夹具时间字段后同一任务由定时器恢复完成。没有弱化身份、关闭保护或将 500 当成功。第二轮使用修正后的完整夹具通过。
- Postman 无回执 401 断言通过，事件上报关闭：`/tmp/carry-deletion-status-anonymous.log`。Security advisor 只有 15 项私有表默认拒绝的 INFO，无 WARN/ERROR。

## 尚待整体验收
真实 Apple 登录/撤销、原生删除页面视觉与动态字号、全业务及文件迁移、双设备、退出/换账户、账户缓存及未同步编辑处理、AI 授权/执行仍需完成。Simulator.app GUI 在本机缺失，未伪称截图验收；原生测试使用已安装的 headless runtime。门禁保持关闭，没有安装本阶段版本到实体手机、没有发 TestFlight。
