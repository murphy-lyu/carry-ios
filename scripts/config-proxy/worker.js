// Carry 远程配置代发（Cloudflare Worker）
//
// 作用：把 carry-ios 仓库里的静态配置（目前只有 roadmap.json）经自营域名
//   config.nevestudio.app 发出来，让中国大陆无 VPN 也能拉到。
//   raw.githubusercontent.com 在大陆被 GFW 阻断；本 Worker 回源 + 缓存——
//   回源那一跳发生在 Cloudflare 边缘（墙外），不受影响；客户端只连 config.nevestudio.app。
//
// 真源永远在 carry-ios 仓库（roadmap.json 不搬家、不在这里存内容）。本 Worker 只是「代发 + 缓存」。
//
// 请求：GET https://config.nevestudio.app/roadmap.json
//   - 仅放行白名单路径（见 ALLOWED），避免被当成开放代理。
//
// 部署：见同目录 README.md。绑自定义域名 config.nevestudio.app。

const SOURCE_BASE = "https://raw.githubusercontent.com/murphy-lyu/carry-ios/main";

// 白名单：只代发这些文件，其余 404（防止被滥用成通用 GitHub 代理）。
const ALLOWED = new Set(["/roadmap.json"]);

// 缓存时长：与 raw CDN 量级一致。改 roadmap 后 push，最多 CACHE_TTL_SECONDS 生效。
const CACHE_TTL_SECONDS = 300; // 5 分钟

export default {
  async fetch(request) {
    if (request.method !== "GET") {
      return json({ error: "method_not_allowed" }, 405);
    }
    const url = new URL(request.url);
    if (!ALLOWED.has(url.pathname)) {
      return json({ error: "not_found" }, 404);
    }

    const cache = caches.default;
    const cacheKey = new Request(`https://carry-config-cache${url.pathname}`, request);
    const cached = await cache.match(cacheKey);
    if (cached) return cached;

    let upstream;
    try {
      upstream = await fetch(`${SOURCE_BASE}${url.pathname}`, {
        cf: { cacheTtl: CACHE_TTL_SECONDS },
      });
    } catch (e) {
      return json({ error: "upstream_unreachable" }, 502);
    }
    if (!upstream.ok) {
      return json({ error: "upstream_error", status: upstream.status }, 502);
    }

    const body = await upstream.text();
    const resp = new Response(body, {
      status: 200,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": `public, max-age=${CACHE_TTL_SECONDS}`,
        "Access-Control-Allow-Origin": "*",
      },
    });
    await cache.put(cacheKey, resp.clone());
    return resp;
  },
};

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
