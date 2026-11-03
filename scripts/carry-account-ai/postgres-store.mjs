import { assetReferences, exportFingerprint, prepareBackup, streamBackup, backupSerializedByteCount } from "./exports.mjs";
import { AIFailure, fail, hash, has, canonical } from "./security.mjs";
import {
  assertMutationAccess,
  graphIndex,
  planContentHash,
  assertPlanPreconditions,
  authorizeEntity,
  rootOf,
} from "./domain.mjs";

/** driver.transaction(fn) pins one PostgreSQL connection and commits only when
 * fn resolves. A callback failure rolls back. core methods use THAT connection:
 * no HTTP call, second pool connection, native-session forgery or async job. */
export const clientRegistryCapacity = Object.freeze({ maximumClients: 1024, maximumBytes: 16 * 1024 * 1024 });
export function postgresStore({
  driver,
  core,
  assets,
  clientRegistryLimits = clientRegistryCapacity,
  onAuthEvent = async () => {},
}) {
  const limits = { ...clientRegistryCapacity, ...clientRegistryLimits };
  for (const key of Object.keys(clientRegistryCapacity)) {
    if (!Number.isSafeInteger(limits[key]) || limits[key] < 1 || limits[key] > clientRegistryCapacity[key])
      throw new Error("invalid_client_registry_capacity");
  }
  const report = async (name, now) => {
    try {
      await onAuthEvent({ name, now });
    } catch {}
  };
  // Shared with retention and pending creation: count + insert is atomic across
  // all Edge isolates. Operator limits may be lowered, never made unbounded.
  const registryLock = tx => tx.query("select pg_advisory_xact_lock(hashtextextended('carry-ai-client-registry',0))");
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
  async function touchClient(tx, id, client, now) {
    // A retained client outlives account deletion. Keep its own activity clock
    // so erasing account grants cannot make a recently used client look idle.
    if (!Number.isSafeInteger(client.lastUsedAt) || now - client.lastUsedAt >= 3600000) {
      client.lastUsedAt = now;
      await put(tx, "client", id, client);
    }
  }
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
    await touchClient(tx, g.clientID, c, now);
    return g;
  }
  const tokenGrant = async (tx, id, now) => {
    try {
      return await grant(tx, id, now);
    } catch (error) {
      if (
        error instanceof AIFailure &&
        ["invalid_token", "account_unavailable"].includes(error.code)
      )
        fail("invalid_grant");
      throw error;
    }
  };
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
  async function authorizedAsset(tx, p, g, id) {
    has(g, "attachments:read");
    if (g.accountID !== p.accountID) fail("invalid_token", 401);
    const row = (await tx.query(`select id,account_id,entity_id,entity_kind,slot,sha256,byte_count,state,verified_version
      from carry_private.assets where account_id=$1 and id=$2`, [p.accountID,id])).rows[0];
    if (!row || row.state !== "verified" || !row.verified_version || Number(row.byte_count) > 50*1024*1024)
      fail("asset_not_found",404);
    // Fetch only the bounded ancestor chain, never every large trip field for
    // each 64 KiB file read. Its root must remain in the current grant.
    const chain = (await tx.query(`with recursive parents as (
      select e.*,array[e.id] as visited from carry_private.graph_entities e where account_id=$1 and id=$2
      union all select e.*,p.visited||e.id from carry_private.graph_entities e join parents p on e.id=p.parent_id
        where e.account_id=$1 and not e.id=any(p.visited) and cardinality(p.visited)<8
    ) select carry_private.graph_snapshot(e) as entity from parents p join carry_private.graph_entities e on e.id=p.id and e.account_id=$1`,[p.accountID,row.entity_id])).rows.map(r=>r.entity);
    const map = graphIndex(chain), entity = authorizeEntity(map,row.entity_id,g);
    if (chain.some(e=>e.deletedAt) || (p.entityID && entity.id!==p.entityID) ||
        (p.tripID && rootOf(map,entity.id).id!==p.tripID) || entity.kind!==row.entity_kind ||
        !assetReferences(entity).some(ref=>ref.id===id&&ref.slot===row.slot)) fail("asset_not_authorized",403);
    const object = (await tx.query(`select 1 from storage.objects where bucket_id='carry-account-assets'
      and name collate "C"=$1 and version=$2 and archived_at is null and not is_delete_marker`,
      [p.accountID.toLowerCase()+"/"+id.toLowerCase()+"/"+row.sha256,String(row.verified_version)])).rows[0];
    if (!object) fail("asset_not_verified",409);
    return { id:row.id,accountID:row.account_id,entityID:row.entity_id,entityKind:row.entity_kind,
      slot:row.slot,sha256:row.sha256,byteCount:Number(row.byte_count),status:"verified",storageVersion:row.verified_version };
  }
  async function exportState(tx,p,{approve=false,download=false}={}) {
    await owner(tx,p);
    const record = await get(tx,"export",p.id);
    if (!record || record.accountID!==p.accountID || record.expiresAt<=p.now) fail("export_not_found",404);
    const g = await grant(tx,record.grantID,p.now);
    has(g,"exports:read"); has(g,"trips:read");
    const roots=(await tx.query("select carry_private.graph_snapshot(e) as entity from carry_private.graph_entities e where account_id=$1 and id=$2 and kind='trip'",[p.accountID,record.tripID])).rows.map(row=>row.entity);
    authorizeEntity(graphIndex(roots),record.tripID,g);
    if (record.mode==="export_backup") for(const scope of ["attachments:read","private:read","preferences:read"]) has(g,scope);
    if (download&&!record.approvedAt) fail("export_not_approved",403);
    if ((approve||download)&&p.contentHash && p.contentHash!==record.contentHash) fail("export_changed",409);
    return {record,g};
  }
  function exportByteBudget(manifests) {
    let total=0;
    for(const file of manifests) {
      if(file.entityKind==='attachment'&&file.slot==='file'&&file.byteCount>25*1024*1024)fail('export_file_too_large',413);
      total+=file.byteCount;
      if(total>128*1024*1024)fail('export_too_large',413);
    }
  }
  async function exportSnapshot(tx,p,record,g) {
    const graph=await core.readGraph(tx,{...p,grant:g});
    authorizeEntity(graphIndex(graph),record.tripID,g);
    if(await exportFingerprint(graph,record.tripID)!==record.graphHash) fail("export_changed",409);
    const prepared=prepareBackup(graph,{tripID:record.tripID,mode:record.mode,now:record.createdAt});
    const manifests=[];
    for(const reference of prepared.files) manifests.push(await authorizedAsset(tx,{...p,tripID:record.tripID,entityID:reference.entityID},g,reference.id));
    exportByteBudget(manifests);backupSerializedByteCount(prepared,manifests);
    if(JSON.stringify(canonical(manifests))!==JSON.stringify(canonical(record.manifests))) fail("export_changed",409);
    return prepared;
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
    registerClient: async (p) => {
      const result = await transaction(async (tx) => {
        await registryLock(tx);
        if (await get(tx, "client", p.id)) fail("request_id_reused", 409);
        const registered = { ...p, registryVersion: 1 };
        const usage = (
          await tx.query(
            `select count(*)::integer as clients,
          coalesce(sum(octet_length(value::text) + case when value->>'usedAt' is null then 96 when value->>'lastUsedAt' is null then 48 else 0 end),0)::bigint as bytes,
          octet_length($1::jsonb::text) + 96 as incoming from carry_ai.records where bucket='client'`,
            [registered],
          )
        ).rows[0];
        if (
          usage.clients >= limits.maximumClients ||
          Number(usage.bytes) + usage.incoming > limits.maximumBytes
        ) {
          if (Number.isSafeInteger(p.createdAt) && p.createdAt >= 0)
            await tx.query("select carry_ai.retire_clients($1::bigint,32)", [
              p.createdAt,
            ]);
          const fresh = (
            await tx.query(`select count(*)::integer as clients,
            coalesce(sum(octet_length(value::text) + case when value->>'usedAt' is null then 96 when value->>'lastUsedAt' is null then 48 else 0 end),0)::bigint as bytes
            from carry_ai.records where bucket='client'`)
          ).rows[0];
          if (
            fresh.clients >= limits.maximumClients ||
            Number(fresh.bytes) + usage.incoming > limits.maximumBytes
          )
            return { capacity: true };
        }
        await put(tx, "client", p.id, registered);
        return { capacity: false };
      });
      if (result.capacity) fail("client_registration_capacity_exhausted", 503);
    },
    getClient: (p) => transaction((tx) => get(tx, "client", p.id)),
    createAuthorization: (p) =>
      transaction(async (tx) => {
        await registryLock(tx);
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
        // A used client must survive retention even after account deletion has
        // removed its grants. No token or refresh binding is changed.
        if (!c.usedAt) c.usedAt = p.now;
        c.lastUsedAt = p.now;
        await put(tx, "client", r.clientID, c);
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
        const g = await tokenGrant(tx, hint.grantID, p.now),
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
      let outcome = "refresh_unavailable";
      try {
        const result = await transaction(async (tx) => {
          const hint = (
            await tx.query(
              "select value from carry_ai.records where bucket='refresh' and id=$1",
              [p.refreshHash],
            )
          ).rows[0]?.value;
          if (!hint) {
            outcome = "refresh_missing";
            fail("invalid_grant");
          }
          outcome = "refresh_invalid";
          const g = await tokenGrant(tx, hint.grantID, p.now),
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
            outcome = "refresh_replay";
            return { reuse: true };
          }
          // Refresh never changes the owner's grant. Check only after spent-token
          // replay detection, so invalid scope cannot suppress family revocation.
          if (
            p.requestedScopes !== undefined &&
            (!Array.isArray(p.requestedScopes) ||
              new Set(p.requestedScopes).size !== new Set(g.scopes).size ||
              g.scopes.some((scope) => !p.requestedScopes.includes(scope)))
          ) {
            outcome = "refresh_scope";
            fail("invalid_scope");
          }
          t.spent = true;
          await put(tx, "refresh", p.refreshHash, t);
          await bindTokens(tx, g, p.tokens);
          return { grant: g };
        });
        // Reuse must COMMIT family revocation before returning invalid_grant.
        if (result.reuse) fail("invalid_grant");
        await report("refresh_ok", p.now);
        return result.grant;
      } catch (error) {
        await report(
          error instanceof AIFailure && error.code === "store_unavailable"
            ? "refresh_unavailable"
            : outcome,
          p.now,
        );
        throw error;
      }
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
    readAsset: async p => {
      if(!assets?.read)fail("capability_unavailable",503);
      const started=Date.now();
      const first=await transaction(async tx=>authorizedAsset(tx,p,await grant(tx,p.grantID,p.now),p.assetID));
      const result=await assets.read(first,{offset:p.offset,limit:p.limit,signal:p.signal});
      await transaction(async tx=>{
        const fresh={...p,now:p.now+Date.now()-started};
        const current=await authorizedAsset(tx,fresh,await grant(tx,p.grantID,fresh.now),p.assetID);
        if(JSON.stringify(current)!==JSON.stringify(first))fail("asset_changed",409);
      });
      return {bytes:result,hasMore:p.offset+result.length<first.byteCount};
    },
    prepareExport: p => transaction(async tx=>{
      const g=await grant(tx,p.grantID,p.now);
      if(g.accountID!==p.accountID)fail("invalid_token",401);
      has(g,"exports:read");has(g,"trips:read");
      if(p.mode==="export_backup")for(const scope of ["attachments:read","private:read","preferences:read"])has(g,scope);
      const prior=(await tx.query("select value from carry_ai.records where bucket='export' and grant_id=$1 and request_id=$2 for update",[g.id,p.requestID])).rows[0]?.value;
      if(prior){if(prior.tripID!==p.tripID||prior.mode!==p.mode)fail("request_id_reused",409);return {id:prior.id};}
      const graph=await core.readGraph(tx,{...p,grant:g});authorizeEntity(graphIndex(graph),p.tripID,g);
      const prepared=prepareBackup(graph,p),manifests=[];
      for(const ref of prepared.files)manifests.push(await authorizedAsset(tx,{...p,entityID:ref.entityID},g,ref.id));
      exportByteBudget(manifests);backupSerializedByteCount(prepared,manifests);
      const graphHash=await exportFingerprint(graph,p.tripID),id=crypto.randomUUID(),
        contentHash=await hash(JSON.stringify(canonical({graphHash,manifests,mode:p.mode}))),
        record={id,accountID:g.accountID,grantID:g.id,requestID:p.requestID,tripID:p.tripID,mode:p.mode,
          createdAt:p.now,expiresAt:p.now+10*60*1000,approvedAt:null,graphHash,contentHash,manifests,
          summary:{...prepared.summary,byteCount:manifests.reduce((n,m)=>n+m.byteCount,0),
            files:manifests.slice(0,100).map((m,i)=>({name:prepared.files[i].label,slot:m.slot,byteCount:m.byteCount}))}};
      await put(tx,"export",id,record);return {id};
    }),
    getExport: p => transaction(async tx=>{
      const {record}=await exportState(tx,p);
      return {id:record.id,summary:record.summary,contentHash:record.contentHash,approvedAt:record.approvedAt,expiresAt:record.expiresAt};
    }),
    approveExport: p => transaction(async tx=>{
      const {record,g}=await exportState(tx,p,{approve:true});
      if(record.contentHash!==p.contentHash)fail("export_changed",409);
      await exportSnapshot(tx,p,record,g);record.approvedAt=p.now;await put(tx,"export",record.id,record);
    }),
    downloadExport: async p => {
      if(!assets?.stream)fail("capability_unavailable",503);
      const {record,prepared}=await transaction(async tx=>{
        const {record,g}=await exportState(tx,p,{download:true});
        return {record,prepared:await exportSnapshot(tx,p,record,g)};
      });
      prepared.backup.assetManifest=record.manifests.map(m=>({entityID:m.entityID,assetID:m.id,slot:m.slot,sha256:m.sha256,byteCount:m.byteCount}));
      const started=Date.now(),fresh=()=>({...p,now:p.now+Date.now()-started});
      const authorize=async()=>transaction(async tx=>{await exportState(tx,fresh(),{download:true});});
      const open=async (ref,{signal}={})=>{
        const current=await transaction(async tx=>{
          const request=fresh(),{g}=await exportState(tx,request,{download:true});
          const manifest=await authorizedAsset(tx,{...request,tripID:record.tripID,entityID:ref.entityID},g,ref.id);
          const expected=record.manifests.find(m=>m.id===ref.id);
          if(JSON.stringify(canonical(manifest))!==JSON.stringify(canonical(expected)))fail("export_changed",409);
          return manifest;
        });
        return assets.stream(current,{signal:signal??p.signal,authorize:async()=>transaction(async tx=>{
          const request=fresh(),{g}=await exportState(tx,request,{download:true});
          const latest=await authorizedAsset(tx,{...request,tripID:record.tripID,entityID:ref.entityID},g,ref.id);
          if(JSON.stringify(canonical(latest))!==JSON.stringify(canonical(current)))fail("export_changed",409);
        })});
      };
      return {body:streamBackup(prepared,{open,authorize,signal:p.signal}),
        fileName:`Carry-${record.tripID}.${record.mode==='share_trip'?'carrytrip':'json'}`};
    },
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
