// Carry 航班号查询代理（Cloudflare Worker）
// spec: specs/itinerary-flight-lookup.md
//
// 作用：App 不直接持有航空数据 API 的 key，改调本 Worker；
//   Worker 持 key（secret，不进 App/git）→ 转发到 AeroDataBox
//   → 服务端缓存同一「航班号+日期」→ 降本 + 防 key 泄露。
//
// 上游地址/鉴权做成「环境变量可配」——RapidAPI / API.market 都能用，换市场只改变量。
//
// 请求：GET https://<your-worker>/flight?number=MU5101&date=2026-07-01
//   - number: 航班号（去空格大写由 Worker 处理）   - date: YYYY-MM-DD
//   - 可选 header  X-App-Token: <APP_TOKEN>（防陌生人盗刷额度）
//
// 需在 Worker 配置：
//   - MARKET_KEY     （必填 secret）你的航空 API key
//   - UPSTREAM_BASE  （变量）上游根地址
//   - KEY_HEADER     （变量）鉴权头名：RapidAPI 用 x-rapidapi-key；API.market 用 x-magicapi-key
//   - UPSTREAM_HOST  （可选变量）设了就额外发 x-rapidapi-host 头（RapidAPI 需要；API.market 留空）
//   - APP_TOKEN      （可选 secret）App 内嵌共享口令；设了就强校验
//   - CACHE_TTL_SECONDS（可选变量，默认 21600 = 6h）
//   - RATE_LIMITER   （可选 Rate Limiting 绑定）按 IP 限流挡脚本盗刷；dashboard
//                     Settings → Bindings 加「Rate limiting」绑定，名 RATE_LIMITER，
//                     设 limit/period（如 20 次 / 60s）。不配则不限流（优雅跳过）。

const DEFAULT_BASE = "https://prod.api.market/api/v1/aedbx/aerodatabox";
const DEFAULT_KEY_HEADER = "x-magicapi-key";

export default {
  async fetch(request, env) {
    if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
    const url = new URL(request.url);
    if (url.pathname !== "/flight") return json({ error: "not_found" }, 404);

    // 可选：按 IP 限流（挡脚本盗刷上游额度）。limit/period 在 RATE_LIMITER 绑定里配；
    // 放在口令校验前 → 连带挡住「拿错口令狂试」。未配绑定则跳过。
    if (env.RATE_LIMITER) {
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      const { success } = await env.RATE_LIMITER.limit({ key: ip });
      if (!success) return json({ error: "rate_limited" }, 429);
    }

    if (env.APP_TOKEN && request.headers.get("X-App-Token") !== env.APP_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }

    const number = (url.searchParams.get("number") || "").trim().toUpperCase().replace(/\s+/g, "");
    const date = (url.searchParams.get("date") || "").trim();
    if (!number || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(date)) {
      return json({ error: "bad_request", detail: "need number & date=YYYY-MM-DD" }, 400);
    }
    if (!env.MARKET_KEY) return json({ error: "server_misconfigured" }, 500);

    const cache = caches.default;
    const cacheKey = new Request(`https://carry-flight-cache/${number}/${date}`, request);
    const cached = await cache.match(cacheKey);
    if (cached) return cached;

    const base = (env.UPSTREAM_BASE || DEFAULT_BASE).replace(/\/$/, "");
    const keyHeader = env.KEY_HEADER || DEFAULT_KEY_HEADER;
    const upstream = `${base}/flights/number/${encodeURIComponent(number)}/${date}`;

    const headers = { [keyHeader]: env.MARKET_KEY, accept: "application/json" };
    if (env.UPSTREAM_HOST) headers["x-rapidapi-host"] = env.UPSTREAM_HOST;

    let resp;
    try {
      resp = await fetch(upstream, { headers });
    } catch (e) {
      return json({ error: "upstream_unreachable" }, 502);
    }

    if (resp.status === 204 || resp.status === 404) {
      return json({ flights: [] }, 200, ttl(env), cacheKey, cache);
    }
    if (!resp.ok) return json({ error: "upstream_error", status: resp.status }, 502);

    const data = await resp.json().catch(() => null);
    if (data == null) return json({ error: "bad_upstream_body" }, 502);

    const flights = Array.isArray(data) ? data : [data];
    return json({ flights }, 200, ttl(env), cacheKey, cache);
  },
};

function ttl(env) {
  const n = parseInt(env.CACHE_TTL_SECONDS || "", 10);
  return Number.isFinite(n) && n > 0 ? n : 21600;
}

function json(body, status = 200, cacheSeconds = 0, cacheKey = null, cache = null) {
  const headers = { "Content-Type": "application/json; charset=utf-8", "Access-Control-Allow-Origin": "*" };
  if (cacheSeconds > 0) headers["Cache-Control"] = `public, max-age=${cacheSeconds}`;
  const resp = new Response(JSON.stringify(body), { status, headers });
  if (cache && cacheKey && status === 200 && cacheSeconds > 0) cache.put(cacheKey, resp.clone());
  return resp;
}
