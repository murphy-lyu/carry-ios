// Carry 航班号查询代理（Cloudflare Worker）
// spec: specs/itinerary-flight-lookup.md
//
// 作用：App 不直接持有航空数据 API 的 key，改调本 Worker；
//   Worker 持 key（secret，不进 App/git）→ 转发到 AeroDataBox
//   → 服务端缓存同一「航班号+日期」→ 降本 + 防 key 泄露。
//
// ✅ 默认对接 API.market（AeroDataBox 在此约 $5/月、6000 次，比 RapidAPI 便宜近 10 倍）。
//    上游地址/鉴权做成「环境变量可配」——你从 API.market 的接口示例里复制确切 base 填进去即可，
//    将来想换 RapidAPI 也只改变量、不改代码。
//
// 请求：GET https://<your-worker>/flight?number=MU5101&date=2026-07-01
//   - number: 航班号（去空格大写由 Worker 处理）   - date: YYYY-MM-DD
//   - 可选 header  X-App-Token: <APP_TOKEN>（防陌生人盗刷额度）
//
// 需在 Worker 配置：
//   - MARKET_KEY        （必填 secret）你的 API.market key（x-magicapi-key 的值）
//   - UPSTREAM_BASE      （变量，默认 API.market 的 AeroDataBox 根地址，见下）
//                         例：https://prod.api.market/api/v1/aedbx/aerodatabox
//                         （以你 API.market 接口页显示的为准，复制粘贴最稳）
//   - KEY_HEADER         （变量，默认 x-magicapi-key；用 RapidAPI 时改 x-rapidapi-key）
//   - UPSTREAM_HOST      （可选变量）设了就额外发 x-rapidapi-host 头——RapidAPI 需要它，
//                         值 = aerodatabox.p.rapidapi.com；API.market 不用，留空即可。
//   - APP_TOKEN          （可选 secret）App 内嵌共享口令；设了就强校验
//   - CACHE_TTL_SECONDS  （可选变量，默认 21600 = 6h）

const DEFAULT_BASE = "https://prod.api.market/api/v1/aedbx/aerodatabox";
const DEFAULT_KEY_HEADER = "x-magicapi-key";

export default {
  async fetch(request, env) {
    if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
    const url = new URL(request.url);
    if (url.pathname !== "/flight") return json({ error: "not_found" }, 404);

    // 可选：App 口令校验
    if (env.APP_TOKEN && request.headers.get("X-App-Token") !== env.APP_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }

    const number = (url.searchParams.get("number") || "").trim().toUpperCase().replace(/\s+/g, "");
    const date = (url.searchParams.get("date") || "").trim();
    if (!number || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(date)) {
      return json({ error: "bad_request", detail: "need number & date=YYYY-MM-DD" }, 400);
    }
    if (!env.MARKET_KEY) return json({ error: "server_misconfigured" }, 500);

    // 服务端缓存：同一「航班号+日期」复用，省额度。
    const cache = caches.default;
    const cacheKey = new Request(`https://carry-flight-cache/${number}/${date}`, request);
    const cached = await cache.match(cacheKey);
    if (cached) return cached;

    const base = (env.UPSTREAM_BASE || DEFAULT_BASE).replace(/\/$/, "");
    const keyHeader = env.KEY_HEADER || DEFAULT_KEY_HEADER;
    const upstream = `${base}/flights/number/${encodeURIComponent(number)}/${date}`;

    const headers = { [keyHeader]: env.MARKET_KEY, accept: "application/json" };
    if (env.UPSTREAM_HOST) headers["x-rapidapi-host"] = env.UPSTREAM_HOST; // RapidAPI 需要；API.market 不用

    let resp;
    try {
      resp = await fetch(upstream, { headers });
    } catch (e) {
      return json({ error: "upstream_unreachable" }, 502);
    }

    if (resp.status === 204 || resp.status === 404) {
      // 没查到这趟 → 统一空，App 据此回退手动。
      return json({ flights: [] }, 200, ttl(env), cacheKey, cache);
    }
    if (!resp.ok) return json({ error: "upstream_error", status: resp.status }, 502);

    const data = await resp.json().catch(() => null);
    if (data == null) return json({ error: "bad_upstream_body" }, 502);

    // 上游返回航班数组（或单对象）；统一包成 { flights: [...] } 透传，由 App 侧解析映射。
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
