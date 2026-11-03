# 原 Carry 真机同步与文件验收

日期：2026-11-01。仅 carry-dev 和原 Bundle ID 的实体机 Debug 验收包；正式入口及原生 AI 门禁保持关闭，不发布 TestFlight。公开 AI 网关及网站已显式启用开发联调，见文末版本记录。

## 范围与备份

- 用户已锁屏并保持实体机连接。开始前完整备份原容器，46 个文件、31,757,120 字节，5 个 SQLite quick_check 均为 ok；备份和摘要清单仅在本机受限目录，不进入 Git。
- 原有 13 趟行程未选择迁移。通过账户页“Sync new trips”开启独立账户工作区，只新建 `Carry QA Sync 20261101`，无日期，目的地为公开地点 Shanghai。
- 测试行程加入公开的上海博物馆地点、合成费用 CNY 42，以及纯合成文本附件。没有选取私人照片、备份或真实旅行文件。
- 合成附件 `Carry-QA-attachment-20261101.txt`：131,072 字节，SHA-256 `47491b540f186807cedebe39a39923ab62a87f67f5987f31df298cde79f0f106`。

## 已读回的真实结果

- 原生与网页同账户核验继续为：auth 用户 1、active 账户 1、两种 audience 同账户 true。
- 新建行程后云端实体从 0 变为 2（行程与一天）；新增地点后为 3。
- 添加附件最初停留在本机 durable job，文件名、字节数及 SHA-256 正确，未丢失；云端 asset/attempt 为 0。
- 查明开发库没有任何 `asset_budgets`。服务端按既有契约拒绝未配置额度，未绕过验证。仅为当前唯一已登记开发账户配置 157,286,400 字节、最多 3 个 pending；事务先校验 auth 用户和 active 账户各唯一，已有预算不覆盖。没有购买套餐或调整权限/RLS。
- 重试后实际 SQL 返回：entities=4、verified_fixture=1、complete_uploads=1、stored_files=1。文件验证条件同时匹配 state、完整字节数与 SHA-256；不是仅创建 Storage 元数据的回滚夹具。
- 更新安装后原测试行程、地点、费用与附件仍在；原 13 趟行程保持可见。

## 真机发现及修复

1. 同步卡片多一行留白：`Color.clear.frame(height:0)` 仍被 Form 分配行高。生命周期和 sheet 修饰器移到始终存在的状态文本，移除占位 View。真机已确认两行状态/重试布局没有空白行。
2. 已同步后仍显示旧失败：卡片“Sync now”直接调用 workspace，外围“Try Again”由 controller 调度；前者成功不会清除 controller 保存的旧错误。统一走 controller，重试开始先清旧错误，失败状态不再重复展示同一错误和第二枚重试按钮。
3. 新增 controller 回归：先让 transport 失败，再恢复，检查发起下一次网络读取前及成功后都不残留旧 failure。两轮原生各 341/341，通过。日志 `/tmp/CarrySyncRetryQA-20261101/round-{1,2}.log`；结果包同目录。
4. Debug 真机重构建、strict codesign、更新安装及启动通过。证据 `/tmp/carry-sync-retry-device-{build,install,launch}-20261101.log`。仅验收产物打开账户门禁，源配置仍关闭。
5. 真实下载首次、补齐测试目录后的第二次都报 `invalidSource`。诊断只输出目录层级与目录/符号链接布尔值，确认沙盒内层级 0–8 均为普通目录，系统祖先层级 9 是符号链接；没有输出路径、账户 ID 或凭据。下载器原先一直检查到文件系统根，误拒绝 iOS 系统路径别名。改为以系统提供的 App 容器为信任边界，拒绝容器外下载目录，并检查容器内每级祖先与文件；未放宽沙盒内符号链接、哈希、账户或版本检查。
6. 修复后实体机只读托管检查连续两次通过：原 Carry 已有会话恢复、实际 graph/manifest 读取、重新下载同一合成文件、131,072 字节与 SHA-256 校验、Range 请求返回 400。测试未导出令牌、未上传/删除/创建身份；两份 xcresult 为 `/tmp/CarryHostedAssetQA-20261101-fixed-round{1,2}.xcresult`。
7. 最终两轮原生各执行 343 项：342 通过、1 项手动启用的物理设备检查按预期跳过，0 失败。保留原离线哈希/符号链接测试，新增越界下载根在网络授权前被拒绝的测试。证据 `/tmp/CarrySandboxDownloadQA-20261101/round-{1,2}.log`。Release 未签名编译通过，Swift warning/error 为 0；日志 `/tmp/carry-device-sync-release-20261101.log`。
8. 含下载修复的常规 Debug 包重新构建、strict codesign、更新安装及启动通过，日志 `/tmp/carry-sandbox-device-{build,install,launch}-20261101.log`。最后镜像提示 iPhone 正在使用，未把重新安装当作预览界面已验收。

## 继续核验

- 真实重新下载已通过；原生预览、离线/双设备及显式合成迁移仍按实际证据补齐。没有以单机上传成功替代这些检查。
- 当前预算仅供开发验收；正式开放前还需明确服务端账户预算的分配/升级政策，不把本次单账户配置当作全用户配额方案。
- 镜像工具曾返回 noWindowsAvailable，重新读取和恢复窗口后继续；该故障不计作 Carry 崩溃。地点搜索 Tokyo 曾出现国内相似名称 POI，本轮改用 Shanghai 做确定性同步验收；海外搜索质量另待定位。

## 开发 AI 网关联调

- 网关部署前回归 30/30。保留原 Durable Object 与旧 token 路由，以显式 CLI 变量 `ACCOUNT_AI_GATEWAY_ENABLED:true` 部署，版本 `931e2389-430a-451c-afbf-b36dae1d6845`；仓库默认仍为 false。
- 网站 acceptance 环境显式覆盖 `ACCOUNT_AI_ENABLED:true`，版本 `a1ff79ba-f5bc-4151-b610-3188b9233042`。网站已用现有真实会话打开 `/connections`，实际显示无已连接应用，证明身份桥接可读；没有自动授权任何客户端。
- 公开 protected-resource 元数据实际 200、resource 指向 `https://connect.nevestudio.app/mcp`。本机其余直连探针和一次合成 public-client 注册发生连接超时，未将尝试记为成功；完整 OAuth/PKCE/MCP 仍继续。注册尝试的本机 PKCE 状态仅在受限目录，不进 Git。
