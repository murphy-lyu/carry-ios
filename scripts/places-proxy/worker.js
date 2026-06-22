// Carry 海外地点检索代理（Cloudflare Worker · spec: itinerary-overseas-poi-search.md）
//
// 作用：代理 Mapbox Search Box（/suggest 自动补全 + /retrieve 取坐标），让大陆设备也能搜到海外
//   地点（MapKit/高德在大陆搜不到境外 POI）。App 始终只调本 Worker；本 Worker 是「控制面」。
//
// 关键设计：
//   - 藏 MAPBOX_TOKEN / GEOAPIFY_KEY（secret，不进 App/git）。
//   - **多源 + 自动降级**：SEARCH_PROVIDER = mapbox | geoapify | auto（默认 auto：Mapbox 主、
//     Geoapify 备，主源硬失败才降级）。换源只改云控变量、App 不动（Worker 是咽喉，防单点）。
//   - **只服务境外**：过滤掉 country ∈ {CN,HK,MO} 的结果——中国境内一律由高德出（合规红线）。
//     红线两道防线：country code（alpha-2/3）+ 坐标 IANA 时区落在境内（沪/乌/港/澳）也挡（见 complianceCheck，
//     用时区而非粗 bbox：精准且堵 ga: id 伪造 cc 的漏洞）。
//   - 坐标 → IANA 时区（tz-lookup，离线），随 /retrieve 返回 → 海外地点也带时区（喂时区功能）。
//   - 运控策略 OVERSEAS_POLICY = all | cn_only | off（Cloudflare 后台即时改、零发版）。
//   - app-token 门槛（常量时间比较）+ 缓存，控成本/防盗刷（同航班 Worker 范式）。
//   - suggest 结果 id 带 provider 前缀（mb:/ga:），/retrieve 据此路由回正确来源。
//
// 请求：
//   GET /suggest?q=&session=&proximity=lon,lat&storefront=   （结果一律 language=en，见下）
//   GET /retrieve?id=&session=&storefront=                   （id 带 mb:/ga: 前缀，路由回来源 provider）
//   header 可选 X-App-Token

import tzlookup from "tz-lookup";

const MAPBOX = "https://api.mapbox.com/search/searchbox/v1";
const CN_CODES = new Set(["cn", "hk", "mo"]);        // 中国大陆 + 港澳（ISO alpha-2）：交给高德，不走 Mapbox
const CN_CODES3 = new Set(["chn", "hkg", "mac"]);    // 同上 alpha-3（Mapbox 字段命名随版本而异，两套都认）
const SUGGEST_TTL = 600;     // 自动补全缓存 10 分钟
const RETRIEVE_TTL = 86400;  // 选中结果缓存 1 天
const MAX_QUERY_LEN = 200;   // query 长度上限：截断超长输入，防刷 Azure/Mapbox 成本

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
    // app-token 门槛（常量时间比较：避免逐字节短路带来的计时旁路，防慢速爆破 token）。
    if (env.APP_TOKEN && !safeEqual(request.headers.get("X-App-Token") || "", env.APP_TOKEN)) {
      return json({ error: "unauthorized" }, 401);
    }
    // 不在这里全局强求 MAPBOX_TOKEN：纯 geoapify 模式（Mapbox 挂了切备源）不需要它。
    //   各 provider 函数各自检查自己的 token（mapboxSuggest 抛错 → auto 模式自动降级到 Geoapify）。

    // 运控策略：off 全关；cn_only 仅大陆 storefront；all 都开。
    // 注意：storefront 由 App 端按真实 StoreKit storefront 注入，理论上客户端可伪造 → 它只是
    //   「是否提供海外搜索」的成本/运控开关，**不是合规边界**。真正的合规红线（境内一律走高德）
    //   由下面 handleSuggest/handleRetrieve 里**无条件**的 CN 过滤保证，与 storefront/policy 无关。
    //   不用 request.cf.country 反查 storefront：旅行 App 用户常人在境外但 storefront=CHN，反查会误杀真实用户。
    const policy = (env.OVERSEAS_POLICY || "all").toLowerCase();
    const storefront = (url.searchParams.get("storefront") || request.headers.get("X-Storefront") || "").toUpperCase();
    const disabled = policy === "off" || (policy === "cn_only" && storefront !== "CHN");
    if (disabled) {
      // 按 path 返回对应空形状：/retrieve 客户端解码的是 {place}，给 {disabled:true}（无 place → 优雅回退 nil，
      //   不会把 suggest 的形状塞给 retrieve 调用方而坏掉选择流程）。
      return url.pathname === "/retrieve"
        ? json({ disabled: true })
        : json({ suggestions: [], disabled: true });
    }

    try {
      if (url.pathname === "/suggest") return await handleSuggest(url, env);
      if (url.pathname === "/retrieve") return await handleRetrieve(url, env);
    } catch (e) {
      return json({ error: "upstream_unreachable" }, 502);
    }
    return json({ error: "not_found" }, 404);
  },
};

// 选哪个源：mapbox（仅主）| geoapify（仅备）| auto（默认：Mapbox 主、Geoapify 自动降级）。
// 降级仅在主源**硬失败**（异常/非 200）时发生；主源「正常返回空」不算失败、不降级（那是真没结果）。
function providerPlan(env) {
  const p = (env.SEARCH_PROVIDER || "auto").toLowerCase();
  if (p === "mapbox") return { primary: "mapbox", fallback: null };
  if (p === "geoapify") return { primary: "geoapify", fallback: null };
  return { primary: "mapbox", fallback: env.GEOAPIFY_KEY ? "geoapify" : null };
}

async function handleSuggest(url, env) {
  let q = (url.searchParams.get("q") || "").trim();
  if (!q) return json({ suggestions: [] });
  if (q.length > MAX_QUERY_LEN) q = q.slice(0, MAX_QUERY_LEN);   // 截断超长 query（防滥用/控成本）
  const session = url.searchParams.get("session") || "carry";   // 仅 Mapbox 用（按 session 计费）
  const proximity = url.searchParams.get("proximity") || "";    // "lon,lat"
  // 目的地「城市模式」：只查行政地名（国家/地区/城市），不掺 POI/门牌——给「建行程·目的地」字段用，
  // 让「Tokyo→东京市」成首条、清掉同名餐厅噪音。缺省（AddStop 的地点检索）仍走全量 POI。
  const placeMode = (url.searchParams.get("kinds") || "").toLowerCase() === "place";
  const cjk = hasCJK(q);
  // 城市模式下按用户 UI 语言做本地化检索：拉丁文本地异名（München/Roma/Lisboa/Wien）在 language=en 下
  // 匹配不到正确城市（撞同名小镇/落空）；用 language=<UI 语言> 让 Mapbox 按该语言索引命中城市本体。
  // 但 CJK query 已翻成英文（见下），用 en 检索拿到干净英文城市名——避免 Mapbox 对 ja/ko 回传冗余的全层级
  // 本地名（如「日本東京都東京都」）。故 searchLang 只对「城市模式 + 非 CJK」取 UI 语言，其余一律 en。
  // 仅 place 模式生效；POI 模式（AddStop）行为不变（仍 en）。
  const searchLang = (placeMode && !cjk) ? (url.searchParams.get("lang") || "").trim() : "";
  const plan = providerPlan(env);

  const cache = caches.default;
  // 缓存键含 provider + kinds + lang：id 体系不同不能串用；城市/POI 结果不同须分桶；不同 UI 语言的本地化结果也不同。
  const cacheKey = new Request(`https://carry-places-cache/suggest?q=${encodeURIComponent(q)}&prov=${plan.primary}&p=${proximity}&k=${placeMode ? "place" : ""}&l=${encodeURIComponent(searchLang)}`);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  // 中日韩 query → 先翻成英文再查（海外 POI 基本无中文别名索引,「卢浮宫」直接查会空)。两源都吃英文 query。
  // 翻译走 Azure、结果缓存,失败优雅回退原 query。一律用 language=en：实测 zh 会把排序带歪（偏行政区划）。
  const queryEn = cjk ? ((await translateToEnglish(q, env)) || q) : q;

  // 主源硬失败才降级到备源；备源也失败 → 抛给上层（502）。
  let suggestions, usedFallback = false;
  try {
    suggestions = await suggestVia(plan.primary, queryEn, { proximity, session, env, placeMode, uiLang: searchLang });
  } catch (e) {
    if (!plan.fallback) throw e;
    usedFallback = true;
    suggestions = await suggestVia(plan.fallback, queryEn, { proximity, session, env, placeMode, uiLang: searchLang });
  }
  // 降级结果**不缓存**：否则主源短暂抖动后，会拿备源结果顶满 10 分钟 TTL（主源恢复了还在吐备源）。
  return usedFallback
    ? json({ suggestions })
    : json({ suggestions }, 200, SUGGEST_TTL, cacheKey, cache);
}

// 按 provider 取补全结果（统一返回 [{id, name, secondary}]，id 带 provider 前缀供 /retrieve 路由）。硬失败抛错以触发降级。
async function suggestVia(provider, q, opts) {
  if (provider === "geoapify") return geoapifySuggest(q, opts);
  return mapboxSuggest(q, opts);
}

// UI 语言 → Mapbox language code（白名单，未知/空回退 en）。pt-BR→pt；中文区分简繁。
function mapboxLangOf(ui) {
  const m = { en: "en", de: "de", es: "es", fr: "fr", ja: "ja", ko: "ko",
              "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "pt-BR": "pt", pt: "pt" };
  return m[ui] || "en";
}

async function mapboxSuggest(q, { proximity, session, env, placeMode, uiLang }) {
  if (!env.MAPBOX_TOKEN) throw new Error("mapbox_no_token");
  const up = new URL(`${MAPBOX}/suggest`);
  up.searchParams.set("q", q);
  up.searchParams.set("access_token", env.MAPBOX_TOKEN);
  up.searchParams.set("session_token", session);
  // 城市模式按 UI 语言检索（命中本地异名城市）；POI 模式保持 en。
  up.searchParams.set("language", placeMode ? mapboxLangOf(uiLang) : "en");
  up.searchParams.set("limit", "8");
  // 城市模式只留行政地名（place=城市/镇、locality=聚落、region=省州、district、country）；
  // 默认模式（地点检索）含 poi/address。
  up.searchParams.set("types", placeMode ? "country,region,district,place,locality" : "poi,address,place,locality,neighborhood");
  if (proximity) up.searchParams.set("proximity", proximity);

  const resp = await fetch(up.toString(), { headers: { accept: "application/json" } });
  if (!resp.ok) throw new Error("mapbox_suggest_" + resp.status);   // 抛错 → 触发降级
  const data = await resp.json().catch(() => null);
  const list = Array.isArray(data?.suggestions) ? data.suggestions : [];
  // 过滤中国境内（已知 country 时）。suggest 拿不到坐标，只能按 country code 挡；漏网的境内点由 /retrieve 时区判定兜底。
  return list
    .filter((s) => !isChinaCountry(countryCodeOf(s)))
    .map((s) => ({
      id: "mb:" + s.mapbox_id,
      name: s.name || "",
      secondary: s.place_formatted || s.full_address || "",
    }))
    .filter((s) => s.id !== "mb:undefined" && s.name);
}

// Geoapify 自动补全：单次调用即带坐标 → 把名称/地址/坐标/国家码塞进 id（base64url），
//   /retrieve 时离线解出、本地算时区，不再二次请求 Geoapify（更省额度、更稳）。
// UI 语言 → Geoapify lang code（2 字母，中文统一 zh；未知/空回退 en）。
function geoapifyLangOf(ui) {
  const m = { en: "en", de: "de", es: "es", fr: "fr", ja: "ja", ko: "ko",
              "zh-Hans": "zh", "zh-Hant": "zh", "pt-BR": "pt", pt: "pt" };
  return m[ui] || "en";
}

// 城市模式保留的 Geoapify result_type（行政地名层级）：对齐 Mapbox 的 country/region/district/place/locality，
// 去掉 street/amenity/building/postcode/unknown 等非「目的地城市」结果。
const GEOAPIFY_PLACE_TYPES = new Set(["country", "state", "county", "city", "district", "suburb"]);

async function geoapifySuggest(q, { proximity, env, placeMode, uiLang }) {
  if (!env.GEOAPIFY_KEY) throw new Error("geoapify_no_key");
  const up = new URL("https://api.geoapify.com/v1/geocode/autocomplete");
  up.searchParams.set("text", q);
  up.searchParams.set("apiKey", env.GEOAPIFY_KEY);
  // 城市模式按 UI 语言（命中本地异名）；POI 模式保持 en。
  up.searchParams.set("lang", placeMode ? geoapifyLangOf(uiLang) : "en");
  // 城市模式多取几条，给下面的 result_type 后过滤留余量（过滤掉街道/POI 后仍有足够城市候选）。
  up.searchParams.set("limit", placeMode ? "12" : "8");
  up.searchParams.set("format", "geojson");
  // 城市模式**不**在查询端限 type：Geoapify 只支持单一 type，取 city 会丢「省/州/国」目的地。
  // 改为按响应里每条的 result_type 后过滤行政地名（见 GEOAPIFY_PLACE_TYPES），既覆盖城市+省州+国、
  // 又去掉街道/POI——比单一 type=city 更全更准。
  if (proximity) {
    const [lon, lat] = proximity.split(",");
    if (lon && lat) up.searchParams.set("bias", `proximity:${lon},${lat}`);
  }
  const resp = await fetch(up.toString(), { headers: { accept: "application/json" } });
  if (!resp.ok) throw new Error("geoapify_suggest_" + resp.status);   // 抛错 → 触发降级（或上层 502）
  const data = await resp.json().catch(() => null);
  const feats = Array.isArray(data?.features) ? data.features : [];
  return feats
    .map((f) => {
      const p = f.properties || {};
      const coords = f.geometry?.coordinates || [];
      const lon = Number(coords[0] ?? p.lon);
      const lat = Number(coords[1] ?? p.lat);
      const cc = (p.country_code || "").toLowerCase();
      const name = p.name || p.address_line1 || p.formatted || "";
      const secondary = p.address_line2 || (p.name ? p.formatted : "") || "";
      return { name, secondary, lon, lat, cc, formatted: p.formatted || "", rt: p.result_type || "" };
    })
    .filter((r) => {
      if (!r.name || !Number.isFinite(r.lat) || !Number.isFinite(r.lon)) return false;
      if (isChinaCountry(r.cc)) return false;
      if (isChinaTimeZone(zoneOf(r.lat, r.lon))) return false;   // 坐标时区在境内 → 不展示（合规；cc 缺失也挡）
      if (placeMode && !GEOAPIFY_PLACE_TYPES.has(r.rt)) return false;   // 城市模式只留行政地名，去街道/POI/邮编
      return true;
    })
    .map((r) => ({
      id: "ga:" + b64urlEncode(JSON.stringify({ n: r.name, a: r.secondary || r.formatted, lat: r.lat, lon: r.lon, cc: r.cc })),
      name: r.name,
      secondary: r.secondary,
    }));
}

async function handleRetrieve(url, env) {
  const rawId = (url.searchParams.get("id") || "").trim();
  if (!rawId) return json({ error: "bad_request" }, 400);
  const session = url.searchParams.get("session") || "carry";

  const cache = caches.default;
  const cacheKey = new Request(`https://carry-places-cache/retrieve?id=${encodeURIComponent(rawId)}`);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  // 按 id 前缀路由到来源 provider（前缀由 suggest 写入）；无前缀的旧式 id 默认按 Mapbox。
  let place;
  if (rawId.startsWith("ga:")) {
    place = geoapifyRetrievePlace(rawId.slice(3));
  } else {
    const mbId = rawId.startsWith("mb:") ? rawId.slice(3) : rawId;
    place = await mapboxRetrievePlace(mbId, session, env);
  }
  if (place.error) return json({ error: place.error }, place.status || 404);
  return json({ place: place.value }, 200, RETRIEVE_TTL, cacheKey, cache);
}

async function mapboxRetrievePlace(id, session, env) {
  if (!env.MAPBOX_TOKEN) return { error: "server_misconfigured", status: 500 };
  const up = new URL(`${MAPBOX}/retrieve/${encodeURIComponent(id)}`);
  up.searchParams.set("access_token", env.MAPBOX_TOKEN);
  up.searchParams.set("session_token", session);

  const resp = await fetch(up.toString(), { headers: { accept: "application/json" } });
  if (!resp.ok) return { error: "upstream_error", status: 502 };
  const data = await resp.json().catch(() => null);
  const f = data?.features?.[0];
  if (!f) return { error: "not_found", status: 404 };

  const coords = f.geometry?.coordinates || [];
  const lon = Number(coords[0]);
  const lat = Number(coords[1]);
  const p = f.properties || {};
  const check = complianceCheck(lat, lon, countryCodeOf(p));
  if (check.error) return check;
  return {
    value: {
      name: p.name || "",
      latitude: lat,
      longitude: lon,
      address: p.full_address || p.place_formatted || "",
      phone: p.metadata?.phone || "",
      timeZoneId: check.timeZoneId,
      // 权威 ISO 国家码（alpha-2，大写）：客户端选中即写入 trip.countryCode 点亮地图，
      // 免去事后从自由文本反解析（语言相关、有歧义）。countryCodeOf 优先取 alpha-2。
      country: (countryCodeOf(p) || "").toUpperCase(),
    },
  };
}

// Geoapify 离线解析：id 里已含名称/地址/坐标/国家码，本地解出 + 算时区，零二次请求。
function geoapifyRetrievePlace(token) {
  let obj;
  try { obj = JSON.parse(b64urlDecode(token)); } catch (_) { return { error: "bad_id", status: 404 }; }
  const lat = Number(obj.lat);
  const lon = Number(obj.lon);
  // 注意：cc 来自客户端可控的 id，故 complianceCheck 不只信 cc，还按坐标时区判定（堵伪造）。
  const check = complianceCheck(lat, lon, (obj.cc || "").toLowerCase());
  if (check.error) return check;
  return {
    value: {
      name: obj.n || "",
      latitude: lat,
      longitude: lon,
      address: obj.a || "",
      phone: "",
      timeZoneId: check.timeZoneId,
      // 同 Mapbox 路径：回传权威 ISO 国家码（alpha-2，大写）供客户端直接点亮地图。
      // obj.cc 为 Geoapify country_code（alpha-2）；合规校验已用其小写形判境内。
      country: (obj.cc || "").toUpperCase(),
    },
  };
}

// 合规红线（境内一律走高德）+ 坐标有效性，两源共用。顺带把时区算出来回传（避免重复 tz-lookup）。
//   返回 { error, status }（应拦截）或 { timeZoneId }（放行）。三道：
//   ① 无效坐标挡；② country code 命中 CN/HK/MO 挡；
//   ③ **不信任可伪造的 cc**——坐标的 IANA 时区落在中国境内（沪/乌鲁木齐/港/澳）也挡。
//   ③ 用时区而非粗 bbox：精准（首尔→Asia/Seoul 放行、台北→Asia/Taipei 放行、北京→Asia/Shanghai 挡，
//   哪怕 ga: id 把 cc 伪造成 jp），既堵 ga: id 伪造漏洞、又不误杀矩形内的境外旅行目的地。
function complianceCheck(lat, lon, cc) {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return { error: "no_coords", status: 404 };
  if (isChinaCountry(cc)) return { error: "domestic_excluded", status: 404 };
  const timeZoneId = zoneOf(lat, lon);
  if (isChinaTimeZone(timeZoneId)) return { error: "domestic_excluded", status: 404 };
  return { timeZoneId };
}

// 中国大陆 + 港澳的 IANA 时区（含历史别名）——境内地理判定，比 country code 可信（坐标无法伪造其所在时区）。
const CN_TIMEZONES = new Set([
  "Asia/Shanghai", "Asia/Urumqi", "Asia/Hong_Kong", "Asia/Macau",
  "Asia/Harbin", "Asia/Chongqing", "Asia/Chungking", "Asia/Kashgar",   // 历史别名（多已 link 到沪/乌鲁木齐）
]);
function isChinaTimeZone(tz) {
  return !!tz && CN_TIMEZONES.has(tz);
}

function zoneOf(lat, lon) {
  try { return tzlookup(lat, lon) || ""; } catch (_) { return ""; }
}

// 常量时间字符串比较（基于运行时 crypto.subtle.timingSafeEqual，要求等长 buffer）。
function safeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(a), bb = enc.encode(b);
  if (ab.byteLength !== bb.byteLength) return false;   // 长度差异本就会泄露，属可接受
  return crypto.subtle.timingSafeEqual(ab, bb);
}

// 从 Mapbox 结果对象提取 country code（兼容多种字段命名：context.country 下 alpha-2 / alpha-3，及顶层备用字段）。
function countryCodeOf(obj) {
  const c = obj?.context?.country;
  return (c?.country_code || c?.country_code_alpha_3 || obj?.country_code || "").toLowerCase();
}

// country code 是否属中国大陆 / 港澳（alpha-2 或 alpha-3）。
function isChinaCountry(cc) {
  return !!cc && (CN_CODES.has(cc) || CN_CODES3.has(cc));
}

// base64url 编/解码（Geoapify 把 retrieve 所需数据塞进 id，避免二次请求）。走 TextEncoder/Decoder 兼容非 ASCII（重音地址等）。
function b64urlEncode(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlDecode(b64) {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(bytes);
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
  // cache.match/json 抖动也不该让整条 suggest 502 → 兜底回退（caller 用原文 query 继续）。
  try {
    const hit = await cache.match(ck);
    if (hit) { try { return (await hit.json()).t; } catch (_) { /* fallthrough */ } }
  } catch (_) { /* 缓存读失败：忽略，继续走在线翻译 */ }

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
