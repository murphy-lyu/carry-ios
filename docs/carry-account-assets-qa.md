# Carry 账户文件同步：实现与验收记录
日期：2026-10-28。继续同一账户/AI 功能与草稿 PR；本页记录组件证据，完整产品尚未交付。组件检查后，用户进一步授权安装当前开发版本；安装结果见 `carry-iphone-install-2026-10-28.md`，不作为完整功能验收。

## 已实现
- 原生 `CarryAssetUploader` 使用 TUS 1.0、6 MiB 分块、最多两个并发文件和单文件 50 MiB 上限。散列以 64 KiB 读取；每个网络请求重新获取账户服务中的令牌，缓存只保留文件身份、受限上传地址和已确认偏移，不写认证头。
- 账户 UUID 分目录、文件保护与排除系统备份；先验证普通源文件及尺寸，再复制并核对 SHA256。暂停保留断点，关闭阻止重启，删除只清理上传缓存副本。AsyncStream 传递进度，避免业务回调反过来关闭自身上传造成等待环。
- 重开上传先 HEAD，处理服务端已收到但客户端没收到响应、偏移异常和地址过期。拒绝 HTTP 重定向、跨来源/路径的 Location、篡改缓存；控制响应限 16 KiB、缓存 JSON 限 8 KiB。
- `CarryAccountService` 的图请求与文件请求共用刷新/归属检查。已有上传器在账户更换后下次请求前报错；真实 SDK/Keychain 工厂已加入合成集成测试。
- 私有文件记录迁移由 CLI 生成：`20261028141122_account_asset_manifests.sql`。预留身份与原生一致地绑定 account/entity/slot/SHA256；额度未配置时拒绝，过期不自动释放，重复预留幂等。校验失败转为待清理；已验证记录不会被错误的重复校验变更成删除状态。RPC 仅 service_role 可执行，私有表 RLS 默认拒绝。
- `asset-storage.mjs` 只从配置来源和私有记录构造对象路径，不接受客户端 URL。增量 SHA256/计数实际文件字节，超长提前取消；文件未上传、服务暂不可用、取消与内容损坏分别返回。使用 Deno 支持的 `node:crypto`，不把 50 MiB 响应整体放入内存。

## Review 中的修正与边界
1. 第一次上传构建通过后，补上源文件尺寸预检、缓存读取上限、关闭时 URLSession 清理和进度回调等待环修正；扩展测试覆盖实际暂停/重开与每请求令牌刷新。后续 Review 补上暂停尚在等待旧请求时拒绝并发 resume；测试以令牌门闩和取消通知确定时序，没有 sleep 或定时猜测。
2. 第一轮 SQL 测试 0/2：夹具额度恰好少了已验证文件占用的 7 字节；另一个夹具用 service_role 修改 Auth 内部会话而无对应权限。修正合成夹具额度与管理员角色切换，生产权限未放宽；原始失败 `/tmp/carry-asset-manifest-tests-initial.log` 保留。
3. 对象预留不能约束同一对象重复创建 TUS 会话及丢失创建响应留下的临时上传。**不开放客户端直接 INSERT Storage 的方案。** 原生工厂已改为账户项目的 `/functions/v1/carry-assets/tus`，底层仍使用标准 TUS；本地夹具同时检查该入口。正式上传服务仍待实现，不能把此 HTTP 夹具当成实际代理服务。
4. 后续服务必须持久绑定上传尝试和对象预留；创建响应不确定时保留占用，逐次计入额度；PATCH 并发用短租约/栅栏和服务端 HEAD 核对，不能持有数据库事务等待网络。删除开始后阻止新上传，并保留在途创建的真实地址供清理；未知地址的临时上传不能仅凭本地过期宣称物理清理完成。
5. `asset-storage.mjs` 尚未接生产 HTTP/数据库确认流程。异步读完文件后必须在同账户锁下重新检查有效会话及删除状态再确认；服务中断不应被当成损坏而删除。
6. 本次没有增加 Storage bucket、策略或客户端文件权限；第七份迁移尚未部署，托管库仍为已核对的六份。未上传既有行程、照片或附件，未开放账户入口。

## 验证
使用随机 UUID、独立临时目录和 7 MiB 合成文件；源文件不来自用户资料。`asset-qa-server.mjs` 必须显式 `CARRY_ASSET_QA=synthetic-only`，只监听 127.0.0.1:8892，无外部网络，不可部署。

| 检查 | 第一轮 | 第二轮 |
|---|---|---|
| 原生组件集（含 11 项文件测试） | 107/107 | 107/107 |
| Node / JOSE / HTTP / PostgreSQL / 文件校验 | 57/57 | 57/57 |

最终原生日志 `/tmp/carry-asset-final-round{1,2}.log`，结果包 `/tmp/CarryAssetFinalRound{1,2}.xcresult`；服务端 `/tmp/carry-asset-server-final-round{1,2}.log`。原生显式排除依赖旧独立服务的 `RelayRoundTripTests`，没有将它算作通过。模拟器没有 iCloud 账户的系统日志不构成 CloudKit 或双设备验收证据。

Release 证据 `/tmp/carry-asset-final-release.log`；九语言审计 `/tmp/carry-asset-final-i18n.log`。不新增 UI/文案；实际实体机性能、真实文件同步、迁移归属切换、完整删除/恢复与 AI 功能仍待完成。原先按完整验收后装机安排，后续用户明确授权先安装当前开发版本；已完成备份、原位安装、启动和安装前后数据核对，仍未达到完整功能交付条件。

参考：[Supabase TUS](https://supabase.com/docs/guides/storage/uploads/resumable-uploads)、[Storage 访问控制](https://supabase.com/docs/guides/storage/security/access-control)、[Deno node:crypto](https://docs.deno.com/api/node/crypto/)。
