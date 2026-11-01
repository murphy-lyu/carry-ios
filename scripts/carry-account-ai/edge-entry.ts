import pg from "npm:pg@8.16.3";
import * as jose from "npm:jose@6.1.3";
import { createAccountAIRuntime } from "./runtime.mjs";
import { routeEdgeRequest } from "./edge-router.mjs";
function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error("missing_configuration");
  return value;
}
const origin = required("CARRY_AI_ORIGIN");
// Hosting an artifact must not silently open the new account protocol. Enable
// only after hosted identity, migration and storage acceptance is complete.
const handler = Deno.env.get("ACCOUNT_AI_ENABLED") === "true" ? createAccountAIRuntime({
  pool: new pg.Pool({
    // A dedicated pool URL can override the platform's server-only connection.
    // Neither connection string is sent to clients or copied to the web worker.
    connectionString: Deno.env.get("CARRY_AI_DATABASE_URL") || required("SUPABASE_DB_URL"),
    max: 2,
    ssl: { rejectUnauthorized: true },
  }),
  jose,
  configuration: {
    origin,
    accountOrigin: required("ACCOUNT_ORIGIN"),
    projectURL: required("SUPABASE_URL"),
    serviceKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    ownerBridgeSecret: required("CARRY_OWNER_BRIDGE_SECRET"),
    queries: {
      flightToken: Deno.env.get("CARRY_FLIGHT_APP_TOKEN"),
      placesToken: Deno.env.get("CARRY_PLACES_APP_TOKEN"),
      amapKey: Deno.env.get("CARRY_AMAP_WEB_KEY"),
    },
  },
}) : (_request: Request) => new Response(JSON.stringify({ error: "account_ai_disabled" }), {
  status: 503,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});
// Functions platform JWT verification must be false for OAuth metadata/code
// exchange and opaque MCP bearer. This handler verifies OAuth and owner proofs.
// Deploy behind connect.nevestudio.app; do not trust incoming identity headers.
Deno.serve((request) => routeEdgeRequest(request, { origin, handler }));
