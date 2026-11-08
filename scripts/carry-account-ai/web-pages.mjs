import { experienceStrings } from "./experience-strings.mjs";
import { exportWebStrings } from "./export-web-strings.mjs";
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
export function consentFormPolicy(policy, redirectURI) {
  const target = new URL(redirectURI);
  // The owner bridge already checked the exact registered callback. Only its
  // origin belongs in CSP; never interpolate raw client metadata/directives.
  if (!(target.protocol === "https:" || (target.protocol === "http:" &&
      ["127.0.0.1", "localhost", "[::1]"].includes(target.hostname))) ||
      target.username || target.password ||
      !/^https?:\/\/(?:[a-z0-9.-]+|\[[a-f0-9:]+\])(?::[0-9]+)?$/i.test(target.origin))
    throw new WebFailure(503, "invalid_owner_response");
  return policy.replace(/form-action ([^;]+);/, (_, sources) =>
    `form-action ${sources} ${target.origin};`);
}
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
  now = Date.now,
}) {
  const url = new URL(request.url),
    path = url.pathname,
    t = aiWebStrings[text.lang] ?? aiWebStrings.en,
    ux = experienceStrings[text.lang] ?? experienceStrings.en;
  const consent = path === "/oauth/consent",
    plan = /^\/ai\/plans\/([0-9a-f-]{36})$/.exec(path),
    connections = path === "/connections",
    exportRoute = /^\/ai\/exports\/([0-9a-f-]{36})(?:\/(download))?$/.exec(path),
    revoke = /^\/connections\/([0-9a-f-]{36})\/revoke$/.exec(path);
  if (!consent && !plan && !connections && !revoke && !exportRoute) return null;
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
    // Resume the review rather than starting a download or repeating a POST
    // immediately after sign-in. Search is optional and can be re-entered.
    const next = consent && uuid(url.searchParams.get("authorization_id"))
      ? "/oauth/consent?authorization_id=" + url.searchParams.get("authorization_id")
      : plan && uuid(plan[1]) ? path
      : exportRoute && uuid(exportRoute[1]) ? "/ai/exports/" + exportRoute[1]
      : "/connections";
    headers.set("Location", "/login?continue=" + encodeURIComponent(next));
    return finish(new Response(null, { status: 303, headers }));
  }
  const call = async (options) => {
    try {
      return await bridge({ session: current.session, ...options });
    } catch (e) {
      throw new WebFailure(e.status ?? 503, e.code ?? "ai_service_unavailable");
    }
  };
  const page = (title, content, layout = "standard") =>
    finish(
      htmlPage(
        text,
        title,
        `<p class="account-id">${esc(current.user.email ?? "Carry")}</p>${content}`,
        headers,
        200,
        layout,
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
      headers.set("Content-Security-Policy", consentFormPolicy(
        headers.get("Content-Security-Policy"), result.location));
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
          `<label class="choice"><input type="checkbox" name="scopes" value="${esc(scope)}" ${scope === "trips:read" ? "checked" : ""}> <span>${esc(t[scopeLabels[scope]] ?? scope)}</span></label>`,
      )
      .join("");
    const trips = choices.trips
      .map(
        (trip) =>
          `<label class="choice"><input type="checkbox" name="tripIDs" value="${esc(trip.id)}"> <span>${esc(trip.name)}</span></label>`,
      )
      .join("");
    // Chromium checks form-action again at the POST's external 303 destination.
    // Permit only this verified client's callback origin on its consent page.
    headers.set("Content-Security-Policy", consentFormPolicy(
      headers.get("Content-Security-Policy"), r.client.redirectURI));
    const redirectHost = new URL(r.client.redirectURI).host;
    return page(t.connect, `
      <div class="consent-layout"><section class="panel client-panel">
        <h2>${esc(r.client.name)}</h2>
        <p class="muted">${esc(t.destination)} · ${esc(redirectHost)}</p>
        <p>${esc(t.unverified)}</p>
        <details><summary>${esc(ux.diagnostics)}</summary>
          <dl><dt>${esc(t.client)}</dt><dd><code>${esc(r.client.id)}</code></dd>
          <dt>${esc(t.destination)}</dt><dd><code>${esc(r.client.redirectURI)}</code></dd></dl>
        </details>
      </section>
      <form id="trip-search" class="search" method="get">
        ${hidden("authorization_id", id)}
      </form>
      <form method="post">
        ${hidden("csrf", csrf)}
        <fieldset><legend>${esc(t.permissions)}</legend>
          <p class="muted">${esc(ux.scopeHint)}</p>${permissions}
        </fieldset>
        <fieldset class="scope-options"><legend>${esc(t.trips)}</legend>
          <label class="choice"><input type="checkbox" name="onlyCreated" value="true" ${choices.trips.length || q ? "" : "checked"}> <span>${esc(t.newOnly)}</span></label>
          <div class="trip-options">
            <p class="muted">${esc(ux.existingHint)}</p>
            ${choices.hasMore || q ? `<div class="search">
              <label>${esc(t.search)} <input form="trip-search" type="search" name="q" value="${esc(q)}" maxlength="200"></label>
              <button class="button text-button" form="trip-search">${esc(t.search)}</button>
            </div>` : ""}
            ${trips}
            ${choices.hasMore ? `<p class="muted">${esc(t.more)}</p>` : ""}
          </div>
        </fieldset>
        <div class="actions">
          <button class="button primary" name="decision" value="approve">${esc(ux.connectAction)}</button>
          <button class="button text-button" name="decision" value="deny">${esc(t.deny)}</button>
        </div>
      </form></div>`);
  }
  if (exportRoute) {
    const id = exportRoute[1];
    const e = exportWebStrings[text.lang] ?? exportWebStrings.en;
    if (!uuid(id)) throw new WebFailure(400, "invalid_export");
    if (exportRoute[2] === "download") {
      if (request.method !== "GET") throw new WebFailure(405, "method_not_allowed");
      const result = await call({ path: "/exports/" + id + "/download", signal: request.signal });
      if (result.status !== 200 || !result.body) throw new WebFailure(503, "invalid_export_response");
      headers.set("Content-Type", "application/json; charset=utf-8");
      headers.set("Content-Disposition", `attachment; filename="${result.fileName}"`);
      return finish(new Response(result.body, { headers }));
    }
    if (request.method === "POST") {
      const f = await form(request, ["csrf", "contentHash"]);
      await checkForm(f, current.user.id);
      await call({ path: "/exports/" + id + "/approve", method: "POST", body: {
        csrf: f.get("csrf"), contentHash: f.get("contentHash"),
      } });
      headers.set("Location", "/ai/exports/" + id);
      return finish(new Response(null, { status: 303, headers }));
    }
    const record = (await call({ path: "/exports/" + id })).data;
    const s = record.summary;
    if (!s || typeof s.name !== "string" || !Number.isSafeInteger(s.entityCount) ||
        !Number.isSafeInteger(s.fileCount) || !Number.isSafeInteger(s.byteCount))
      throw new WebFailure(503, "invalid_export_response");
    const formatCount = new Intl.NumberFormat(text.lang);
    const size = (bytes) => {
      const [unit, divisor] = bytes >= 1e6 ? ["megabyte", 1e6]
        : bytes >= 1e3 ? ["kilobyte", 1e3] : ["byte", 1];
      return new Intl.NumberFormat(text.lang, {
        style: "unit", unit, unitDisplay: "short", maximumFractionDigits: 1,
      }).format(bytes / divisor);
    };
    const includes = [s.containsPrivateFields ? e.private : null,
      s.containsOriginalPhotos ? e.originals : null,
      s.containsPackingList ? e.packing : null].filter(Boolean);
    const content = Array.isArray(s.contents) ? s.contents : [];
    const files = Array.isArray(s.files) ? s.files : [];
    const subtitle = [s.destinationCity, s.departureDate].filter(Boolean).join(" · ");
    const details = `<section class="panel">
      <h2>${esc(s.name)}</h2>${subtitle ? `<p class="muted">${esc(subtitle)}</p>` : ""}
      <dl class="metrics">
        <div><dt>${esc(e.items)}</dt><dd>${formatCount.format(s.entityCount)}</dd></div>
        <div><dt>${esc(e.files)}</dt><dd>${formatCount.format(s.fileCount)}</dd></div>
        <div><dt>${esc(e.size)}</dt><dd>${esc(size(s.byteCount))}</dd></div>
      </dl>
      ${includes.length ? `<ul class="notice">${includes.map(item => `<li>${esc(item)}</li>`).join("")}</ul>` : ""}
      ${content.length ? `<details><summary>${esc(e.items)} (${content.length}/${s.entityCount})</summary>
        <ol>${content.map(item => `<li>${esc(item)}</li>`).join("")}</ol></details>` : ""}
      ${files.length ? `<details><summary>${esc(e.files)} (${files.length}/${s.fileCount})</summary>
        <ul>${files.map(file => `<li>${esc(file.name)} · ${esc(size(file.byteCount))}</li>`).join("")}</ul></details>` : ""}
      </section>`;
    const expiry = Number.isFinite(record.expiresAt)
      ? `<time class="muted" datetime="${new Date(record.expiresAt).toISOString()}">${esc(ux.expiredAt)} · ${esc(new Intl.DateTimeFormat(text.lang, {
          dateStyle: "medium", timeStyle: "short", timeZone: "UTC",
        }).format(record.expiresAt))} UTC</time>`
      : "";
    if (record.approvedAt) return page(e.title, `
      <p class="notice" role="status">${esc(e.approved)}</p><p>${expiry}</p>
      <a class="button primary" href="/ai/exports/${esc(id)}/download">${esc(e.download)}</a>
      ${details}`);
    const csrf = await formToken(current.user.id);
    return page(e.title, `<p class="lead">${esc(e.detail)}</p><p>${expiry}</p>${details}
      <form class="actions" method="post">${hidden("csrf", csrf)}${hidden("contentHash", record.contentHash)}
      <button class="button primary">${esc(e.approve)}</button></form>`);
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
      return page(ux.approvedTitle, `<p class="notice" role="status">${esc(t.done)}</p>`, "focus");
    }
    const r = (await call({ path: "/plans/" + id })).data,
      csrf = await formToken(current.user.id);
    const actions = previewActions(r.summary, text.lang, t);
    return page(
      t.review,
      `<ol class="stack">${actions}</ol><form class="actions" method="post">
      ${hidden("csrf", csrf)}${hidden("contentHash", r.contentHash)}
      <button class="button primary">${esc(ux.approveChanges)}</button></form>`,
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
  const guide = `<a class="button ${r.connections.length ? "text-button" : "primary"}" href="/ai/guide">${esc(ux.guide)}</a>`;
  if (!r.connections.length) return page(t.connections, `
    <section class="panel"><h2>${esc(t.empty)}</h2><p>${esc(ux.intro)}</p>${guide}</section>`);
  const grants = r.connections.map((g) => {
    const expired = Number.isFinite(g.expiresAt) && g.expiresAt <= now();
    const status = g.revokedAt ? ux.revoked : expired ? ux.expired : ux.active;
    const name = g.clientName || `${t.client} · ${g.id.slice(-6)}`;
    const count = Array.isArray(g.tripIDs) ? new Intl.NumberFormat(text.lang).format(g.tripIDs.length) : null;
    const range = g.onlyCreated ? t.newOnly : count === null ? "" : `${ux.selectedTrips} · ${count}`;
    return `<li class="panel">
      <p class="status">${esc(status)}</p><h2>${esc(name)}</h2>
      <p>${g.scopes.map((s) => esc(t[scopeLabels[s]] ?? s)).join(" · ")}</p>
      ${range ? `<p class="muted">${esc(range)}</p>` : ""}
      <details><summary>${esc(ux.diagnostics)}</summary><code>${esc(g.clientID ?? g.id)}</code></details>
      ${g.revokedAt || expired ? "" : `<form method="post" action="/connections/${esc(g.id)}/revoke">
        ${hidden("csrf", csrf)}<button class="button text-button">${esc(t.revoke)}</button></form>`}
    </li>`;
  }).join("");
  return page(t.connections, `<ul class="stack">${grants}</ul><div class="actions">${guide}</div>`);
}
