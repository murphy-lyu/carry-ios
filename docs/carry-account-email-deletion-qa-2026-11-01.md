# Apple邮箱显示与账户删除联调修复

日期：2026-11-01。用户真实登录后更改Apple邮箱共享选择，Carry仍显示隐私邮箱；随后在Carry明确提交删除请求，界面停留在处理中。本次延续同一功能的修复与验收，不迁移或上传旧行程。

## 根因与实现

- 只查询邮箱状态布尔值，确认Supabase主账户email仍是隐私邮箱，而Apple关联身份email已为不同的非隐私地址，且email_verified=true。原生资料直接读取主账户email，登录与恢复都会重复展示旧地址。未把个人邮箱、Apple subject、账户ID或令牌写入本记录。
- 账户显示邮箱统一读取当前账户的已验证Apple身份；同时检查provider、身份所属user UUID及email_verified（布尔或字符串true）。唯一一致结果才用于显示，多身份不同邮箱/未验证/非Apple/错误owner均回退原Auth账户邮箱。可编辑user_metadata不作邮箱依据，不改Auth账户ID或主登录邮箱，不根据地址是否为隐私邮箱强行选择真实地址。
- 登录与恢复共用saveProfile；原先选择隐藏邮箱的用户仍按已验证Apple隐私邮箱显示。新增实际SDK/HTTP适配回归覆盖重新共享、恢复、再次隐藏及伪造/歧义来源。
- 原删除后台每次仅推进一个持久阶段，阶段间需等待Cron及全局分发租约，撤销已完成时界面仍可能等待数轮。新增受限连续执行器：每个阶段继续独立领取operation、校验租约和前置条件并落盘；一次最多6步、45秒预算后不再发起下一步。失败立即保留重试状态，不跳过文件清理或Auth实际删除。维持既有Cron和JWT/内部能力边界。
- 删除页可见期间每10秒查询自身持久回执；页面消失取消任务，完成自动回到未登录状态，手动检查按钮保留。

## 验证

| 检查 | 结果 | 本机证据 |
|---|---|---|
| 原生完整回归两轮 | 每轮339/339，新增3项邮箱来源回归 | `/tmp/CarryAccountEmailDeletionQA-20261101/round-{1,2}.xcresult` |
| 服务完整回归两轮 | 每轮120/120，新增多凭据顺序/失败重试/预算续传回归 | `/tmp/carry-email-deletion-service-20261101-r{1,2}.log` |
| 真机Debug构建 | BUILD SUCCEEDED，Swift告警/错误0 | `/tmp/carry-email-deletion-device-build-20261101.log` |
| 严格签名/安装/启动 | 通过，同Bundle ID与CloudKit Development；未新增App | `/tmp/carry-email-deletion-device-{install,launch}-20261101.log` |
| 原生正式门禁 | 源Secrets仍为false，只有验收产物为true | 本机配置读回，值未进入Git |
| 真实删除 | 13:24:37（上海）后台stage=deleted、Auth用户0、Apple凭据0、业务实体0 | 已通过Supabase只读查询核对；未手工删除业务表或绕过阶段标记 |

维护函数已发布，当前carry-maintenance v5；原JWT要求保留。发布前读取的上一版本源码与已审核HEAD逐文件一致。通过既有内部dispatcher触发已授权的待处理作业，没有修改全局租约或跳过撤销。

本次删除针对用户已在Carry确认的空账户：初查业务实体/文件均为0。真实初次Apple登录与凭据撤销/账户删除已发生；这不证明旧数据迁移、文件同步、双设备或完整Codex链路。

## 尚需用户验收

修正版已安装。手机正在使用，iPhone镜像提示需锁屏，未继续抢占界面。用户需重新在Apple系统授权中选择Share My Email并完成本人验证，核对最新显示邮箱；不能把合成测试通过或安装成功当作实际新账户邮箱已验收。无需再次删除账户。原有本地/iCloud行程保留，原备份仍在本机受限目录。
