// Supabase invokes functions at /<function-name>/* internally, while callers
// address /functions/v1/<function-name>/*. Accept only these fixed mounts.
export function routeEdgeRequest(request, { origin, handler }) {
  const url = new URL(request.url);
  if (url.origin === origin) return handler(request);
  const prefix = ["/functions/v1/carry-ai", "/carry-ai"].find(
    (value) => url.pathname === value || url.pathname.startsWith(value + "/"),
  );
  if (!prefix) return new Response(null, { status: 404 });
  const path = url.pathname.slice(prefix.length) || "/";
  return handler(new Request(origin + path + url.search, request));
}
