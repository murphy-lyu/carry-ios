import { previewActions } from "./web-preview.mjs";
import { aiWebStrings, scopeLabels } from "./web-strings.mjs";
import {
  htmlEscape as esc,
  WebFailure,
  boundedBytes,
} from "../carry-account-web/security.mjs";
const uuid = (value) =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const hidden = (name, value) =>
  `<input type="hidden" name="${name}" value="${esc(value)}">`;
async function form(request, allowed, repeated = []) {
  if (
    request.headers.get("Content-Type")?.split(";")[0].trim() !==
    "application/x-www-form-urlencoded"
  )
    throw new WebFailure(415, "form_required");
  const f = new URLSearchParams(
      new TextDecoder("utf-8", { fatal: true }).decode(
        await boundedBytes(request.body, 24000),
      ),
    ),
    seen = new Set();
  for (const [k] of f) {
    if (!allowed.includes(k) || (seen.has(k) && !repeated.includes(k)))
      throw new WebFailure(400, "invalid_form");
    seen.add(k);
  }
  return f;
}
/** Called inside account-web with checked SDK cookies. No public identity
 * headers or DB key are accepted here. A null result means route not handled. */
export async function accountAIPage({
  request,
  checkedSession,
  formToken,
  checkForm,
  bridge,
  headers,
  text,
  htmlPage,
  finish,
}) {
  const url = new URL(request.url),
    path = url.pathname,
    t = aiWebStrings[text.lang] ?? aiWebStrings.en;
  const consent = path === "/oauth/consent",
    plan = /^\/ai\/plans\/([0-9a-f-]{36})$/.exec(path),
    connections = path === "/connections",
    revoke = /^\/connections\/([0-9a-f-]{36})\/revoke$/.exec(path);
  if (!consent && !plan && !connections && !revoke) return null;
  const querySeen = new Set();
  for (const [key] of url.searchParams) {
    if (
      !consent ||
      !["authorization_id", "q"].includes(key) ||
      querySeen.has(key)
    )
      throw new WebFailure(400, "invalid_request");
    querySeen.add(key);
  }
  if (!["GET", "POST"].includes(request.method))
    throw new WebFailure(405, "method_not_allowed");
  const current = await checkedSession();
  if (!current) {
    headers.set(
      "Location",
      "/login?continue=" + encodeURIComponent(path + url.search),
    );
    return finish(new Response(null, { status: 303, headers }));
  }
  const call = async (options) => {
    try {
      return await bridge({ session: current.session, ...options });
    } catch (e) {
      throw new WebFailure(e.status ?? 503, e.code ?? "ai_service_unavailable");
    }
  };
  const page = (title, content) =>
    finish(
      htmlPage(
        text,
        title,
        `<p>${esc(current.user.email ?? "Carry")}</p>${content}`,
        headers,
      ),
    );
  if (consent) {
    const id = url.searchParams.get("authorization_id");
    if (!uuid(id)) throw new WebFailure(400, "invalid_authorization");
    if (request.method === "POST") {
      const f = await form(
        request,
        ["csrf", "decision", "scopes", "tripIDs", "onlyCreated"],
        ["scopes", "tripIDs"],
      );
      await checkForm(f, current.user.id);
      const decision = f.get("decision");
      if (!["approve", "deny"].includes(decision))
        throw new WebFailure(400, "invalid_decision");
      const result = await call({
        path: "/oauth/requests/" + id,
        method: "POST",
        body: {
          csrf: f.get("csrf"),
          decision,
          ...(decision === "approve"
            ? {
                scopes: f.getAll("scopes"),
                tripIDs:
                  f.get("onlyCreated") === "true" ? [] : f.getAll("tripIDs"),
                onlyCreated: f.get("onlyCreated") === "true",
              }
            : {}),
        },
      });
      if (result.status !== 303)
        throw new WebFailure(503, "invalid_owner_response");
      headers.set("Location", result.location);
      return finish(new Response(null, { status: 303, headers }));
    }
    const r = (await call({ path: "/oauth/requests/" + id })).data,
      csrf = await formToken(current.user.id),
      q = url.searchParams.get("q") ?? "";
    if (q.length > 200) throw new WebFailure(400, "invalid_search");
    const choices = (
      await call({
        path:
          "/owner/trips?" +
          new URLSearchParams({ q, offset: "0", limit: "500" }),
      })
    ).data;
    const permissions = r.requestedScopes
      .map(
        (scope) =>
          `<label><input type="checkbox" name="scopes" value="${esc(scope)}" ${scope === "trips:read" ? "checked" : ""}> ${esc(t[scopeLabels[scope]] ?? scope)}</label><br>`,
      )
      .join("");
    const trips = choices.trips
      .map(
        (trip) =>
          `<label><input type="checkbox" name="tripIDs" value="${esc(trip.id)}"> ${esc(trip.name)}</label><br>`,
      )
      .join("");
    return page(
      t.connect,
      `<dl><dt>${esc(t.client)}</dt><dd>${esc(r.client.name)}<br><code>${esc(r.client.id)}</code></dd><dt>${esc(t.destination)}</dt><dd><code>${esc(r.client.redirectURI)}</code></dd></dl><p>${esc(t.unverified)}</p><form method="get">${hidden("authorization_id", id)}<label>${esc(t.search)} <input type="search" name="q" value="${esc(q)}"></label><button class="text-button">${esc(t.search)}</button></form><form method="post">${hidden("csrf", csrf)}<fieldset><legend>${esc(t.permissions)}</legend>${permissions}</fieldset><label><input type="checkbox" name="onlyCreated" value="true" checked> ${esc(t.newOnly)}</label><fieldset><legend>${esc(t.trips)}</legend>${trips}${choices.hasMore ? `<p>${esc(t.more)}</p>` : ""}</fieldset><button class="text-button" name="decision" value="approve">${esc(t.approve)}</button> <button class="text-button" name="decision" value="deny">${esc(t.deny)}</button></form>`,
    );
  }
  if (plan) {
    const id = plan[1];
    if (!uuid(id)) throw new WebFailure(400, "invalid_preview");
    if (request.method === "POST") {
      const f = await form(request, ["csrf", "contentHash"]);
      await checkForm(f, current.user.id);
      await call({
        path: "/plans/" + id + "/approve",
        method: "POST",
        body: { csrf: f.get("csrf"), contentHash: f.get("contentHash") },
      });
      return page(t.review, `<p role="status">${esc(t.done)}</p>`);
    }
    const r = (await call({ path: "/plans/" + id })).data,
      csrf = await formToken(current.user.id);
    const actions = previewActions(r.summary, text.lang, t);
    return page(
      t.review,
      `<ol>${actions}</ol><form method="post">${hidden("csrf", csrf)}${hidden("contentHash", r.contentHash)}<button class="text-button">${esc(t.approve)}</button></form>`,
    );
  }
  if (revoke) {
    if (request.method !== "POST" || !uuid(revoke[1]))
      throw new WebFailure(405, "method_not_allowed");
    const f = await form(request, ["csrf"]);
    await checkForm(f, current.user.id);
    await call({ path, method: "POST", body: { csrf: f.get("csrf") } });
    headers.set("Location", "/connections");
    return finish(new Response(null, { status: 303, headers }));
  }
  if (request.method !== "GET") throw new WebFailure(405, "method_not_allowed");
  const r = (await call({ path: "/connections" })).data,
    csrf = await formToken(current.user.id);
  return page(
    t.connections,
    r.connections.length
      ? `<ul>${r.connections.map((g) => `<li><p>${esc(g.clientID ?? g.id)}</p><p>${g.scopes.map((s) => esc(t[scopeLabels[s]] ?? s)).join(" · ")}</p>${g.revokedAt ? "" : `<form method="post" action="/connections/${esc(g.id)}/revoke">${hidden("csrf", csrf)}<button class="text-button">${esc(t.revoke)}</button></form>`}</li>`).join("")}</ul>`
      : `<p>${esc(t.empty)}</p>`,
  );
}
