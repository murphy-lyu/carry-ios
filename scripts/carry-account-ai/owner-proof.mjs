import { fail, hash, opaque, bytes } from "./security.mjs";
const encode = (value) => new TextEncoder().encode(value);
const base64 = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
function decode(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value))
    fail("invalid_owner_proof", 403);
  try {
    return Uint8Array.from(
      atob(value.replaceAll("-", "+").replaceAll("_", "/") + "="),
      (c) => c.charCodeAt(0),
    );
  } catch {
    fail("invalid_owner_proof", 403);
  }
}
async function key(secret) {
  const bytes = decode(secret);
  if (bytes.length !== 32) fail("invalid_owner_configuration", 503);
  return crypto.subtle.importKey(
    "raw",
    bytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}
async function payload(request, timestamp, nonce) {
  const token = request.headers.get("Authorization");
  if (!token?.startsWith("Bearer ") || token.length > 16384)
    fail("unauthorized", 401);
  const body = await bytes(request.clone(), 65536);
  if (body.byteLength > 65536) fail("body_too_large", 413);
  const digest = base64(await crypto.subtle.digest("SHA-256", body));
  return encode(
    JSON.stringify([
      request.method,
      request.url,
      request.headers.get("Origin"),
      await hash(token),
      digest,
      timestamp,
      nonce,
    ]),
  );
}
/** Called only after the account site's own same-origin form CSRF check. The
 * shared bridge secret stays in account-web and AI server env, never HTML/JS. */
export async function ownerProofHeaders(request, secret, now = Date.now()) {
  const timestamp = String(now),
    nonce = opaque(),
    data = await payload(request, timestamp, nonce);
  return {
    "X-Carry-Owner-Time": timestamp,
    "X-Carry-Owner-Nonce": nonce,
    "X-Carry-Owner-Proof": base64(
      await crypto.subtle.sign("HMAC", await key(secret), data),
    ),
  };
}
export async function verifyOwnerProof(request, secret, now = Date.now()) {
  const timestamp = request.headers.get("X-Carry-Owner-Time"),
    nonce = request.headers.get("X-Carry-Owner-Nonce"),
    proof = request.headers.get("X-Carry-Owner-Proof");
  if (
    !/^\d{10,16}$/.test(timestamp ?? "") ||
    Math.abs(Number(timestamp) - now) > 30000 ||
    !/^[A-Za-z0-9_-]{43}$/.test(nonce ?? "")
  )
    fail("invalid_owner_proof", 403);
  if (
    !(await crypto.subtle.verify(
      "HMAC",
      await key(secret),
      decode(proof),
      await payload(request, timestamp, nonce),
    ))
  )
    fail("invalid_owner_proof", 403);
}
