// Fixed account backend; neither the caller nor a query parameter selects an
// upstream. Keep the original Durable Object and its existing tokens intact.
const PUBLIC_ORIGIN = "https://connect.nevestudio.app";
const UPSTREAM = "https://lbxsvguuoqqpctkinpwy.supabase.co/functions/v1/carry-ai";
const metadata = new Set([
  "/.well-known/oauth-authorization-server",
  "/.well-known/oauth-protected-resource",
  "/.well-known/oauth-protected-resource/mcp",
]);

export function usesAccountGateway(request, env) {
  if (env.ACCOUNT_AI_GATEWAY_ENABLED !== "true") return false;
  const { pathname } = new URL(request.url);
  if (pathname === "/mcp") {
    // Only the exact legacy token format can reach the old relay. New invalid
    // tokens fail at the account backend; never retry them against legacy data.
    return !/^Bearer [a-f0-9]{64}$/.test(request.headers.get("Authorization") ?? "");
  }
  return metadata.has(pathname) || ["/oauth", "/owner", "/connections", "/plans", "/exports"]
    .some(prefix => pathname === prefix || pathname.startsWith(prefix + "/"));
}

export async function forwardAccountRequest(request, fetcher = fetch) {
  const url = new URL(request.url);
  if (url.origin !== PUBLIC_ORIGIN) return new Response(null, { status: 400 });
  const headers = new Headers(request.headers);
  // Browser sessions terminate at account.nevestudio.app. The bridge supplies
  // bearer + proof; this transport must not introduce cookie authentication.
  for (const name of ["cookie", "host", "connection", "proxy-authorization",
    "forwarded", "x-forwarded-host", "x-forwarded-proto", "x-forwarded-for"])
    headers.delete(name);
  try {
    const upstream = new Request(UPSTREAM + url.pathname + url.search, {
      method: request.method, headers, body: request.body,
      redirect: "manual", signal: request.signal,
      ...(request.body ? { duplex: "half" } : {}),
    });
    const response = await fetcher(upstream);
    const resultHeaders = new Headers(response.headers);
    resultHeaders.delete("set-cookie");
    resultHeaders.set("Cache-Control", "no-store");
    // Preserve OAuth redirects and streaming responses without following them
    // with credentials or buffering private file bodies in the gateway.
    return new Response(response.body, {
      status: response.status, statusText: response.statusText, headers: resultHeaders,
    });
  } catch {
    return new Response('{"error":"account_service_unavailable"}', {
      status: 502, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  }
}
