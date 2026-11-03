# 新账户 AI 公共网关验收

最新进展：原生/网页同账户及合成文件真实上传/下载已通过后，2026-11-01显式打开 carry-dev 公共网关与网站联调；版本及真实检查见 `carry-account-device-sync-qa-2026-11-01.md`。下方为首轮未部署时的记录，完整 OAuth/MCP 仍未通过。

承接已确认的 `specs/carry-cloud-and-ai.md` 与账户入口 spec；本次补齐公共地址和已部署新账户服务之间的传输层，不增加业务能力或授权范围。

## 路由与兼容契约

- `ACCOUNT_AI_GATEWAY_ENABLED` 必须精确为字符串 `true` 才分流。默认配置为 `false`，未启用、未部署公共切换。
- 新发现文档、`/oauth/*`、`/owner/*`、`/connections`、`/plans/*`、`/exports/*` 使用固定的 carry-dev `carry-ai` 上游。前缀匹配有路径边界，不接受客户端指定上游。
- `/mcp` 仅精确匹配既有小写 64 位十六进制 bearer 时保留原 relay。其他凭据交新服务校验；失败不回退或重试另一份数据。旧 `/register`、`/authorize`、`/token`、`/revoke`、设备路径和 Durable Object 保持原处理。
- 保留请求体、方法、query、Bearer、Origin 和 owner proof；清除 Cookie、Host、代理及转发头。固定上游不跟随重定向，响应不转发 Set-Cookie，一律 no-store，下载流不预读或整体缓冲。异常只返回脱敏 502。
- 新发现文档在启用后指向账户 OAuth。既有连接继续使用其原 token/revoke 地址和原 token；不假称旧连接自动转成账户授权。

## 已运行的验证

- Node 两轮各 30/30：包含原 relay 20 项及网关 10 项，覆盖关闭门禁、精确路由、旧 token、原 Durable Object 派发、固定上游、请求体/取消、Cookie 隔离、OAuth 重定向、私有流、失败不回退、错误 Host 和真实 owner proof 经 edge-router 后的校验。
- 本机实际转发到已部署 carry-ai：两份元数据均 200，issuer/resource 为公共 connect 地址；无凭据 MCP 返回 401 `invalid_token`。未注册客户端、上传行程或保存私人数据。
- Wrangler 实际 bundle dry-run 通过；默认门禁为 false。workerd 使用同一 bundle、全拦截 outbound 的合成验证通过：账户 token 请求体正确转发，Cookie 双向隔离，旧 Durable Object `/health` 正常，未访问真实账户或外网。
- 自行 Review 核对：请求不会同时进入新旧服务；未知 token 无旧协议回退；请求体签名在固定挂载点规范化后仍有效；回传下载不读入内存；未删除或迁移原 Durable Object。

## 仍未证明

公开域名尚未切换，网页 AI 入口仍关闭。真实网页登录与手机同账户、Codex OAuth、真实原生同步和双设备验证尚未完成。默认网关关闭是部署门禁，不能当作公开新服务已可用。
