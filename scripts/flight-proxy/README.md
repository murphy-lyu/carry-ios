# Carry 航班号查询代理 — 部署说明

配套 `specs/itinerary-flight-lookup.md`。这是个 **Cloudflare Worker**（免费档够用），帮 App 藏住 RapidAPI key、缓存同一航班、防盗刷。

## 一、拿 AeroDataBox 的 key（⚠️ 用 API.market，不是 RapidAPI）

> RapidAPI 上 AeroDataBox 最低商用档要 **$49.99/月**；同样的数据在 **API.market** 上 **Pro 档约 $5/月、6000 次**——便宜近 10 倍，AeroDataBox 官方也标 API.market「lowest fees」。所以走 API.market。

1. 注册/登录 [API.market 的 AeroDataBox 页](https://api.market/store/aedbx/aerodatabox)。
2. 订阅 **Pro（约 $5/月、6000 次/月，含商用许可 + 180 天未来/历史）**。（也有免费档可先验证，但商用上架建议直接 Pro）
3. 在该 API 的接口页找到 **Flight status by number** 端点，**复制示例里的完整请求地址**——形如
   `https://prod.api.market/api/v1/aedbx/aerodatabox/flights/number/{number}/{date}`。把 `/flights/number/...` **之前的那段 base** 记下来（待会儿填 `UPSTREAM_BASE`）。
4. 在账号里拿到你的 **API.market key**（用于 `x-magicapi-key` 请求头）。

## 二、部署 Worker

### 方式 A：网页控制台（最简单，无需命令行）
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/) → **Workers & Pages** → **Create** → **Create Worker**。
2. 起个名（如 `carry-flight`）→ 部署默认模板。
3. **Edit code** → 把 `worker.js` 全部内容粘进去 → **Deploy**。
4. **Settings → Variables and Secrets**：
   - 加 **Secret** `MARKET_KEY` = 你的 API.market key。
   - 加 **Variable** `UPSTREAM_BASE` = 第一部分记下的 base（例 `https://prod.api.market/api/v1/aedbx/aerodatabox`，**以你接口页为准**）。
   - （推荐）加 **Secret** `APP_TOKEN` = 自己随机生成一串（如 `openssl rand -hex 16`）——App 会带这个头，挡住陌生人盗刷。
   - （可选）加 **Variable** `CACHE_TTL_SECONDS`（默认 21600 = 6 小时）。
   - （推荐）**限流绑定**：**Settings → Bindings → Add → Rate limiting**，变量名填 `RATE_LIMITER`，
     设 limit/period（如 **20 次 / 60 秒**，period 仅支持 10 或 60）。按 IP 限流挡脚本盗刷；
     不加则不限流（代码会优雅跳过）。这是比 APP_TOKEN 更实在的防刷防线。
5. 记下你的 Worker URL，如 `https://carry-flight.<你的子域>.workers.dev`。

### 方式 B：wrangler（命令行）
```bash
npm i -g wrangler
wrangler login
# 在本目录放一个 wrangler.toml（name/main=worker.js/compatibility_date）
wrangler secret put MARKET_KEY        # 粘贴 API.market key
wrangler secret put APP_TOKEN         # 粘贴自定 token（可选）
# UPSTREAM_BASE 在 wrangler.toml 的 [vars] 里写，或用 dashboard 加
wrangler deploy
```

## 三、自测

```bash
curl "https://<你的worker>.workers.dev/flight?number=MU5101&date=2026-07-01" \
  -H "X-App-Token: <你的APP_TOKEN>"
```
- 有数据 → 返回 `{ "flights": [ ... ] }`。
- 查不到 → `{ "flights": [] }`（App 据此回退手动）。
- 缺参/越权 → 4xx。

## 四、回填进 App（给 Claude）

把这两个给我，我把 App 侧接上并验证：
1. **Worker URL**（如 `https://carry-flight.xxx.workers.dev`）——公开、无敏感，会作为 App 内常量。
2. **APP_TOKEN**（若设了）——会内嵌进 App（可被提取，但配合月额度上限 + 可随时在 Worker 改 token 轮换，足够起步）。

> ⚠️ API.market key（`MARKET_KEY`）**永远只在 Worker 的 secret 里**，绝不进 App、绝不进 git。
