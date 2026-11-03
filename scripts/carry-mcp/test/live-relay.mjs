// Uses synthetic trips only. Never reads a user's Carry database or prints credentials.
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { spawn } from "node:child_process";
import { isIP } from "node:net";
const base = process.argv[2] || "http://127.0.0.1:8789";
const url = new URL(base);
assert.ok(url.protocol === "https:" || url.hostname === "127.0.0.1");
let deviceToken;
let checks = 0;
async function fetchResponse(target, options) {
  if (!process.argv.includes("--curl")) return fetch(target, { ...options, signal: AbortSignal.timeout(20_000) });
  // Optional compatibility transport for the developer Mac's existing proxy.
  // Keep every credential in stdin configuration, never in process arguments/logs.
  return new Promise((resolve, reject) => {
    const address = process.argv.find(arg => arg.startsWith("--resolve-address="))?.split("=")[1];
    if (address && isIP(address) !== 4) return reject(new Error("Expected a verified IPv4 address"));
    const resolved = !address ? [] : process.argv.includes("--use-proxy")
      ? ["--connect-to", url.hostname + ":" + (url.port || 443) + ":" + address + ":" + (url.port || 443)]
      : ["--noproxy", "*", "--resolve", url.hostname + ":" + (url.port || 443) + ":" + address];
    const child = spawn("curl", ["--http1.1", "--compressed", "--silent", "--show-error", "--max-time", "20", ...resolved, "--config", "-", "--write-out", "\n%{http_code}", "--url", target], { stdio: ["pipe", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", chunk => { output += chunk; });
    child.stderr.resume();
    child.on("error", reject);
    child.on("close", code => {
      if (code !== 0) return reject(new Error("HTTPS transport failed at " + new URL(target).pathname + " (curl exit " + code + ", received " + Buffer.byteLength(output) + " bytes, complete HTML: " + output.includes("</html>") + ")"));
      const end = output.lastIndexOf("\n"), status = Number(output.slice(end + 1));
      resolve(new Response(output.slice(0, end), { status }));
    });
    const config = ["request = " + JSON.stringify(options.method),
      ...Object.entries(options.headers).map(([key, value]) => "header = " + JSON.stringify(key + ": " + value)),
      ...(options.body === undefined ? [] : ["data-binary = " + JSON.stringify(options.body)])];
    child.stdin.end(config.join("\n") + "\n");
  });
}
async function send(path, body, token, headers = {}) {
  return fetchResponse(base + path, { method: body == null ? "GET" : "POST", headers: {
    ...(body != null ? { "Content-Type": "application/json" } : {}), ...(token ? { Authorization: "Bearer " + token } : {}), ...headers,
  }, body: body == null ? undefined : typeof body === "string" ? body : JSON.stringify(body), redirect: "manual" });
}
async function call(token, name, args = {}) {
  const response = await send("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, token);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.ok(!body.result.isError, body.result.content?.[0]?.text);
  return body.result.structuredContent;
}
try {
  assert.equal((await send("/health")).status, 200); checks++;
  const meta = await (await send("/.well-known/oauth-authorization-server")).json();
  assert.equal(meta.issuer, base); checks++;
  const client = await (await send("/register", { client_name: "Carry automated acceptance (synthetic data)", redirect_uris: ["http://127.0.0.1:51234/callback"] })).json();
  assert.ok(client.client_id); checks++;
  const verifier = "qa".repeat(32), hash = await webcrypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const params = new URLSearchParams({ client_id: client.client_id, redirect_uri: "http://127.0.0.1:51234/callback", code_challenge: Buffer.from(hash).toString("base64url"), code_challenge_method: "S256", response_type: "code", state: "synthetic-state" });
  const page = await (await send("/authorize?" + params)).text();
  const code = page.match(/<code>([A-F0-9]{16})<\/code>/)?.[1];
  const flow = page.match(/'X-Flow':"([a-f0-9]+)"/)?.[1];
  assert.ok(code && flow); checks++;
  const tripId = crypto.randomUUID();
  const pairAttempt = { code, tripIds: [tripId], shareLibrary: false, connectionId: crypto.randomUUID(), deviceToken: Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex") };
  const paired = await (await send("/device/pair", pairAttempt)).json();
  deviceToken = paired.deviceToken;
  assert.ok(deviceToken); checks++;
  const recovered = await (await send("/device/pair", pairAttempt)).json();
  assert.equal(recovered.connectionId, paired.connectionId); assert.equal(recovered.deviceToken, deviceToken); checks++;
  const ready = await (await send("/authorize/status", null, null, { "X-Flow": flow })).json();
  const authCode = new URL(ready.redirect).searchParams.get("code");
  const tokens = await (await send("/token", new URLSearchParams({ grant_type: "authorization_code", client_id: client.client_id, code: authCode, code_verifier: verifier, redirect_uri: "http://127.0.0.1:51234/callback" }).toString(), null, { "Content-Type": "application/x-www-form-urlencoded" })).json();
  assert.ok(tokens.access_token); checks++;
  const snapshot = { id: tripId, name: "Synthetic Tokyo QA", destinationCity: "Tokyo", isDateless: false, departureDate: "2030-11-15", returnDate: "2030-11-20", days: [], packing: [], lodging: [], revision: "a".repeat(64), attachments: [{ secret: "must be removed" }] };
  assert.equal((await send("/device/snapshot", { trips: [snapshot] }, deviceToken)).status, 200); checks++;
  const trip = await call(tokens.access_token, "get_trip", { tripId });
  assert.equal(trip.trip.name, snapshot.name); assert.ok(!JSON.stringify(trip).includes("must be removed")); checks++;
  const requestId = crypto.randomUUID(), args = { requestId, tripId, expectedRevision: snapshot.revision, data: { name: "Synthetic rename" } };
  const [first, duplicate] = await Promise.all([call(tokens.access_token, "update_trip", args), call(tokens.access_token, "update_trip", args)]);
  assert.equal(first.entityId, duplicate.entityId); assert.equal(first.status, "queued"); checks++;
  const next = await (await send("/device/next", {}, deviceToken)).json();
  assert.equal(next.operation.requestId, requestId); assert.equal(next.operation.status, "executing"); checks++;
  const receipt = { requestId, payloadHash: next.operation.payloadHash, status: "applied", entityId: tripId, revision: "b".repeat(64) };
  assert.equal((await send("/device/receipt", receipt, deviceToken)).status, 200);
  assert.equal((await send("/device/receipt", receipt, deviceToken)).status, 200);
  assert.equal((await call(tokens.access_token, "get_operation", { requestId })).status, "applied"); checks++;
  assert.equal((await send("/device/revoke", {}, deviceToken)).status, 200);
  assert.equal((await send("/mcp", { jsonrpc: "2.0", id: 2, method: "tools/list" }, tokens.access_token)).status, 401); checks++;
  const cancellationPage = await (await send("/authorize?" + params)).text();
  const cancellationCode = cancellationPage.match(/<code>([A-F0-9]{16})<\/code>/)?.[1];
  assert.ok(cancellationCode);
  const cancelledAttempt = { code: cancellationCode, tripIds: [], connectionId: crypto.randomUUID(), deviceToken: Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex") };
  assert.equal((await send("/device/cancel-pair", cancelledAttempt)).status, 200);
  assert.equal((await send("/device/pair", cancelledAttempt)).status, 404); checks++;
  const revokePage = await (await send("/authorize?" + params)).text();
  const revokeCode = revokePage.match(/<code>([A-F0-9]{16})<\/code>/)?.[1];
  const revokeFlow = revokePage.match(/'X-Flow':"([a-f0-9]+)"/)?.[1];
  assert.ok(revokeCode && revokeFlow);
  const revokePair = await (await send("/device/pair", { code: revokeCode, tripIds: [] })).json();
  deviceToken = revokePair.deviceToken;
  const revokeReady = await (await send("/authorize/status", null, null, { "X-Flow": revokeFlow })).json();
  const revokeAuthCode = new URL(revokeReady.redirect).searchParams.get("code");
  const revokeTokens = await (await send("/token", new URLSearchParams({ grant_type: "authorization_code", client_id: client.client_id, code: revokeAuthCode, code_verifier: verifier, redirect_uri: "http://127.0.0.1:51234/callback" }).toString(), null, { "Content-Type": "application/x-www-form-urlencoded" })).json();
  assert.ok(revokeTokens.access_token);
  assert.equal((await send("/revoke", new URLSearchParams({ token: revokeTokens.access_token, client_id: client.client_id }).toString(), null, { "Content-Type": "application/x-www-form-urlencoded" })).status, 200);
  assert.equal((await send("/device/next", {}, deviceToken)).status, 401); checks++;
  console.log(`Live relay: ${checks} checks passed; synthetic connection revoked.`);
  deviceToken = undefined;
} finally {
  if (deviceToken) await send("/device/revoke", {}, deviceToken);
}
