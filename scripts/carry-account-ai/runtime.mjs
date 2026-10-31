import { createAccountAIHandler } from "./worker.mjs";
import { createAccountQueries } from "./queries.mjs";
import { createAccountAssets } from "./assets.mjs";
import { postgresStore } from "./postgres-store.mjs";
import { postgresDriver } from "./postgres-driver.mjs";
import { postgresGraphCore } from "./postgres-graph-core.mjs";
import { verifyOwnerProof } from "./owner-proof.mjs";
import { createGraphAdapter } from "../carry-account-service/graph-adapter.mjs";
import { AIFailure, fail } from "./security.mjs";

/** Real runtime: transactionally durable SQL + Auth-verified Apple identity.
 * Only owner endpoints receive first-party cookies' bearer through the signed
 * account-web proxy. Public MCP bearer is never interpreted as a native JWT. */
export function createAccountAIRuntime({
  pool,
  jose,
  configuration,
  fetcher = fetch,
  queries = null,
  trustedAddress = () => null,
  now = Date.now,
}) {
  const { origin, accountOrigin, projectURL, serviceKey, ownerBridgeSecret } =
    configuration;
  if (!ownerBridgeSecret) throw new Error("missing_owner_bridge_secret");
  const driver = postgresDriver(pool, { role: "service_role" }),
    core = postgresGraphCore(),
    store = postgresStore({
      driver,
      core,
      assets: createAccountAssets({ projectURL, serviceKey, fetcher }),
    });
  const identity = createGraphAdapter({
    configuration: { projectURL, serviceKey },
    jose,
    fetcher,
  });
  const firstParty = {
    authenticate: async (request) => {
      await verifyOwnerProof(request, ownerBridgeSecret, now());
      const bearer = request.headers
        .get("Authorization")
        ?.replace(/^Bearer /, "");
      let session;
      try {
        session = await identity.authenticate(bearer);
      } catch (e) {
        if (e.status === 401) fail("unauthorized", 401);
        fail("identity_unavailable", 503);
      }
      try {
        await driver.transaction(async (tx) => {
          await core.assertAccount(tx, session);
          await core.assertOwner(tx, session);
        });
      } catch (e) {
        if (e instanceof AIFailure) throw e;
        fail("identity_unavailable", 503);
      }
      return session;
    },
    verifyCSRF: (request) =>
      verifyOwnerProof(request, ownerBridgeSecret, now()),
  };
  return createAccountAIHandler({
    store,
    firstParty,
    origin,
    accountOrigin,
    queries:
      queries ??
      createAccountQueries({
        fetcher,
        configuration: configuration.queries ?? {},
      }),
    trustedAddress,
    now,
  });
}
