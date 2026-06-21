// Carry 海外地点检索代理（Cloudflare Worker · spec: itinerary-overseas-poi-search.md）
//
// 作用：代理 Mapbox Search Box（/suggest 自动补全 + /retrieve 取坐标），让大陆设备也能搜到海外
//   地点（MapKit/高德在大陆搜不到境外 POI）。App 始终只调本 Worker；本 Worker 是「控制面」。
//
// 关键设计：
//   - 藏 MAPBOX_TOKEN（secret，不进 App/git）。
//   - **只服务境外**：过滤掉 country ∈ {CN,HK,MO} 的结果——中国境内一律由高德出（合规红线）。
//   - 坐标 → IANA 时区（tz-lookup，离线），随 /retrieve 返回 → 海外地点也带时区（喂时区功能）。
//   - 运控策略 OVERSEAS_POLICY = all | cn_only | off（Cloudflare 后台即时改、零发版）。
//   - app-token 门槛 + 缓存，控成本/防盗刷（同航班 Worker 范式）。
//
// 请求：
//   GET /suggest?q=&session=&proximity=lon,lat&language=&storefront=
//   GET /retrieve?id=&session=&storefront=
//   header 可选 X-App-Token

import tzlookup from "tz-lookup";

const MAPBOX = "https://api.mapbox.com/search/searchbox/v1";
const CN_CODES = new Set(["cn", "hk", "mo"]);   // 中国大陆 + 港澳：交给高德，不走 Mapbox
const SUGGEST_TTL = 600;     // 自动补全缓存 10 分钟
const RETRIEVE_TTL = 86400;  // 选中结果缓存 1 天

export default {
  async fetch(request, env) {
    if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
    const url = new URL(request.url);

    // 按 IP 限流（可选绑定）。
    if (env.RATE_LIMITER) {
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      const { success } = await env.RATE_LIMITER.limit({ key: ip });
      if (!success) return json({ error: "rate_limited" }, 429);
    }
    // app-token 门槛。
    if (env.APP_TOKEN && request.headers.get("X-App-Token") !== env.APP_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }
    if (!env.MAPBOX_TOKEN) return json({ error: "server_misconfigured" }, 500);

    // 运控策略：off 全关；cn_only 仅大陆 storefront；all 都开。
    const policy = (env.OVERSEAS_POLICY || "all").toLowerCase();
    const storefront = (url.searchParams.get("storefront") || request.headers.get("X-Storefront") || "").toUpperCase();
    if (policy === "off") return json({ suggestions: [], disabled: true });
    if (policy === "cn_only" && storefront !== "CHN") return json({ suggestions: [], disabled: true });

    try {
      if (url.pathname === "/suggest") return await handleSuggest(url, env);
      if (url.pathname === "/retrieve") return await handleRetrieve(url, env);
    } catch (e) {
      return json({ error: "upstream_unreachable" }, 502);
    }
    return json({ error: "not_found" }, 404);
  },
};

async function handleSuggest(url, env) {
  const q = (url.searchParams.get("q") || "").trim();
  if (!q) return json({ suggestions: [] });
  const session = url.searchParams.get("session") || "carry";
  const language = url.searchParams.get("language") || "en";
  const proximity = url.searchParams.get("proximity") || "";   // "lon,lat"

  const cache = caches.default;
  const cacheKey = new Request(`https://carry-places-cache/suggest?q=${encodeURIComponent(q)}&l=${language}&p=${proximity}`);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  // 中文/日文/韩文 query → 先翻成英文再查 Mapbox（其海外 POI 基本无中文别名索引,
  // 「卢浮宫」直接查会空)。翻译走 DeepL、结果缓存,失败优雅回退原 query。显示仍按 language 本地化。
  const mapboxQ = hasCJK(q) ? ((await translateToEnglish(q, env)) || q) : q;

  const up = new URL(`${MAPBOX}/suggest`);
  up.searchParams.set("q", mapboxQ);
  up.searchParams.set("access_token", env.MAPBOX_TOKEN);
  up.searchParams.set("session_token", session);
  up.searchParams.set("language", language);
  up.searchParams.set("limit", "8");
  up.searchParams.set("types", "poi,address,place,locality,neighborhood");
  if (proximity) up.searchParams.set("proximity", proximity);

  const resp = await fetch(up.toString(), { headers: { accept: "application/json" } });
  if (!resp.ok) return json({ error: "upstream_error", status: resp.status }, 502);
  const data = await resp.json().catch(() => null);
  const list = Array.isArray(data?.suggestions) ? data.suggestions : [];

  // 过滤中国境内（已知 country 时）；返回精简结构。
  const suggestions = list
    .filter((s) => {
      const cc = s?.context?.country?.country_code?.toLowerCase();
      return !(cc && CN_CODES.has(cc));
    })
    .map((s) => ({
      id: s.mapbox_id,
      name: s.name || "",
      secondary: s.place_formatted || s.full_address || "",
    }))
    .filter((s) => s.id && s.name);

  return json({ suggestions }, 200, SUGGEST_TTL, cacheKey, cache);
}

async function handleRetrieve(url, env) {
  const id = (url.searchParams.get("id") || "").trim();
  if (!id) return json({ error: "bad_request" }, 400);
  const session = url.searchParams.get("session") || "carry";

  const cache = caches.default;
  const cacheKey = new Request(`https://carry-places-cache/retrieve?id=${encodeURIComponent(id)}`);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const up = new URL(`${MAPBOX}/retrieve/${encodeURIComponent(id)}`);
  up.searchParams.set("access_token", env.MAPBOX_TOKEN);
  up.searchParams.set("session_token", session);

  const resp = await fetch(up.toString(), { headers: { accept: "application/json" } });
  if (!resp.ok) return json({ error: "upstream_error", status: resp.status }, 502);
  const data = await resp.json().catch(() => null);
  const f = data?.features?.[0];
  if (!f) return json({ error: "not_found" }, 404);

  const coords = f.geometry?.coordinates || [];
  const lon = Number(coords[0]);
  const lat = Number(coords[1]);
  const p = f.properties || {};
  const cc = p?.context?.country?.country_code?.toLowerCase();
  // 兜底再挡一道中国境内（合规）。
  if (cc && CN_CODES.has(cc)) return json({ error: "domestic_excluded" }, 404);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return json({ error: "no_coords" }, 404);

  let timeZoneId = "";
  try { timeZoneId = tzlookup(lat, lon) || ""; } catch (_) { timeZoneId = ""; }

  const place = {
    name: p.name || "",
    latitude: lat,
    longitude: lon,
    address: p.full_address || p.place_formatted || "",
    phone: p.metadata?.phone || "",
    timeZoneId,
  };
  return json({ place }, 200, RETRIEVE_TTL, cacheKey, cache);
}

// 含中日韩文字（CJK 表意 + 假名 + 谚文）→ 视为需翻译。
function hasCJK(s) {
  return /[㐀-鿿぀-ヿ가-힯]/.test(s);
}

// 经 Azure Translator 把 query 翻成英文（源语言自动检测）。缓存 30 天控量;无 key/失败 → null（调用方回退原词)。
async function translateToEnglish(text, env) {
  if (!env.AZURE_TRANSLATOR_KEY) return null;
  const cache = caches.default;
  const ck = new Request(`https://carry-places-cache/tr?q=${encodeURIComponent(text)}`);
  const hit = await cache.match(ck);
  if (hit) { try { return (await hit.json()).t; } catch (_) { /* fallthrough */ } }

  const region = env.AZURE_TRANSLATOR_REGION || "eastasia";
  let resp;
  try {
    resp = await fetch("https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=en", {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": env.AZURE_TRANSLATOR_KEY,
        "Ocp-Apim-Subscription-Region": region,   // 区域型资源必须带,否则 401
        "Content-Type": "application/json",
      },
      body: JSON.stringify([{ Text: text }]),
    });
  } catch (_) { return null; }
  if (!resp.ok) return null;
  const data = await resp.json().catch(() => null);
  const t = data?.[0]?.translations?.[0]?.text || null;
  if (t) {
    const r = new Response(JSON.stringify({ t }), { headers: { "Cache-Control": "public, max-age=2592000" } });
    cache.put(ck, r.clone());
  }
  return t;
}

function json(body, status = 200, cacheSeconds = 0, cacheKey = null, cache = null) {
  const headers = { "Content-Type": "application/json; charset=utf-8", "Access-Control-Allow-Origin": "*" };
  if (cacheSeconds > 0) headers["Cache-Control"] = `public, max-age=${cacheSeconds}`;
  const resp = new Response(JSON.stringify(body), { status, headers });
  if (cache && cacheKey && status === 200 && cacheSeconds > 0) cache.put(cacheKey, resp.clone());
  return resp;
}
