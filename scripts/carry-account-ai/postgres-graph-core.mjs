import { fail } from "./security.mjs";
import { graphIndex } from "./domain.mjs";

// Only the private shared business core is invoked. Never mint an Auth session,
// use a native user's bearer, or proxy a native-only RPC with an OAuth token.
export function postgresGraphCore() {
  const sql = async (tx, statement, parameters = []) => {
    try {
      return await tx.query(statement, parameters);
    } catch (e) {
      const code = String(e.message ?? "");
      const known = [
        "account_unavailable",
        "session_expired",
        "field_conflict",
        "move_conflict",
        "subtree_conflict",
        "deleted_entity",
        "entity_not_found",
        "entity_exists",
        "restore_expired",
        "request_id_reused",
        "asset_not_verified",
        "asset_reference_invalid",
        "invalid_parent",
        "invalid_version",
        "invalid_command",
        "invalid_mutation",
        "invalid_field_versions",
        "invalid_patch",
        "invalid_command_size",
        "invalid_request_id",
        "duplicate_mutation",
        "subtree_version_required",
        "invalid_field",
        "invalid_fields",
        "invalid_hierarchy",
      ];
      const matched = known.find((v) => code === v);
      if (matched)
        fail(
          matched,
          ["account_unavailable", "session_expired"].includes(matched)
            ? 401
            : 409,
        );
      throw e;
    }
  };
  const read = async (tx, accountID) => {
    const size = (
      await sql(
        tx,
        "select count(*) as count,coalesce(sum(octet_length(fields::text)),0) as bytes from carry_private.graph_entities where account_id=$1",
        [accountID],
      )
    ).rows[0];
    if (Number(size.count) > 20000 || Number(size.bytes) > 32 * 1024 * 1024)
      fail("graph_too_large", 413);
    const rows = (
      await sql(
        tx,
        `select carry_private.graph_snapshot(e) as entity from carry_private.graph_entities e
      where account_id=$1 order by id limit 20001`,
        [accountID],
      )
    ).rows;
    if (rows.length > 20000) fail("graph_too_large", 413);
    return rows.map((r) => r.entity);
  };
  return {
    assertAccount: async (tx, p) => {
      await sql(tx, "select carry_private.graph_require_active_account($1)", [
        p.accountID,
      ]);
    },
    assertOwner: async (tx, p) => {
      await sql(tx, "select carry_private.graph_require_session($1,$2)", [
        p.accountID,
        p.sessionID,
      ]);
    },
    ownsTrips: async (tx, p) => {
      if (!p.tripIDs.length) return true;
      const rows = (
        await sql(
          tx,
          "select id from carry_private.graph_entities where account_id=$1 and id=any($2::uuid[]) and kind='trip' and deleted_at is null",
          [p.accountID, p.tripIDs],
        )
      ).rows;
      return rows.length === p.tripIDs.length;
    },
    tripChoices: async (tx, p) => {
      const rows = (
        await sql(
          tx,
          `select id,fields->>'name' as name,version from carry_private.graph_entities
        where account_id=$1 and kind='trip' and deleted_at is null
          and ($2='' or strpos(lower(fields->>'name'),lower($2))>0)
        order by id offset $3 limit $4`,
          [p.accountID, p.q, p.offset, p.limit + 1],
        )
      ).rows;
      return {
        trips: rows.slice(0, p.limit),
        hasMore: rows.length > p.limit,
        nextOffset: rows.length > p.limit ? p.offset + p.limit : null,
      };
    },
    readGraph: async (tx, p) => read(tx, p.accountID),
    execute: async (tx, p) => {
      // Request IDs are globally scoped to an account Graph, while AI receipts
      // are additionally scoped to a grant. A different grant/native operation
      // cannot borrow an existing Graph receipt and invent new before images.
      if (
        (
          await sql(
            tx,
            "select 1 from carry_private.graph_receipts where account_id=$1 and request_id=$2",
            [p.accountID, p.requestID],
          )
        ).rows.length
      )
        fail("request_id_reused", 409);
      const before = graphIndex(await read(tx, p.accountID));
      const mutations = p.compiled.command.mutations.map((m) => {
        if (m.action !== "restore") return m;
        const current = before.get(m.id);
        if (
          !current?.deletedAt ||
          !current.deletionBatch ||
          m.deletionBatch !== current.deletionBatch
        )
          fail("restore_conflict", 409);
        // The user-facing batch is an approval binding, not a native wire key.
        const { deletionBatch, ...native } = m;
        return native;
      });
      const command = { requestID: p.requestID, mutations };
      const result = (
        await sql(
          tx,
          "select carry_private.graph_apply_core($1,$2::jsonb) as result",
          [p.accountID, command],
        )
      ).rows[0].result;
      const after = graphIndex(await read(tx, p.accountID));
      const changed = [...new Set(result.changes.map((c) => c.entity.id))];
      return {
        status: "saved_to_account",
        requestID: p.requestID,
        operationID: p.requestID,
        changes: changed.map((id) => ({
          id,
          kind: after.get(id).kind,
          version: after.get(id).version,
        })),
        before: changed.map((id) => before.get(id)).filter(Boolean),
        after: changed.map((id) => after.get(id)),
        mutations: p.compiled.command.mutations,
      };
    },
    prepareUndo: async (tx, p) => {
      if (p.record.undoExpired) fail("undo_expired", 410);
      const before = graphIndex(p.record.before ?? []),
        after = graphIndex(p.record.after ?? []),
        current = graphIndex(await read(tx, p.accountID));
      // Include ancestor-only events in conflict detection. A new child, move or
      // field edit after acceptance must invalidate a destructive inverse.
      for (const a of after.values()) {
        const c = current.get(a.id);
        if (
          !c ||
          c.version !== a.version ||
          c.subtreeVersion !== a.subtreeVersion
        )
          fail("undo_conflict", 409);
      }
      const mutations = p.record.mutations ?? [],
        mutated = new Set(mutations.map((m) => m.id)),
        operations = [];
      const created = new Set(
        mutations.filter((m) => m.action === "create").map((m) => m.id),
      );
      const ancestorIn = (entity, set) => {
        const seen = new Set();
        let c = entity;
        while (c?.parentID) {
          if (seen.has(c.id)) fail("invalid_graph", 503);
          seen.add(c.id);
          if (set.has(c.parentID)) return c.parentID;
          c = current.get(c.parentID);
        }
        return null;
      };
      for (const m of mutations) {
        const a = after.get(m.id),
          b = before.get(m.id);
        if (!a) fail("undo_unavailable", 409);
        if (!b) {
          if (ancestorIn(a, created)) continue;
          operations.push({
            action: "delete",
            id: a.id,
            kind: a.kind,
            baseVersion: a.version,
            baseSubtreeVersion: a.subtreeVersion,
          });
        } else if (a.deletedAt && !b.deletedAt) {
          const parent = ancestorIn(a, mutated);
          if (parent && after.get(parent)?.deletionBatch === a.deletionBatch)
            continue;
          operations.push({
            action: "restore",
            id: a.id,
            kind: a.kind,
            baseVersion: a.version,
            baseSubtreeVersion: a.subtreeVersion,
            deletionBatch: a.deletionBatch,
          });
        } else if (!a.deletedAt && b.deletedAt) {
          operations.push({
            action: "delete",
            id: a.id,
            kind: a.kind,
            baseVersion: a.version,
            baseSubtreeVersion: a.subtreeVersion,
          });
        } else {
          const fields = Object.fromEntries(
            Object.keys(m.fields ?? {}).map((k) => [k, b.fields[k] ?? null]),
          );
          operations.push({
            action: a.parentID !== b.parentID ? "move" : "patch",
            id: a.id,
            kind: a.kind,
            ...(a.parentID !== b.parentID ? { parentID: b.parentID } : {}),
            baseVersion: a.version,
            fields,
            fieldVersions: Object.fromEntries(
              Object.keys(fields).map((k) => [
                k,
                a.fieldVersions[k] ?? a.version,
              ]),
            ),
          });
        }
      }
      if (!operations.length) fail("undo_unavailable", 409);
      return { operations };
    },
  };
}
