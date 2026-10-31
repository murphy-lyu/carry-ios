import { AIFailure, fail, hash } from "./security.mjs";
import {
  assertMutationAccess,
  graphIndex,
  planContentHash,
  assertPlanPreconditions,
} from "./domain.mjs";

/** driver.transaction(fn) pins one PostgreSQL connection and commits only when
 * fn resolves. A callback failure rolls back. core methods use THAT connection:
 * no HTTP call, second pool connection, native-session forgery or async job. */
export function postgresStore({ driver, core }) {
  const required = [
    "assertOwner",
    "assertAccount",
    "ownsTrips",
    "readGraph",
    "execute",
    "prepareUndo",
  ];
  if (
    !driver?.transaction ||
    required.some((k) => typeof core?.[k] !== "function")
  )
    throw new Error("transactional_graph_core_required");
  async function transaction(fn) {
    try {
      return await driver.transaction(fn);
    } catch (e) {
      if (e instanceof AIFailure) throw e;
      fail("store_unavailable", 503);
    }
  }
  const get = async (tx, bucket, id) =>
    (
      await tx.query(
        "select value from carry_ai.records where bucket=$1 and id=$2 for update",
        [bucket, id],
      )
    ).rows[0]?.value ?? null;
  const put = async (
    tx,
    bucket,
    id,
    value,
    {
      accountID = value.accountID,
      grantID = value.grantID,
      requestID = value.requestID,
    } = {},
  ) => {
    await tx.query(
      `insert into carry_ai.records(bucket,id,account_id,grant_id,request_id,value)
      values($1,$2,$3,$4,$5,$6) on conflict(bucket,id) do update set value=excluded.value`,
      [
        bucket,
        id,
        accountID ?? null,
        grantID ?? null,
        requestID ?? null,
        value,
      ],
    );
  };
  const accountLock = async (tx, id) => {
    // The concrete shared core obtains the canonical account advisory lock,
    // which is also used by native Graph writes and account deletion.
    await core.assertAccount(tx, { accountID: id });
  };
  const owner = async (tx, p) => {
    await accountLock(tx, p.accountID);
    await core.assertOwner(tx, p);
  };
  async function grant(tx, id, now) {
    // Lookup alone is not authorization. Re-fetch after account lock to serialize
    // grant revocation, graph changes, receipt creation and first-party deletion.
    const hint = (
      await tx.query(
        "select account_id from carry_ai.records where bucket='grant' and id=$1",
        [id],
      )
    ).rows[0];
    if (!hint) fail("invalid_token", 401);
    await accountLock(tx, hint.account_id);
    const g = await get(tx, "grant", id),
      c = g && (await get(tx, "client", g.clientID));
    if (!g || !c || c.disabledAt || g.revokedAt || g.expiresAt <= now)
      fail("invalid_token", 401);
    return g;
  }
  const bindTokens = async (tx, g, tokens) => {
    const base = { accountID: g.accountID, grantID: g.id };
    await put(tx, "access", tokens.accessHash, {
      ...base,
      expiresAt: tokens.accessExpiresAt,
    });
    await put(tx, "refresh", tokens.refreshHash, {
      ...base,
      expiresAt: tokens.refreshExpiresAt,
      spent: false,
    });
  };
  const receiptID = (p) => p.grantID + ":" + p.requestID;
  async function previewForRequest(tx, p) {
    return (
      (
        await tx.query(
          "select value from carry_ai.records where bucket='preview' and grant_id=$1 and request_id=$2 for update",
          [p.grantID, p.requestID],
        )
      ).rows[0]?.value ?? null
    );
  }
  const store = {
    durability: "transactional",
    rateLimit: async (p) =>
      transaction(async (tx) => {
        // No caller-controlled header is a trusted network identity. Without a
        // verified adapter address, one shared anonymous bucket remains bounded.
        const route = [
          "/oauth/register",
          "/oauth/authorize",
          "/oauth/token",
          "/oauth/revoke",
          "/mcp",
        ].includes(p.path)
          ? p.path
          : "/other";
        const address =
          typeof p.address === "string" && p.address.length <= 128
            ? p.address
            : "anonymous";
        const key = await hash(
          JSON.stringify([
            route,
            p.accountID ?? null,
            p.grantID ?? null,
            address,
          ]),
        );
        const window = Math.floor(p.now / 60000),
          limit = p.grantID ? 240 : p.path === "/oauth/register" ? 20 : 120;
        const r = await tx.query(
          `insert into carry_ai.rate_limits(key,account_id,window_id,count) values($1,$2,$3,1)
        on conflict(key) do update set window_id=excluded.window_id,
        count=case when carry_ai.rate_limits.window_id=excluded.window_id then carry_ai.rate_limits.count+1 else 1 end returning count`,
          [key, p.accountID ?? null, window],
        );
        return r.rows[0].count <= limit;
      }),
    registerClient: (p) =>
      transaction(async (tx) => {
        if (await get(tx, "client", p.id)) fail("request_id_reused", 409);
        await put(tx, "client", p.id, p);
      }),
    getClient: (p) => transaction((tx) => get(tx, "client", p.id)),
    createAuthorization: (p) =>
      transaction(async (tx) => {
        const c = await get(tx, "client", p.clientID);
        if (!c || c.disabledAt || !c.redirectURIs.includes(p.redirectURI))
          fail("invalid_client");
        if (await get(tx, "authorization", p.id))
          fail("request_id_reused", 409);
        await put(tx, "authorization", p.id, p);
      }),
    getAuthorization: (p) =>
      transaction(async (tx) => {
        const r = await get(tx, "authorization", p.id);
        if (!r || r.consumedAt) return null;
        const c = await get(tx, "client", r.clientID);
        return c && !c.disabledAt ? { ...r, clientName: c.name } : null;
      }),
    denyAuthorization: (p) =>
      transaction(async (tx) => {
        await owner(tx, p);
        const r = await get(tx, "authorization", p.id);
        if (!r || r.consumedAt || r.expiresAt <= p.now) fail("invalid_request");
        r.consumedAt = p.now;
        await put(tx, "authorization", p.id, r);
      }),
    approveAuthorization: (p) =>
      transaction(async (tx) => {
        await owner(tx, p);
        const r = await get(tx, "authorization", p.id);
        if (!r || r.consumedAt || r.expiresAt <= p.now) fail("invalid_request");
        const c = await get(tx, "client", r.clientID);
        if (
          !c ||
          c.disabledAt ||
          p.selectedScopes.some((s) => !r.scopes.includes(s))
        )
          fail("invalid_scope");
        if (!(await core.ownsTrips(tx, p))) fail("trip_not_authorized", 403);
        const g = {
          id: p.grantID,
          accountID: p.accountID,
          clientID: r.clientID,
          resource: r.resource,
          scopes: p.selectedScopes,
          tripIDs: p.tripIDs,
          createdTripIDs: [],
          onlyCreated: p.onlyCreated,
          expiresAt: p.grantExpiresAt,
          revokedAt: null,
          createdAt: p.now,
        };
        await put(tx, "grant", g.id, g, {
          accountID: g.accountID,
          grantID: g.id,
        });
        await put(tx, "code", p.codeHash, {
          ...r,
          accountID: g.accountID,
          grantID: g.id,
          codeExpiresAt: p.codeExpiresAt,
          consumedAt: null,
        });
        r.consumedAt = p.now;
        await put(tx, "authorization", p.id, r);
      }),
    exchangeCode: (p) =>
      transaction(async (tx) => {
        // Code digest identifies its grant; grant is always locked before token to
        // match rotation/revocation lock order and avoid token/grant deadlocks.
        const hint = (
          await tx.query(
            "select value from carry_ai.records where bucket='code' and id=$1",
            [p.codeHash],
          )
        ).rows[0]?.value;
        if (!hint) fail("invalid_grant");
        const g = await grant(tx, hint.grantID, p.now),
          c = await get(tx, "code", p.codeHash);
        if (
          !c ||
          c.consumedAt ||
          c.codeExpiresAt <= p.now ||
          c.clientID !== p.clientID ||
          c.redirectURI !== p.redirectURI ||
          c.resource !== p.resource ||
          c.challenge !== p.challenge
        )
          fail("invalid_grant");
        c.consumedAt = p.now;
        await put(tx, "code", p.codeHash, c);
        await bindTokens(tx, g, p.tokens);
        return g;
      }),
    rotateRefresh: async (p) => {
      const result = await transaction(async (tx) => {
        const hint = (
          await tx.query(
            "select value from carry_ai.records where bucket='refresh' and id=$1",
            [p.refreshHash],
          )
        ).rows[0]?.value;
        if (!hint) fail("invalid_grant");
        const g = await grant(tx, hint.grantID, p.now),
          t = await get(tx, "refresh", p.refreshHash);
        if (
          !t ||
          g.clientID !== p.clientID ||
          g.resource !== p.resource ||
          t.expiresAt <= p.now
        )
          fail("invalid_grant");
        if (t.spent) {
          g.revokedAt = p.now;
          await put(tx, "grant", g.id, g);
          return { reuse: true };
        }
        t.spent = true;
        await put(tx, "refresh", p.refreshHash, t);
        await bindTokens(tx, g, p.tokens);
        return { grant: g };
      });
      // Reuse must COMMIT family revocation before returning invalid_grant.
      if (result.reuse) fail("invalid_grant");
      return result.grant;
    },
    revokeToken: async (p) => {
      try {
        return await transaction(async (tx) => {
          const hint = (
            await tx.query(
              "select value from carry_ai.records where bucket in ('access','refresh') and id=$1 limit 1",
              [p.tokenHash],
            )
          ).rows[0]?.value;
          if (!hint) return;
          const g = await grant(tx, hint.grantID, p.now);
          if (g.clientID === p.clientID) {
            g.revokedAt = p.now;
            await put(tx, "grant", g.id, g);
          }
        });
      } catch (e) {
        // Invalid/expired/deleted-account tokens receive the same public result.
        // Handle after rollback: a SQL account check may abort its transaction.
        if (
          e instanceof AIFailure &&
          ["invalid_token", "account_unavailable"].includes(e.code)
        )
          return;
        throw e;
      }
    },
    resolveAccess: (p) =>
      transaction(async (tx) => {
        const hint = (
          await tx.query(
            "select value from carry_ai.records where bucket='access' and id=$1",
            [p.tokenHash],
          )
        ).rows[0]?.value;
        if (!hint) fail("invalid_token", 401);
        const g = await grant(tx, hint.grantID, p.now),
          t = await get(tx, "access", p.tokenHash);
        if (!t || t.expiresAt <= p.now || g.resource !== p.resource)
          fail("invalid_token", 401);
        return g;
      }),
    getGrant: (p) => transaction((tx) => grant(tx, p.id, p.now)),
    listGrants: (p) =>
      transaction(async (tx) => {
        await owner(tx, p);
        return (
          await tx.query(
            "select value from carry_ai.records where bucket='grant' and account_id=$1 order by id",
            [p.accountID],
          )
        ).rows.map(({ value: g }) => ({
          id: g.id,
          clientID: g.clientID,
          scopes: g.scopes,
          tripIDs: g.tripIDs,
          onlyCreated: g.onlyCreated,
          expiresAt: g.expiresAt,
          revokedAt: g.revokedAt,
        }));
      }),
    revokeGrant: (p) =>
      transaction(async (tx) => {
        await owner(tx, p);
        const g = await get(tx, "grant", p.id);
        if (!g || g.accountID !== p.accountID) fail("not_found", 404);
        g.revokedAt = p.now;
        await put(tx, "grant", g.id, g);
      }),
    ownerTripChoices: (p) =>
      transaction(async (tx) => {
        await owner(tx, p);
        if (typeof core.tripChoices !== "function")
          fail("capability_unavailable", 503);
        return core.tripChoices(tx, p);
      }),
    readGraph: (p) =>
      transaction(async (tx) => {
        const g = await grant(tx, p.grantID, p.now);
        if (g.accountID !== p.accountID) fail("invalid_token", 401);
        return core.readGraph(tx, { ...p, grant: g });
      }),
    receipt: (p) =>
      transaction(async (tx) => {
        const g = await grant(tx, p.grantID, p.now);
        if (g.accountID !== p.accountID) fail("invalid_token", 401);
        return get(tx, "receipt", receiptID(p));
      }),
    createPreview: (p) =>
      transaction(async (tx) => {
        const g = await grant(tx, p.grantID, p.now);
        if (g.accountID !== p.accountID) fail("invalid_token", 401);
        const prior = await previewForRequest(tx, p);
        if (prior) {
          if (prior.inputHash !== p.inputHash) fail("request_id_reused", 409);
          return prior;
        }
        const v = {
          ...p,
          id: crypto.randomUUID(),
          contentHash: p.compiled.contentHash,
          approvedAt: null,
        };
        await put(tx, "preview", v.id, v);
        return v;
      }),
    getPreview: (p) =>
      transaction(async (tx) => {
        const hint = (
          await tx.query(
            "select value from carry_ai.records where bucket='preview' and id=$1",
            [p.id],
          )
        ).rows[0]?.value;
        if (
          !hint ||
          hint.accountID !== p.accountID ||
          (p.grantID && p.grantID !== hint.grantID)
        )
          return null;
        await grant(tx, hint.grantID, p.now);
        return get(tx, "preview", p.id);
      }),
    approvePreview: (p) =>
      transaction(async (tx) => {
        await owner(tx, p);
        const v = await get(tx, "preview", p.id);
        if (
          !v ||
          v.accountID !== p.accountID ||
          v.expiresAt <= p.now ||
          v.contentHash !== p.contentHash ||
          v.consumedAt
        )
          fail("invalid_preview");
        await grant(tx, v.grantID, p.now);
        v.approvedAt = p.now;
        await put(tx, "preview", p.id, v);
      }),
    execute: (p) =>
      transaction(async (tx) => {
        const g = await grant(tx, p.grantID, p.now);
        if (g.accountID !== p.accountID) fail("invalid_token", 401);
        const prior = await get(tx, "receipt", receiptID(p));
        if (prior) {
          if (prior.inputHash !== p.inputHash) fail("request_id_reused", 409);
          return prior;
        }
        const preview = await previewForRequest(tx, p);
        if (preview && p.previewID !== preview.id)
          fail("preview_required", 403);
        if (
          (p.previewID && !preview) ||
          (p.compiled.requiresApproval && !preview)
        )
          fail("preview_not_approved", 403);
        if (
          preview &&
          (!preview.approvedAt ||
            preview.expiresAt <= p.now ||
            preview.consumedAt ||
            preview.contentHash !== p.compiled.contentHash ||
            preview.inputHash !== p.inputHash)
        )
          fail("preview_not_approved", 403);
        if (
          (await planContentHash(
            p.compiled.command.mutations,
            p.compiled.preconditions,
          )) !== p.compiled.contentHash
        )
          fail("preview_changed", 409);
        if (preview) p = { ...p, compiled: preview.compiled };
        const graph = graphIndex(await core.readGraph(tx, { ...p, grant: g }));
        assertPlanPreconditions(graph, p.compiled, g);
        const created = p.compiled.command.mutations
          .filter((m) => m.action === "create" && m.kind === "trip")
          .map((m) => m.id);
        // Access is rechecked against CURRENT locked graph, not preview snapshot.
        // Core must also apply parent creation order and enforce final hierarchy.
        const checking = new Map(graph);
        for (const m of p.compiled.command.mutations) {
          assertMutationAccess(checking, m, g, created);
          if (m.action === "create")
            checking.set(m.id, { ...m, deletedAt: null });
        }
        const result = await core.execute(tx, { ...p, grant: g });
        if (
          result?.status !== "saved_to_account" ||
          result.requestID !== p.requestID ||
          !Array.isArray(result.changes)
        )
          fail("invalid_store_receipt", 503);
        const record = {
          ...result,
          accountID: g.accountID,
          grantID: g.id,
          inputHash: p.inputHash,
          createdAt: p.now,
        };
        await put(tx, "receipt", receiptID(p), record);
        g.createdTripIDs = [...new Set([...g.createdTripIDs, ...created])];
        await put(tx, "grant", g.id, g);
        if (preview) {
          preview.consumedAt = p.now;
          await put(tx, "preview", preview.id, preview);
        }
        return record;
      }),
    prepareUndo: (p) =>
      transaction(async (tx) => {
        const g = await grant(tx, p.grantID, p.now);
        if (g.accountID !== p.accountID) fail("invalid_token", 401);
        const key = receiptID(p),
          prior = await get(tx, "undo", key);
        if (prior) {
          if (prior.operationID !== p.operationID)
            fail("request_id_reused", 409);
          return prior.inverse;
        }
        const record = await get(tx, "receipt", g.id + ":" + p.operationID);
        if (!record) fail("operation_not_found", 404);
        const inverse = await core.prepareUndo(tx, { ...p, grant: g, record });
        if (!Array.isArray(inverse?.operations)) fail("undo_unavailable", 409);
        await put(tx, "undo", key, { ...p, inverse, createdAt: p.now });
        return inverse;
      }),
  };
  return store;
}
