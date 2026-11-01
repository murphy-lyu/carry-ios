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

## 真机验收结果

用户重新完成Apple授权后明确反馈“已显示我的邮箱”。服务端仅核对状态布尔值：新账户主邮箱与Apple身份邮箱一致、两者均为非隐私邮箱、provider email_verified=true，活动Apple凭据1份。邮箱显示这项已通过真实用户验收，无需再次删除账户。业务实体及文件仍为0，原有本地/iCloud行程未迁移，原备份仍在本机受限目录。

原生/网页登录身份一致性、真实同步、文件、双设备与新Codex公共连接仍需按总验收继续检查；本项通过不代表整项功能已完成。

## Apple 通知中的应用名称

Apple Developer 原生 App ID（`app.nevestudio.carry`）的 Description 原为 `XC app nevestudio carry`，与用户撤销通知一致。已改为 `Carry` 并保存，重新读取标识列表确认名称与 Bundle ID 对应正确。保存前后逐项比较 capability 控件，值完全一致；未修改 Bundle ID、能力、签名或 App Store 本地化名称。历史邮件不会更新，新生成通知的最终显示仍待 Apple 实际通知验证，未为此再次撤销用户授权。

## 网页发起 Apple 登录失败

用户截图停在 `/auth/apple/start`，尚未进入 Apple。代码中的 `Referrer-Policy: no-referrer` 与精确 Origin 的 CSRF 校验冲突：Fetch Standard 的非 CORS 表单 POST 会按此策略将 Origin 设为 `null`。原测试手工提供正确 Origin，未覆盖真实浏览器的来源策略行为。参见 https://fetch.spec.whatwg.org/#append-a-request-origin-header 。

页面策略改为 `same-origin`，保留同站来源，跨站 Apple/第三方不发送 Referer；不接受 null Origin、不放宽 CSRF 或 Cookie。原生、注销和 AI 表单共用的响应头一并修复。两轮网站各23/23，workerd四项检查通过，并增加策略断言及 null Origin 拒绝回归。

已发布账户网站版本 `cf93274f-c40c-43f1-bd18-20c0d12843bf`，AI 入口仍关闭。线上新取表单与 Cookie 后，null Origin 返回403 `origin_mismatch`；正确同站 Origin 返回303且目标为 `appleid.apple.com`。这只证明发起步骤，用户真实 Apple 网页回调仍需验收。本机直连探针最初超时，改用 Node24 的系统代理环境后完成检查，未改网络设置或 TLS 验证。

### 回调仍失败：诊断未完成

用户随后截图已到 `/auth/apple/callback`，仍显示通用错误，不能宣称网页登录完成。既有页面未展示错误码、Worker未记录失败阶段，无法从截图区分flow cookie、Supabase身份或生命周期登记。新增固定错误码响应头/页面标识，以及仅包含固定阶段、静态错误码和HTTP状态的结构化日志；绝不记录请求、URL、Cookie、令牌、Apple code、邮箱、账户ID或原始异常。

23项回归通过，诊断版本 `c43e16e0-245b-4511-8347-5279f49014df` 已部署。该版本只是增加可诊断性，尚未修复未知的回调问题；等待一次新的本人Apple授权获取失败码。不刷新或重放已有callback，不擅自删除账号、重建密钥或更改Apple配置。

用户下一次截图为 `invalid_apple_identity`；结构化实时日志确认 phase=`apple_identity`、401，失败发生在Supabase signInWithIdToken，尚未调用生命周期登记。独立只读检查使用现存网站publishable key请求Auth settings，返回200且Apple enabled=true，排除key无效或provider关闭。尚不能区分audience、nonce或上游错误；未宣称修复。

进一步只在内存分类provider错误，日志仅输出固定枚举，保留原始消息与身份隐私；新增nonce/audience/限流/上游异常分类及不泄露秘密的回归，两轮24/24。分类版本 `587de073-27e0-495c-a1a9-ef53b2fc03dd` 已部署，等待新的本人授权。浏览器原生操作出现ScreenCaptureKit -3812，扩展返回Work settings禁用，无法读取现存Supabase详细日志；未绕过浏览器权限提取会话。404扫描噪声不再记录。

### 根因确认与修复：Workers 不支持 redirect:error

用户再次授权仍失败。改用纯合成回调（加密flow与假令牌，绝不重放用户的token/code）复现，细分类显示 `apple_identity_transport`；未向Apple交换假code或创建账户。Cloudflare官方文档明确：Workers构建 `redirect: "error"` 的Request时即抛TypeError，尚未发出网络请求。原上游包装使用此选项；SDK将异常作为Auth错误返回，原分支又统一标成401 `invalid_apple_identity`。参考 https://developers.cloudflare.com/workers/runtime-apis/request/ 。

上游统一改为 `redirect: "manual"`，收到3xx立即取消响应并拒绝，不跟随并携带凭据；同时修正错误语义，传输/服务不可用返回503，限流429，不再伪称身份无效。覆盖Auth、资料更新、账户登记和注销等共同路径。临时响应体格式诊断已移除，未记录任何真实上游内容。

- 新workerd回归实际运行Supabase SDK的fetch，而非只检查登录页和Apple跳转：合成认证成功并恢复Cookie、无效token拒绝、上游302拒绝且仅请求一次，均通过；外网完全拦截，只允许固定QA项目与合成身份。
- 对旧bundle执行相同回归，实际Auth请求次数0、期望1，明确复现旧缺陷。新bundle两轮均通过，加上原4项页面/CSRF检查。Node两轮各24/24。
- 最终网站版本 `7ad0cefb-5d24-41bd-8e50-7beb892049d1` 已部署。中间修复版本的线上纯合成回调不再出现transport，进入provider对假token的正常拒绝；一次网络探针超时已单列，未算通过。
- 用户真实网页授权仍需最终验证；本轮不声称已登录同账户、不启用AI、不上传真实行程或发布App。

### 本人真实网页登录通过

用户随后回复“已完成”，并提供 `account.nevestudio.app/` 的账户首页截图；原生Chrome AX也读取到“Your Carry account”与退出按钮。真实Apple授权、Supabase身份、Carry生命周期登记及登录后首页读回这条链路通过，不再把网页回调记为未完成。

原生与网页同账户仍需独立核对。已在carry-dev SQL编辑器准备只返回用户数、active账户数、同账户是否同时有原生/web audience、业务实体和文件计数的SELECT；不查询邮箱、subject、账户UUID或凭据。界面工具多次出现ScreenCaptureKit错误/不可用窗口，Run结果未可靠返回，尚未把该查询视为通过；已请求用户仅协助点击Run并提供计数结果。未修改表、授权或真实行程。
