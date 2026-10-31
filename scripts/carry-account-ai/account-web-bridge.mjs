import { ownerProofHeaders } from "./owner-proof.mjs";
import { bytes, fail, exactURL } from "./security.mjs";

/** Mount ONLY inside createWebHandler after checkedSession, and for POST after
 * checkForm. Browser cookies, caller authorization headers and arbitrary target
 * URLs are never forwarded. The account website never receives a DB/service key.
 */
export function createAccountWebAIBridge({
  origin,
  accountOrigin,
  secret,
  fetcher = fetch,
  now = Date.now,
}) {
  exactURL(origin + "/");
  exactURL(accountOrigin + "/");
  const thisAccountOrigin = new URL(accountOrigin).origin;
  if (thisAccountOrigin !== accountOrigin)
    throw new Error("invalid_account_origin");
  if (new URL(origin).origin !== origin) throw new Error("invalid_ai_origin");
  return async ({ session, path, method = "GET", body }) => {
    if (
      !/^Bearer [A-Za-z0-9_.-]+$/.test("Bearer " + session?.access_token) ||
      !session?.user?.id
    )
      fail("unauthorized", 401);
    // The browser cannot choose OAuth token/revoke/MCP endpoints through this
    // first-party proxy, nor a remote host, query fragment or encoded path escape.
    const tripChoices =
      /^\/owner\/trips(?:\?(?:q=[^&]*&)?offset=\d+&limit=\d+)?$/.test(path);
    if (
      !tripChoices &&
      !/^(?:\/oauth\/requests\/[0-9a-f-]{36}|\/plans\/[0-9a-f-]{36}(?:\/approve)?|\/connections(?:\/[0-9a-f-]{36}\/revoke)?)$/.test(
        path,
      )
    )
      fail("invalid_owner_route");
    if (!["GET", "POST"].includes(method)) fail("invalid_owner_route");
    const request = new Request(origin + path, {
      method,
      headers: {
        Authorization: "Bearer " + session.access_token,
        Origin: new URL(origin).origin,
        "Content-Type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    // The API requires the account site's Origin; caller supplies only the
    // configured account origin through this factory's immutable construction.
    request.headers.set("Origin", thisAccountOrigin);
    for (const [k, v] of Object.entries(
      await ownerProofHeaders(request, secret, now()),
    ))
      request.headers.set(k, v);
    const response = await fetcher(request, {
      redirect: "manual",
      signal: AbortSignal.timeout(15000),
    });
    if (response.status === 303) {
      // Only OAuth approval/denial is allowed to yield a client redirect. The AI
      // handler selects it from the originally registered immutable request.
      if (!/^\/oauth\/requests\//.test(path) || method !== "POST")
        fail("invalid_owner_response", 503);
      const location = response.headers.get("Location");
      if (!location || location.length > 4096)
        fail("invalid_owner_response", 503);
      return { status: 303, location };
    }
    let data;
    try {
      data = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(
          await bytes(
            new Request("https://bridge.invalid", {
              method: "POST",
              body: response.body,
              duplex: "half",
            }),
            2 * 1024 * 1024,
          ),
        ),
      );
    } catch {
      fail("invalid_owner_response", 503);
    }
    if (!response.ok)
      fail(
        typeof data.error === "string" && /^[a-z_]{1,64}$/.test(data.error)
          ? data.error
          : "owner_service_unavailable",
        response.status >= 500 ? 503 : response.status,
      );
    return { status: response.status, data };
  };
}
