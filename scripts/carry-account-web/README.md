# Carry 网页账户入口

已确认的可选账户/AI 连接方案的浏览器适配；**尚未部署，默认关闭入口，无路由**。完整生命周期、范围授权和真实原生/网页登录仍是发布门禁。这里不保存或读取旅行数据，不复制 Apple P8/数据库 service key。

## 身份与安全
- 使用官方 `@supabase/ssr` / `supabase-js` 维护会话与刷新；每请求一个独立 server client。会话只在 host-only Secure/HttpOnly/SameSite=Lax Cookie，不交给前端脚本/localStorage。
- 采用 Apple 官方 REST web flow（`code id_token` / `form_post`），与原生共享 Supabase `signInWithIdToken` 和 Carry 生命周期服务。P8 只在既有 Supabase 服务端生成五分钟 client assertion；浏览器入口不维护六个月的长效 client secret。
- 同源表单 CSRF、随机 state 与 SHA256 nonce、十分钟 AES-GCM flow Cookie 按 origin/purpose 绑定；仅该 flow Cookie 使用 SameSite=None 来承接 Apple 跨站 POST。浏览器原 Lax 会话在回调可能不出现，所以必须把发起时已核对的 account ID 写入加密 flow，防止回调换账户。
- 完成生命周期 enroll 才发布新会话 Cookie；失败/SDK 异常撤销新会话、不发布其 Cookie；已有会话刷新不因暂时服务失败丢失。名字仅为显示 metadata，无授权含义。
- 24KiB 表单、128KiB 上游响应、16KiB Cookie 及重复键拒绝；上游限定固定服务地址，超时/拒绝重定向；CSP、禁止缓存/嵌入和 referrer 输出。只允许站内 `/` 或精确 UUID 的 `/oauth/consent` 恢复路径，不接受任意 redirect。
- 九语言与原生一致。Apple 按钮使用官方 CDN 图片，提供 2x/3x 及深色白色按钮，不依赖自绘 Apple 标志或额外前端脚本。

## 外部配置（不能据此开放产品）
- 已保存 Apple Services ID `app.nevestudio.carry.web`，关联 Carry；唯一域名 `account.nevestudio.app`，回调 `https://account.nevestudio.app/auth/apple/callback`。
- 待配置：Supabase Apple provider Client IDs 添加已关联的 web ID；carry-account 服务端同样添加 web audience 和 `CARRY_APPLE_WEB_REDIRECT_URI`，部署完整生命周期适配器。现有开发 secrets 的 client IDs 仍只有原生，未擅自视为已生效。
- Worker 需要 `ACCOUNT_ORIGIN`、`SUPABASE_URL`、公开 `SUPABASE_PUBLISHABLE_KEY`、`APPLE_WEB_CLIENT_ID`、独立的 32-byte Base64URL `WEB_FLOW_ENCRYPTION_KEY`。flow key 与长期提供者凭据的 AES key 分开；不混用、不覆盖旧 key。
- `ACCOUNT_WEB_ENABLED` 仅在完整链路验收后设置为 true；当前 false。没有建立新付费服务、DNS 路由或替换现有 MCP Worker。

## 验证
Node 24+；所有依赖精确固定并有 lockfile。`npm ci --ignore-scripts`，`node --test *.test.mjs`。包含实际 Supabase SSR Cookie 持久化/读回（网络为合成），不等于真实 Apple 登录。

`wrangler deploy --dry-run --outdir /tmp/CarryAccountWebBundle` 后运行 `CARRY_WEB_QA=synthetic-only node runtime-smoke.mjs`，真实 workerd 验证页面/加密 Cookie/回调/CSRF，所有 worker 出站 IO 禁止。

`CARRY_WEB_QA=synthetic-only node preview-server.mjs` 只监听 loopback，允许 GET 登录/样式、禁止身份交换/授权/退出；输出的临时 URL 可用 CUA 截图。不是可用账户服务，也不能部署。

当前 Wrangler 附带 Miniflare 5 beta；其 file-backed loader 的内部错误已用最小模块复现，QA 通过官方兼容适配器传入同一 bundle 的内存源码，不修改产品安全校验。完整结果、失败与 Review 见 `docs/carry-account-web-qa.md`。

## 官方依据
- [Supabase Apple 登录](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- [Supabase 服务端会话](https://supabase.com/docs/guides/auth/server-side/creating-a-client)
- [Apple REST 授权](https://developer.apple.com/documentation/signinwithapplerestapi/request-an-authorization-to-the-sign-in-with-apple-server.)
- [Apple 令牌交换](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
- [Supabase OAuth 的 scope 与数据权限边界](https://supabase.com/docs/guides/auth/oauth-server/token-security)
