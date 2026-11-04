# 暂停删除账户的安全恢复
## 当前边界
用户授权继续恢复本人账户。工作在独立 `codex/account-deletion-recovery` / `Carry-account-recovery`，复用 `375b8aa` 后补齐原生入口与安全审查。没有修改父工作树、提取 Keychain 凭据、重建身份或上传私人备份。
恢复迁移和两个 Edge 服务已安装。用户连接手机并完成新的原生 Apple 授权后，2026-11-04 23:17:56（北京时间）恢复事务成功提交；独立只读核验确认原账户恢复，原删除回执为 cancelled。
## 核验事实
- 原 Auth 身份保留，两条旧 Apple 凭据均已撤销。
- 12 条业务记录的全部字段通过现行 schema 验证；父子类型、归属及无悬空检查通过，全记录摘要与本轮首次只读结果一致。
- 一条资产、一条上传尝试和一个当前 Storage 对象指向同一不可变版本。完整下载 131,072 字节，SHA-256 与账本一致，未查看或记录文件正文。
- 官方 API Gateway 24 小时结果仅一条 DELETE，与唯一账本尝试路径精确匹配，终态 409；随后同一路径 HEAD 终态 410。两条线上清理路径的源码均下载核对，与已审查 adapter 完全相同；该 HEAD 分支抛错退出，不会继续发送对象 DELETE。没有用等待或成功 GET 代替终态证据。
- 仅对该申请按账户锁、原申请时间、purging、无在途主租约及完整图摘要条件登记隔离与证据摘要。schema 安装自身不批量修改账户任务。
## 恢复行为
回执新增粗粒度 `recovery_available`；后台证据与隔离排空满足后，原生才显示“恢复账户”和官方 Apple 按钮。普通登录、退出及新删除不能绕过原回执。
新 Apple nonce、ID token、一次性 code、原 subject、原 Auth UUID 和原删除回执共同绑定恢复。服务端再次完整核验文件字节，最后在账户锁内复核业务图/资产/上传尝试摘要与 provider 版本。任一变化均保留隔离并拒绝激活。
成功事务只保存新加密凭据，恢复已验证的资产状态，撤销旧 AI grants 与其他原生会话，将原回执写为 cancelled。原生验证身份及服务可用、持久化会话和资料后才移除本机回执；保留本地行程和未同步草稿。
审查修复：未来再次删除继续携带旧会话禁用列表；cancelled 轮询先验证 Auth 再清回执；恢复按钮状态在成功、完成、取消回执和新删除时复位。
## 验证
- 服务端完整通过两轮各 140 项，含真正独立 PostgreSQL 并发。中间一次 139/140 暴露测试 teardown 的 FORCE DROP 杀掉尚未关闭的连接；已等待全部连接 end 事件后普通 DROP，未修改生产逻辑规避失败。
- 原生账户测试两轮各 40 项，零失败；测试构建及实体机 Debug 构建通过。测试宿主 iCloud 未登录不作为真实 iCloud 验收。
- 九语言审计 0 错误/0 警告，实体机包内新增文案九语言值逐项核对通过。只在打包产物启用授权的开发账户/AI门禁，strict/deep 签名通过。
- 两个部署包从官方后台下载，与测试产物字节完全一致；账户服务保留 JWT 检查，回执服务保留原回执认证配置。托管未认证请求均 401；bundle 本地初始化与拒绝未认证检查通过，不能替代真实恢复验收。
- Postman 未初始化/未登录；沿用仓库回归及单次请求，没有创建工作区或上传真实请求数据。
## 部署记录
- 迁移 `20261103150216_held_account_deletion_recovery`，SQL SHA-256 `0575c0d8fca3a6000f51088792f758cb7131e64a764fa2b3c441cb208cff3f77`，同事务登记 history。
- `carry-account` index SHA-256：`c34b1046e475cac0e9842a17c1872c79aa29e26d238c5de0600111007a2ea543`。
- `carry-account-status` index SHA-256：`2a10ee677ea25091f76e86bd601c1ad8a6eecd64b08617b8033462c976e5c7e2`。
- 父任务运维迁移 `20261103144256` 不在本轮部署范围；后续工具须保留真实缺口，不能仅凭最大版本号认定已安装。
- Provider 证据保存在本机任务产物；Git 不记录账户 UUID、subject、邮箱、回执、token、行程字段或文件正文。
## 真实手机恢复验收
- CoreDevice 4016 在用户数据线连接并解锁后解除，未重复镜像点按；检查时没有原 Carry 运行进程。原 bundle ID `app.nevestudio.carry` 覆盖安装一次，启动成功。
- 安装前本机受限容器备份 55 文件、35,937,910 字节，6 个 SQLite integrity_check 均 ok；原账户 replica/物化各 12 条，pending replica/native changes/native transactions 均 0，备份中两份原文件副本的完整摘要匹配云端。未导出 Keychain。
- 用户明确确认已在手机完成 Apple 授权。后台回执于北京时间 23:17:56 写为 cancelled，原 Auth UUID 保留，当前一个新的有效原生会话、一个新的有效原生 Apple 凭据；旧原生会话剩余 0、旧未撤销 AI grants 为 0。
- 原业务图仍为 12 条，全记录摘要完全未变；原不可变文件/版本仍在，131,072 字节，verified assets=1、complete attempts=1、待清理 attempts=0，恢复隔离已按事务解除。
- 这里只恢复了原账户与其现存数据，没有重建账号或重导入备份。旧 AI 连接须由本人重新授权，不自动复活旧 grants。
- 本机完整备份路径 `/Users/murphy/Documents/Carry-Recovery-Backups/20261104-before-recovery`；脱敏恢复证据在本聊天任务产物，具体私人内容不进 Git。
