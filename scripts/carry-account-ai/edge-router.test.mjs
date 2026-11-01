import { test } from "node:test";
import assert from "node:assert/strict";
import { routeEdgeRequest } from "./edge-router.mjs";

const origin = "https://connect-qa.invalid";
test("external and internal Supabase mounts resolve to the same resource", async () => {
  for (const prefix of ["/functions/v1/carry-ai", "/carry-ai"]) {
    const request = new Request("https://project-qa.invalid" + prefix + "/mcp?q=one", {
      method: "POST", headers: { Authorization: "Bearer synthetic", "Content-Type": "application/json" },
      body: JSON.stringify({ id: 1 }),
    });
    const response = await routeEdgeRequest(request, { origin, handler: async (normalized) => {
      assert.equal(normalized.url, origin + "/mcp?q=one");
      assert.equal(normalized.method, "POST");
      assert.equal(normalized.headers.get("Authorization"), "Bearer synthetic");
      assert.deepEqual(await normalized.json(), { id: 1 });
      return new Response("mounted");
    } });
    assert.equal(await response.text(), "mounted");
  }
});
test("canonical origin keeps the original request and both mount roots resolve", async () => {
  const original = new Request(origin + "/.well-known/oauth-authorization-server");
  routeEdgeRequest(original, { origin, handler: (request) => {
    assert.equal(request, original); return new Response();
  } });
  for (const prefix of ["/functions/v1/carry-ai", "/carry-ai"]) {
    routeEdgeRequest(new Request("https://project-qa.invalid" + prefix), { origin, handler: (request) => {
      assert.equal(request.url, origin + "/"); return new Response();
    } });
  }
});
test("unknown and sibling mounts never invoke the authenticated handler", () => {
  for (const path of ["/mcp", "/carry-ai-other/mcp", "/functions/v1/carry-ai-other/mcp", "/other/carry-ai/mcp"]) {
    const response = routeEdgeRequest(new Request("https://project-qa.invalid" + path), {
      origin, handler: () => assert.fail("unknown mount reached handler"),
    });
    assert.equal(response.status, 404);
  }
});
