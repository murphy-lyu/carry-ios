// TEST FIXTURE ONLY. No deploy/export path uses this non-durable Map adapter.
import { AIFailure, fail, canonical } from "./security.mjs";
import {
  graphIndex,
  rootOf,
  authorizeEntity,
  assertMutationAccess,
  assertPlanPreconditions,
} from "./domain.mjs";
export function syntheticStore({ accountID, sessionID, entities = [], time }) {
  const db = {
    clients: new Map(),
    authorizations: new Map(),
    grants: new Map(),
    codes: new Map(),
    access: new Map(),
    refresh: new Map(),
    previews: new Map(),
    receipts: new Map(),
    graph: new Map(entities.map((e) => [e.id, structuredClone(e)])),
    sessions: new Set([sessionID]),
    accountActive: true,
    sequence: 0,
  };
  const checkOwner = (p) => {
    if (
      p.accountID !== accountID ||
      !db.sessions.has(p.sessionID) ||
      !db.accountActive
    )
      fail("unauthorized", 401);
  };
  const checkGrant = (id, now) => {
    const g = db.grants.get(id);
    if (
      !g ||
      g.accountID !== accountID ||
      g.revokedAt ||
      g.expiresAt <= now ||
      !db.accountActive ||
      db.clients.get(g.clientID)?.disabledAt
    )
      fail("invalid_token", 401);
    return g;
  };
  const getReceipt = (grantID, requestID) =>
    db.receipts.get(grantID + ":" + requestID);
  const bindTokens = (g, tokens) => {
    db.access.set(tokens.accessHash, {
      grantID: g.id,
      expiresAt: tokens.accessExpiresAt,
    });
    db.refresh.set(tokens.refreshHash, {
      grantID: g.id,
      expiresAt: tokens.refreshExpiresAt,
      spent: false,
    });
  };
  const store = {
    durability: "synthetic-only",
    db,
    rateLimit: async () => true,
    registerClient: async (value) => {
      db.clients.set(value.id, structuredClone(value));
    },
    getClient: async ({ id }) => db.clients.get(id),
    createAuthorization: async (value) => {
      if (db.authorizations.has(value.id)) fail("request_id_reused", 409);
      db.authorizations.set(value.id, structuredClone(value));
    },
    getAuthorization: async ({ id }) => {
      const r = db.authorizations.get(id);
      return r
        ? {
            ...structuredClone(r),
            clientName: db.clients.get(r.clientID)?.name,
          }
        : null;
    },
    denyAuthorization: async (p) => {
      checkOwner(p);
      const r = db.authorizations.get(p.id);
      if (!r || r.consumedAt || r.expiresAt <= p.now) fail("invalid_request");
      r.consumedAt = p.now;
    },
    approveAuthorization: async (p) => {
      checkOwner(p);
      const r = db.authorizations.get(p.id);
      if (!r || r.consumedAt || r.expiresAt <= p.now) fail("invalid_request");
      if (
        !db.clients.has(r.clientID) ||
        db.clients.get(r.clientID).disabledAt ||
        p.selectedScopes.some((s) => !r.scopes.includes(s))
      )
        fail("invalid_scope");
      for (const id of p.tripIDs) {
        const e = db.graph.get(id);
        if (!e || e.kind !== "trip" || e.deletedAt)
          fail("trip_not_authorized", 403);
      }
      const grant = {
        id: p.grantID,
        accountID,
        clientID: r.clientID,
        resource: r.resource,
        scopes: p.selectedScopes,
        tripIDs: p.tripIDs,
        createdTripIDs: [],
        onlyCreated: p.onlyCreated,
        expiresAt: p.grantExpiresAt,
        revokedAt: null,
      };
      db.grants.set(grant.id, grant);
      db.codes.set(p.codeHash, {
        ...structuredClone(r),
        grantID: grant.id,
        codeExpiresAt: p.codeExpiresAt,
        consumedAt: null,
      });
      r.consumedAt = p.now;
    },
    exchangeCode: async (p) => {
      const c = db.codes.get(p.codeHash);
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
      const g = checkGrant(c.grantID, p.now);
      c.consumedAt = p.now;
      bindTokens(g, p.tokens);
      return structuredClone(g);
    },
    rotateRefresh: async (p) => {
      const t = db.refresh.get(p.refreshHash);
      if (!t) fail("invalid_grant");
      const g = checkGrant(t.grantID, p.now);
      if (
        g.clientID !== p.clientID ||
        g.resource !== p.resource ||
        t.expiresAt <= p.now
      )
        fail("invalid_grant");
      if (t.spent) {
        g.revokedAt = p.now;
        fail("invalid_grant");
      }
      t.spent = true;
      bindTokens(g, p.tokens);
      return structuredClone(g);
    },
    revokeToken: async (p) => {
      const token = db.access.get(p.tokenHash) ?? db.refresh.get(p.tokenHash),
        g = token && db.grants.get(token.grantID);
      if (g?.clientID === p.clientID) g.revokedAt = p.now;
    },
    resolveAccess: async (p) => {
      const t = db.access.get(p.tokenHash);
      if (!t || t.expiresAt <= p.now) fail("invalid_token", 401);
      const g = checkGrant(t.grantID, p.now);
      if (g.resource !== p.resource) fail("invalid_token", 401);
      return structuredClone(g);
    },
    getGrant: async (p) => structuredClone(checkGrant(p.id, p.now)),
    listGrants: async (p) => {
      checkOwner(p);
      return [...db.grants.values()].map((g) => ({
        id: g.id,
        scopes: g.scopes,
        tripIDs: g.tripIDs,
        expiresAt: g.expiresAt,
        revokedAt: g.revokedAt,
      }));
    },
    revokeGrant: async (p) => {
      checkOwner(p);
      checkGrant(p.id, p.now).revokedAt = p.now;
    },
    readGraph: async (p) => {
      checkGrant(p.grantID, p.now);
      return structuredClone([...db.graph.values()]);
    },
    receipt: async (p) => {
      checkGrant(p.grantID, p.now);
      return structuredClone(getReceipt(p.grantID, p.requestID) ?? null);
    },
    createPreview: async (p) => {
      checkGrant(p.grantID, p.now);
      const existing = [...db.previews.values()].find(
        (v) => v.grantID === p.grantID && v.requestID === p.requestID,
      );
      if (existing) {
        if (existing.inputHash !== p.inputHash) fail("request_id_reused", 409);
        return structuredClone(existing);
      }
      const record = {
        ...structuredClone(p),
        id: crypto.randomUUID(),
        contentHash: p.compiled.contentHash,
        approvedAt: null,
      };
      db.previews.set(record.id, record);
      return structuredClone(record);
    },
    getPreview: async (p) => {
      const r = db.previews.get(p.id);
      if (
        !r ||
        p.accountID !== r.accountID ||
        (p.grantID && p.grantID !== r.grantID)
      )
        return null;
      checkGrant(r.grantID, p.now);
      return structuredClone(r);
    },
    approvePreview: async (p) => {
      checkOwner(p);
      const r = db.previews.get(p.id);
      if (
        !r ||
        r.accountID !== p.accountID ||
        r.expiresAt <= p.now ||
        r.contentHash !== p.contentHash
      )
        fail("invalid_preview");
      checkGrant(r.grantID, p.now);
      r.approvedAt = p.now;
    },
    execute: async (p) => {
      const grant = checkGrant(p.grantID, p.now),
        prior = getReceipt(p.grantID, p.requestID);
      if (prior) {
        if (prior.inputHash !== p.inputHash) fail("request_id_reused", 409);
        return structuredClone(prior);
      }
      const associated = [...db.previews.values()].find(
        (v) => v.grantID === p.grantID && v.requestID === p.requestID,
      );
      if (associated && !p.previewID) fail("preview_required", 403);
      const preview = p.previewID && db.previews.get(p.previewID);
      if (p.compiled.requiresApproval && !preview)
        fail("preview_not_approved", 403);
      if (
        preview &&
        (!preview.approvedAt ||
          preview.expiresAt <= p.now ||
          preview.grantID !== grant.id ||
          preview.requestID !== p.requestID ||
          preview.contentHash !== p.compiled.contentHash ||
          preview.consumedAt)
      )
        fail("preview_not_approved", 403);
      // One synchronous fixture transaction: work on a clone, publish all maps
      // only after validation. No await may split this non-durable test unit.
      const before = graphIndex([...db.graph.values()]),
        working = graphIndex([...db.graph.values()]);
      assertPlanPreconditions(working, p.compiled, grant);
      let sequence = db.sequence;
      const changed = new Set(),
        ancestors = (id) => {
          let e = working.get(id);
          while (e?.parentID) {
            const parent = working.get(e.parentID);
            if (!parent) fail("invalid_parent");
            parent.subtreeVersion = ++sequence;
            e = parent;
          }
        };
      for (const m of p.compiled.command.mutations) {
        const current = working.get(m.id);
        assertMutationAccess(
          working,
          m,
          grant,
          p.compiled.command.mutations
            .filter((x) => x.action === "create" && x.kind === "trip")
            .map((x) => x.id),
        );
        if (m.action === "create") {
          if (current) fail("entity_exists", 409);
          if (m.kind === "trip") {
            if (!grant.scopes.includes("trips:create"))
              fail("insufficient_scope", 403);
          } else if (m.kind === "libraryItem") {
            if (!grant.scopes.includes("library:write"))
              fail("insufficient_scope", 403);
          } else {
            const parent = working.get(m.parentID);
            if (!parent || parent.deletedAt) fail("invalid_parent");
            const root = rootOf(working, parent.id);
            if (!p.compiled.createdTripIDs.includes(root.id))
              authorizeEntity(working, parent.id, grant, { write: true });
          }
          working.set(m.id, {
            id: m.id,
            kind: m.kind,
            parentID: m.parentID ?? null,
            fields: structuredClone(m.fields),
            version: 1,
            subtreeVersion: ++sequence,
            deletedAt: null,
            deletionBatch: null,
            fieldVersions: Object.fromEntries(
              Object.keys(m.fields).map((k) => [k, 1]),
            ),
          });
          changed.add(m.id);
          ancestors(m.id);
          continue;
        }
        authorizeEntity(working, m.id, grant, {
          write: true,
          includeDeleted: m.action === "restore",
        });
        if (!current || current.kind !== m.kind) fail("entity_not_found", 404);
        if (
          ["delete", "restore", "move"].includes(m.action) &&
          current.version !== m.baseVersion
        )
          fail("version_conflict", 409);
        if (
          ["delete", "restore"].includes(m.action) &&
          current.subtreeVersion !== m.baseSubtreeVersion
        )
          fail("subtree_conflict", 409);
        if (m.action === "delete" || m.action === "restore") {
          if (
            m.action === "restore" &&
            current.deletionBatch !== m.deletionBatch
          )
            fail("restore_conflict", 409);
          const batch =
            m.action === "delete" ? crypto.randomUUID() : m.deletionBatch;
          for (const e of working.values()) {
            let member = e.id === m.id,
              c = e;
            while (!member && c?.parentID) {
              if (c.parentID === m.id) member = true;
              c = working.get(c.parentID);
            }
            if (
              member &&
              (m.action === "delete" ? !e.deletedAt : e.deletionBatch === batch)
            ) {
              e.deletedAt =
                m.action === "delete" ? new Date(p.now).toISOString() : null;
              e.deletionBatch = m.action === "delete" ? batch : null;
              e.version++;
              e.subtreeVersion = ++sequence;
              changed.add(e.id);
            }
          }
          ancestors(m.id);
          continue;
        }
        if (current.deletedAt) fail("entity_deleted", 409);
        for (const [key, value] of Object.entries(m.fields ?? {})) {
          if (
            (current.fieldVersions[key] ?? current.version) >
            (m.fieldVersions?.[key] ?? m.baseVersion)
          )
            fail("field_conflict", 409);
          current.fields[key] = value;
          current.fieldVersions[key] = current.version + 1;
        }
        if (m.action === "move") {
          const parent = working.get(m.parentID);
          if (!parent || parent.deletedAt) fail("invalid_parent");
          current.parentID = m.parentID;
        }
        current.version++;
        current.subtreeVersion = ++sequence;
        changed.add(current.id);
        ancestors(current.id);
      }
      const record = {
        requestID: p.requestID,
        operationID: p.requestID,
        inputHash: p.inputHash,
        status: "saved_to_account",
        grantID: grant.id,
        accountID,
        changes: [...changed].map((id) => ({
          id,
          kind: working.get(id).kind,
          version: working.get(id).version,
        })),
        before: [...before.values()],
        after: structuredClone([...working.values()]),
        mutations: structuredClone(p.compiled.command.mutations),
      };
      db.graph = working;
      db.sequence = sequence;
      grant.createdTripIDs = [
        ...new Set([...grant.createdTripIDs, ...p.compiled.createdTripIDs]),
      ];
      db.receipts.set(grant.id + ":" + p.requestID, record);
      if (preview) preview.consumedAt = p.now;
      return structuredClone(record);
    },
    prepareUndo: async (p) => {
      const grant = checkGrant(p.grantID, p.now),
        record = getReceipt(grant.id, p.operationID);
      if (!record) fail("operation_not_found", 404);
      const before = graphIndex(record.before),
        after = graphIndex(record.after),
        mutated = new Set(record.mutations.map((m) => m.id)),
        operations = [];
      for (const m of record.mutations) {
        const a = after.get(m.id),
          b = before.get(m.id),
          current = db.graph.get(m.id);
        if (
          !current ||
          current.version !== a.version ||
          current.subtreeVersion !== a.subtreeVersion
        )
          fail("undo_conflict", 409);
        if (!b) {
          if (a.parentID && mutated.has(a.parentID) && !before.has(a.parentID))
            continue;
          operations.push({
            action: "delete",
            id: a.id,
            kind: a.kind,
            baseVersion: a.version,
            baseSubtreeVersion: a.subtreeVersion,
          });
        } else if (a.deletedAt && !b.deletedAt) {
          if (
            a.parentID &&
            mutated.has(a.parentID) &&
            after.get(a.parentID)?.deletionBatch === a.deletionBatch
          )
            continue;
          operations.push({
            action: "restore",
            id: a.id,
            kind: a.kind,
            baseVersion: a.version,
            baseSubtreeVersion: a.subtreeVersion,
            deletionBatch: a.deletionBatch,
          });
        } else {
          const fields = Object.fromEntries(
            Object.keys(m.fields ?? {}).map((k) => [k, b.fields[k] ?? null]),
          );
          operations.push({
            action: a.parentID !== b.parentID ? "move" : "patch",
            id: a.id,
            kind: a.kind,
            parentID: b.parentID,
            baseVersion: a.version,
            fields,
          });
        }
      }
      return { operations };
    },
  };
  return store;
}
