export class AIFailure extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}
/** @returns {never} */
export const fail = (code, status = 400) => {
  throw new AIFailure(status, code);
};
export const uuid = (value) =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export const opaque = () => {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};
export const canonical = (value) =>
  Array.isArray(value)
    ? value.map(canonical)
    : value && typeof value === "object"
      ? Object.fromEntries(
          Object.keys(value)
            .sort()
            .map((k) => [k, canonical(value[k])]),
        )
      : value;
export async function hash(value) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  return [...bytes].map((x) => x.toString(16).padStart(2, "0")).join("");
}
export async function challenge(value) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}
export function object(value, allowed, required = []) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).some((k) => !allowed.includes(k)) ||
    required.some((k) => !Object.hasOwn(value, k))
  )
    fail("invalid_request");
  return value;
}
export function text(value, max = 2000) {
  if (typeof value !== "string" || value.length > max || value.includes("\0"))
    fail("invalid_request");
  return value;
}
export function identifier(value) {
  if (!uuid(value)) fail("invalid_identifier");
  return value.toLowerCase();
}
export function exactURL(raw, { loopback = false } = {}) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail("invalid_uri");
  }
  if (
    url.href !== raw ||
    url.username ||
    url.password ||
    url.hash ||
    !(
      url.protocol === "https:" ||
      (loopback &&
        url.protocol === "http:" &&
        ["127.0.0.1", "[::1]", "localhost"].includes(url.hostname))
    )
  )
    fail("invalid_uri");
  return raw;
}
export async function bytes(request, maximum = 2 * 1024 * 1024) {
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const declared = request.headers.get("Content-Length");
  if (
    declared !== null &&
    (!/^\d+$/.test(declared) || Number(declared) > maximum)
  ) {
    await reader.cancel();
    fail("body_too_large", 413);
  }
  const signal = AbortSignal.any([request.signal, AbortSignal.timeout(15000)]),
    chunks = [];
  let total = 0;
  try {
    while (true) {
      signal.throwIfAborted();
      const result = await new Promise((resolve, reject) => {
        const stop = () => reject(new AIFailure(408, "request_timeout"));
        signal.addEventListener("abort", stop, { once: true });
        reader.read().then(
          (v) => {
            signal.removeEventListener("abort", stop);
            resolve(v);
          },
          (e) => {
            signal.removeEventListener("abort", stop);
            reject(e);
          },
        );
      });
      if (result.done) break;
      total += result.value.byteLength;
      if (total > maximum) fail("body_too_large", 413);
      chunks.push(result.value);
    }
    const output = new Uint8Array(total);
    let offset = 0;
    for (const b of chunks) {
      output.set(b, offset);
      offset += b.byteLength;
    }
    return output;
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
export async function jsonBody(request, maximum) {
  if (
    request.headers.get("Content-Type")?.split(";")[0].trim() !==
    "application/json"
  )
    fail("json_required", 415);
  try {
    return JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(
        await bytes(request, maximum),
      ),
    );
  } catch (e) {
    if (e instanceof AIFailure) throw e;
    fail("invalid_json");
  }
}
export async function formBody(request, allowed, required = []) {
  if (
    request.headers.get("Content-Type")?.split(";")[0].trim() !==
    "application/x-www-form-urlencoded"
  )
    fail("form_required", 415);
  const form = new URLSearchParams(
    new TextDecoder("utf-8", { fatal: true }).decode(
      await bytes(request, 16384),
    ),
  );
  const seen = new Set();
  for (const [key] of form) {
    if (seen.has(key) || !allowed.includes(key)) fail("invalid_request");
    seen.add(key);
  }
  const body = Object.fromEntries(form);
  return object(body, allowed, required);
}
export const SCOPES = [
  "trips:read",
  "trips:write",
  "trips:create",
  "library:read",
  "library:write",
  "attachments:read",
  "attachments:write",
  "preferences:read",
  "preferences:write",
  "private:read",
  "private:write",
  "exports:read",
];
export function scopes(raw) {
  const values = typeof raw === "string" ? raw.split(" ").filter(Boolean) : raw;
  if (
    !Array.isArray(values) ||
    values.length > SCOPES.length ||
    values.some((v) => !SCOPES.includes(v)) ||
    new Set(values).size !== values.length
  )
    fail("invalid_scope");
  return [...values].sort();
}
export function has(grant, scope) {
  if (!grant.scopes.includes(scope)) fail("insufficient_scope", 403);
}
export const json = (body, status = 200, extra = {}) =>
  Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      Pragma: "no-cache",
      "X-Content-Type-Options": "nosniff",
      ...extra,
    },
  });
