import { graphSchema } from "../carry-account-service/graph-schema.mjs";
import { fail, object, identifier, has, canonical, hash } from "./security.mjs";
export const privateFields = new Set([
  "confirmationCode",
  "eticketNumber",
  "seat",
  "licensePlate",
]);
const assetFields = new Set([
  "thumbnailAssetID",
  "originalAssetID",
  "fileAssetID",
  "backgroundsData",
  "backgroundAssetIDs",
  "fileName",
  "urlString",
]);
const preferenceFields = new Set(["reminderConfigData", "remindersEnabled"]);
const kinds = Object.keys(graphSchema);
export function visibleEntity(entity, grant) {
  if (!entity || !kinds.includes(entity.kind)) fail("invalid_graph", 503);
  const fields = {};
  for (const [key, value] of Object.entries(entity.fields ?? {})) {
    if (
      !Object.hasOwn(graphSchema[entity.kind].fields, key) ||
      key === "assetLocalIdentifier"
    )
      continue;
    if (privateFields.has(key) && !grant.scopes.includes("private:read"))
      continue;
    if (
      (assetFields.has(key) || ["attachment", "photo"].includes(entity.kind)) &&
      !grant.scopes.includes("attachments:read")
    )
      continue;
    if (preferenceFields.has(key) && !grant.scopes.includes("preferences:read"))
      continue;
    fields[key] = value;
  }
  return {
    id: entity.id,
    kind: entity.kind,
    parentID: entity.parentID ?? null,
    version: entity.version,
    subtreeVersion: entity.subtreeVersion,
    deletedAt: entity.deletedAt ?? null,
    deletionBatch: entity.deletionBatch ?? null,
    fields,
    fieldVersions: Object.fromEntries(
      Object.keys(fields).map((k) => [
        k,
        entity.fieldVersions?.[k] ?? entity.version,
      ]),
    ),
  };
}
export function graphIndex(entities) {
  const map = new Map();
  for (const entity of entities) {
    if (
      !entity ||
      !kinds.includes(entity.kind) ||
      !entity.id ||
      map.has(entity.id)
    )
      fail("invalid_graph", 503);
    map.set(entity.id, structuredClone(entity));
  }
  return map;
}
export function rootOf(map, id) {
  const visited = new Set();
  let entity = map.get(id);
  while (entity?.parentID) {
    if (visited.has(entity.id)) fail("invalid_graph", 503);
    visited.add(entity.id);
    entity = map.get(entity.parentID);
  }
  if (!entity) fail("entity_not_found", 404);
  return entity;
}
export function authorizeEntity(
  map,
  id,
  grant,
  { write = false, includeDeleted = false } = {},
) {
  const entity = map.get(id);
  if (!entity || (!includeDeleted && entity.deletedAt))
    fail("entity_not_found", 404);
  const root = rootOf(map, id);
  has(
    grant,
    root.kind === "libraryItem"
      ? write
        ? "library:write"
        : "library:read"
      : write
        ? "trips:write"
        : "trips:read",
  );
  if (
    root.kind === "trip" &&
    !grant.tripIDs.includes(root.id) &&
    !grant.createdTripIDs.includes(root.id)
  )
    fail("trip_not_authorized", 403);
  if (["photo", "attachment"].includes(entity.kind))
    has(grant, write ? "attachments:write" : "attachments:read");
  return entity;
}
// Match the existing account wire contract, not Date.parse's normalization
// of impossible calendar days / 24:00, or its timezone-less local-time fallback.
function wireDateValid(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match || match[0] !== value) return false;
  const [, y, m, d, h, minute, second, zone, , offsetHour, offsetMinute] = match;
  const year = Number(y), month = Number(m), day = Number(d);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1] ||
      Number(h) > 23 || Number(minute) > 59 || Number(second) > 59) return false;
  // PostgreSQL's existing timestamptz contract rejects displacement >=16h.
  if (zone !== "Z" && (Number(offsetHour) > 15 || Number(offsetMinute) > 59)) return false;
  const instant = Date.parse(value);
  if (!Number.isFinite(instant)) return false;
  const utcYear = new Date(instant).getUTCFullYear();
  return utcYear >= 1 && utcYear <= 9999;
}
function valueValid(value, rule) {
  if (value === null) return rule.optional === true;
  if (rule.type === "string") {
    if (
      typeof value !== "string" ||
      value.length > (rule.max ?? 100000) ||
      value.includes("\0")
    )
      return false;
    if (rule.values && !rule.values.includes(value)) return false;
    if (rule.pattern && !new RegExp(rule.pattern).test(value)) return false;
    if (rule.format === "uuid") return /^[0-9a-f-]{36}$/i.test(value);
    if (rule.format === "date-time")
      return wireDateValid(value);
    if (rule.format === "timezone" && value) {
      try {
        new Intl.DateTimeFormat("en", { timeZone: value }).format();
      } catch {
        return false;
      }
    }
    return true;
  }
  if (rule.type === "number")
    return (
      typeof value === "number" &&
      Number.isFinite(value) &&
      (!rule.integer || Number.isSafeInteger(value)) &&
      value >= rule.min &&
      value <= rule.max
    );
  if (rule.type === "boolean") return typeof value === "boolean";
  if (rule.type === "object")
    return (
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      Object.keys(value).length <= rule.max &&
      Object.entries(value).every(
        ([k, v]) =>
          new RegExp(rule.keyPattern).test(k) && valueValid(v, rule.item),
      )
    );
  if (rule.type === "array")
    return (
      Array.isArray(value) &&
      value.length <= rule.max &&
      value.every((v) => valueValid(v, rule.item))
    );
  return false;
}
function checkFields(kind, fields, grant) {
  object(fields, Object.keys(graphSchema[kind].fields));
  for (const [key, value] of Object.entries(fields)) {
    if (key === "assetLocalIdentifier") fail("device_only_field");
    if (!valueValid(value, graphSchema[kind].fields[key]))
      fail("invalid_field");
    if (privateFields.has(key)) has(grant, "private:write");
    if (assetFields.has(key) || ["photo", "attachment"].includes(kind))
      has(grant, "attachments:write");
    if (preferenceFields.has(key)) has(grant, "preferences:write");
  }
}
export function defaults(kind, now) {
  return Object.fromEntries(
    Object.entries(graphSchema[kind].fields)
      .filter(([, r]) => !r.optional)
      .map(([key, r]) => [
        key,
        r.values?.[0] ??
          (r.type === "string"
            ? r.format === "date-time"
              ? new Date(now).toISOString()
              : ""
            : r.type === "number"
              ? Math.max(0, r.min)
              : r.type === "array"
                ? []
                : false),
      ]),
  );
}
async function stableID(requestID, label) {
  const h = await hash(requestID + ":" + label);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
function version(entity, operation, { subtree = false } = {}) {
  if (!Number.isSafeInteger(operation.baseVersion) || operation.baseVersion < 1)
    fail("version_required");
  if (
    subtree &&
    (!Number.isSafeInteger(operation.baseSubtreeVersion) ||
      operation.baseSubtreeVersion !== entity.subtreeVersion ||
      operation.baseVersion !== entity.version)
  )
    fail("subtree_conflict", 409);
}
function descendants(map, entity) {
  return [...map.values()].filter((e) => {
    let current = e,
      visited = new Set();
    while (current?.parentID) {
      if (visited.has(current.id)) fail("invalid_graph", 503);
      visited.add(current.id);
      if (current.parentID === entity.id) return true;
      current = map.get(current.parentID);
    }
    return false;
  });
}
function deletionRights(map, entity, grant) {
  for (const e of [entity, ...descendants(map, entity)]) {
    if (
      ["photo", "attachment"].includes(e.kind) ||
      e.fields?.backgroundsData ||
      (e.fields?.backgroundAssetIDs &&
        Object.keys(e.fields.backgroundAssetIDs).length)
    )
      has(grant, "attachments:write");
    if ([...privateFields].some((k) => e.fields?.[k]))
      has(grant, "private:write");
  }
}
function effectiveDates(fields) {
  if (fields.isDateless) return;
  const d = new Date(fields.departureDate);
  if (
    !Number.isFinite(d.valueOf()) ||
    !Number.isInteger(fields.days) ||
    fields.days < 0 ||
    fields.days > 3650
  )
    fail("invalid_trip_dates");
}

/** Compile public domain intents to the one account graph core. Every parent,
 * subtree, version and scope is checked again inside the durable store's final
 * graph transaction. This module never creates an Auth session or calls the
 * native-only RPC with an OAuth token. */
export async function compilePlan({
  requestID,
  operations,
  entities,
  grant,
  now,
}) {
  identifier(requestID);
  if (
    !Array.isArray(operations) ||
    operations.length < 1 ||
    operations.length > 20000
  )
    fail("invalid_plan");
  const map = graphIndex(entities),
    original = graphIndex(entities),
    mutations = [],
    createdTripIDs = [],
    preconditions = [],
    seen = new Set(),
    refs = new Map();
  const reference = (value) =>
    typeof value === "string" && value.startsWith("@")
      ? (refs.get(value.slice(1)) ?? fail("unknown_plan_reference"))
      : identifier(value);
  const remember = (ref, id) => {
    if (ref !== undefined) {
      if (
        typeof ref !== "string" ||
        !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(ref) ||
        refs.has(ref)
      )
        fail("invalid_plan_reference");
      refs.set(ref, id);
    }
  };
  let requiresApproval = operations.length > 1;
  const add = (m) => {
    if (seen.has(m.id)) fail("duplicate_entity_in_plan");
    seen.add(m.id);
    mutations.push(m);
  };
  for (let index = 0; index < operations.length; index++) {
    const op = object(
      operations[index],
      [
        "action",
        "kind",
        "id",
        "parentID",
        "fields",
        "baseVersion",
        "baseSubtreeVersion",
        "fieldVersions",
        "deletionBatch",
        "ids",
        "data",
        "ref",
      ],
      ["action"],
    );
    if (op.action === "create_trip") {
      has(grant, "trips:create");
      const fields = {
        ...defaults("trip", now),
        ...object(op.fields ?? {}, Object.keys(graphSchema.trip.fields)),
      };
      checkFields("trip", op.fields ?? {}, grant);
      effectiveDates(fields);
      if (!fields.name.trim()) fail("name_required");
      const id = op.id ? identifier(op.id) : await stableID(requestID, index);
      if (map.has(id)) fail("entity_exists", 409);
      add({ id, kind: "trip", action: "create", baseVersion: 0, fields });
      map.set(id, { id, kind: "trip", fields, version: 0, parentID: null });
      createdTripIDs.push(id);
      remember(op.ref, id);
      const days = fields.isDateless ? 0 : fields.days;
      for (let day = 0; day <= days; day++) {
        const child = await stableID(requestID, `${index}:day:${day}`),
          dayFields = { ...defaults("day", now), sortOrder: day };
        add({
          id: child,
          kind: "day",
          parentID: id,
          action: "create",
          baseVersion: 0,
          fields: dayFields,
        });
        map.set(child, {
          id: child,
          kind: "day",
          parentID: id,
          fields: dayFields,
          version: 0,
        });
        if (op.ref) refs.set(op.ref + "/day/" + day, child);
      }
      continue;
    }
    if (op.action === "duplicate_trip") {
      const source = authorizeEntity(map, identifier(op.id), grant);
      if (source.kind !== "trip") fail("invalid_kind");
      has(grant, "trips:create");
      version(source, op, { subtree: true });
      preconditions.push({
        id: source.id,
        kind: source.kind,
        version: source.version,
        subtreeVersion: source.subtreeVersion,
        access: "read",
      });
      requiresApproval = true;
      const members = [source, ...descendants(map, source)].filter(
        (e) => !e.deletedAt && !["attachment", "photo"].includes(e.kind),
      );
      const replacement = new Map();
      for (const e of members)
        replacement.set(
          e.id,
          await stableID(requestID, `${index}:copy:${e.id}`),
        );
      for (const e of members) {
        const fields = { ...e.fields };
        for (const k of privateFields)
          if (Object.hasOwn(fields, k)) fields[k] = "";
        delete fields.backgroundsData;
        delete fields.backgroundAssetIDs;
        if (e.kind === "packingItem") fields.isPacked = false;
        if (e.kind === "trip") {
          object(op.fields ?? {}, ["name"]);
          if (
            op.fields?.name !== undefined &&
            (typeof op.fields.name !== "string" ||
              op.fields.name.length > 500 ||
              !op.fields.name.trim())
          )
            fail("name_required");
          fields.createdAt = new Date(now).toISOString();
          if (op.fields?.name) fields.name = op.fields.name;
          fields.reminderConfigData = "";
          fields.remindersEnabled = false;
        }
        const id = replacement.get(e.id),
          parentID = e.parentID ? replacement.get(e.parentID) : undefined;
        add({
          id,
          kind: e.kind,
          parentID,
          action: "create",
          baseVersion: 0,
          fields,
        });
        map.set(id, { id, kind: e.kind, parentID, fields, version: 0 });
      }
      createdTripIDs.push(replacement.get(source.id));
      remember(op.ref, replacement.get(source.id));
      if (op.ref)
        for (const e of members)
          if (e.kind === "day")
            refs.set(
              op.ref + "/day/" + e.fields.sortOrder,
              replacement.get(e.id),
            );
      continue;
    }
    const kind = op.kind;
    if (!kinds.includes(kind)) fail("invalid_kind");
    if (op.action === "create") {
      const id = op.id ? identifier(op.id) : await stableID(requestID, index);
      if (map.has(id)) fail("entity_exists", 409);
      let parentID = null;
      if (kind === "trip") fail("use_create_trip");
      if (kind === "libraryItem") has(grant, "library:write");
      else {
        parentID = reference(op.parentID);
        const parent = map.get(parentID);
        if (
          !parent ||
          parent.deletedAt ||
          !graphSchema[kind].parents.includes(parent.kind)
        )
          fail("invalid_parent");
        if (createdTripIDs.includes(rootOf(map, parentID).id)) {
          has(grant, "trips:create");
        } else authorizeEntity(map, parentID, grant, { write: true });
      }
      checkFields(kind, op.fields ?? {}, grant);
      const fields = { ...defaults(kind, now), ...op.fields };
      if (["photo", "attachment"].includes(kind))
        has(grant, "attachments:write");
      if (kind === "photo" && !fields.thumbnailAssetID) fail("asset_required");
      if (kind === "attachment" && !fields.fileAssetID && !fields.urlString)
        fail("asset_required");
      add({ id, kind, action: "create", parentID, baseVersion: 0, fields });
      map.set(id, { id, kind, parentID, fields, version: 0 });
      remember(op.ref, id);
      continue;
    }
    const id = identifier(op.id),
      entity = authorizeEntity(map, id, grant, {
        write: true,
        includeDeleted: op.action === "restore",
      });
    if (entity.kind !== kind) fail("invalid_kind");
    if (op.action === "reorder") {
      version(entity, op, { subtree: true });
      preconditions.push({
        id: entity.id,
        kind: entity.kind,
        version: entity.version,
        subtreeVersion: entity.subtreeVersion,
        access: "write",
      });
      object(op.data, ["childKind"], ["childKind"]);
      if (!kinds.includes(op.data.childKind)) fail("invalid_kind");
      if (!Array.isArray(op.ids) || op.ids.length < 1 || op.ids.length > 10000)
        fail("invalid_order");
      const ids = op.ids.map(identifier),
        children = [...map.values()].filter(
          (e) =>
            e.parentID === id && !e.deletedAt && e.kind === op.data?.childKind,
        );
      if (
        ids.length !== children.length ||
        new Set(ids).size !== ids.length ||
        children.some((e) => !ids.includes(e.id))
      )
        fail("incomplete_order");
      for (let i = 0; i < ids.length; i++) {
        const child = authorizeEntity(map, ids[i], grant, { write: true });
        add({
          id: child.id,
          kind: child.kind,
          action: "patch",
          baseVersion: child.version,
          fields: { sortOrder: i },
          fieldVersions: {
            sortOrder: child.fieldVersions?.sortOrder ?? child.version,
          },
        });
      }
      continue;
    }
    if (op.action === "delete" || op.action === "restore") {
      version(entity, op, { subtree: true });
      deletionRights(map, entity, grant);
      requiresApproval = true;
      if (
        op.action === "restore" &&
        (!entity.deletedAt ||
          !entity.deletionBatch ||
          op.deletionBatch !== entity.deletionBatch)
      )
        fail("restore_conflict", 409);
      add({
        id,
        kind,
        action: op.action,
        baseVersion: op.baseVersion,
        baseSubtreeVersion: op.baseSubtreeVersion,
        ...(op.action === "restore" ? { deletionBatch: op.deletionBatch } : {}),
      });
      continue;
    }
    if (!["patch", "move"].includes(op.action)) fail("unsupported_operation");
    version(entity, op);
    checkFields(kind, op.fields ?? {}, grant);
    const fields = op.fields ?? {};
    if (Object.keys(fields).length === 0 && op.action === "patch")
      fail("empty_patch");
    const merged = { ...entity.fields, ...fields };
    if (kind === "trip") {
      effectiveDates(merged);
      if (
        ["departureDate", "days", "isDateless"].some((k) =>
          Object.hasOwn(fields, k),
        )
      )
        requiresApproval = true;
    }
    let parentID;
    if (op.action === "move") {
      parentID = reference(op.parentID);
      const parent = authorizeEntity(map, parentID, grant, { write: true });
      if (
        !graphSchema[kind].parents.includes(parent.kind) ||
        rootOf(map, id).id !== rootOf(map, parentID).id
      )
        fail("invalid_parent");
      if (op.baseVersion !== entity.version) fail("move_conflict", 409);
    }
    const fieldVersions =
      op.fieldVersions ??
      Object.fromEntries(Object.keys(fields).map((k) => [k, op.baseVersion]));
    object(fieldVersions, Object.keys(fields), Object.keys(fields));
    if (
      Object.values(fieldVersions).some(
        (v) => !Number.isSafeInteger(v) || v < 1 || v > op.baseVersion,
      )
    )
      fail("invalid_field_versions");
    add({
      id,
      kind,
      action: op.action,
      parentID,
      baseVersion: op.baseVersion,
      fields,
      fieldVersions,
    });
  }
  if (
    mutations.length < 1 ||
    mutations.length > 20000 ||
    new TextEncoder().encode(JSON.stringify(mutations)).byteLength >
      16 * 1024 * 1024
  )
    fail("plan_too_large");
  const depth = (id) => {
    let e = map.get(id),
      n = 0;
    while (e?.parentID) {
      e = map.get(e.parentID);
      if (++n > 10) fail("invalid_graph", 503);
    }
    return n;
  };
  mutations.sort((a, b) => {
    const rank = (m) =>
      m.action === "restore"
        ? 0
        : m.action === "create"
          ? 1
          : m.action === "delete"
            ? 3
            : 2;
    return (
      rank(a) - rank(b) ||
      (a.action === "delete"
        ? depth(b.id) - depth(a.id)
        : depth(a.id) - depth(b.id))
    );
  });
  requiresApproval = requiresApproval || mutations.length > 20;
  return {
    command: { requestID, mutations },
    createdTripIDs,
    preconditions,
    requiresApproval,
    summary: {
      count: mutations.length,
      createdTrips: createdTripIDs.length,
      actions: mutations.map((m) => {
        const prior = original.get(m.id),
          before = prior ? visibleEntity(prior, grant).fields : {},
          after = visibleEntity({ ...m, fields: m.fields ?? {} }, grant).fields;
        const selected = m.fields ? Object.keys(after) : ["name", "title"];
        return {
          id: m.id,
          kind: m.kind,
          action: m.action,
          affectedCount:
            prior && ["delete", "restore"].includes(m.action)
              ? 1 + descendants(original, prior).length
              : 1,
          baseVersion: m.baseVersion,
          baseSubtreeVersion: m.baseSubtreeVersion,
          parentBefore: prior?.parentID ?? null,
          parentAfter: m.parentID ?? prior?.parentID ?? null,
          parentBeforeDisplay: prior?.parentID
            ? {
                kind: original.get(prior.parentID)?.kind,
                name:
                  original.get(prior.parentID)?.fields?.name ??
                  original.get(prior.parentID)?.fields?.title ??
                  null,
                order: original.get(prior.parentID)?.fields?.sortOrder ?? null,
              }
            : null,
          parentAfterDisplay:
            (m.parentID ?? prior?.parentID)
              ? {
                  kind: map.get(m.parentID ?? prior.parentID)?.kind,
                  name:
                    map.get(m.parentID ?? prior.parentID)?.fields?.name ??
                    map.get(m.parentID ?? prior.parentID)?.fields?.title ??
                    null,
                  order:
                    map.get(m.parentID ?? prior.parentID)?.fields?.sortOrder ??
                    null,
                }
              : null,
          before: Object.fromEntries(
            selected
              .filter((k) => Object.hasOwn(before, k))
              .map((k) => [k, before[k]]),
          ),
          after,
        };
      }),
    },
    contentHash: await planContentHash(mutations, preconditions),
  };
}

export function graphForGrant(entities, grant) {
  const map = graphIndex(entities),
    result = [];
  for (const e of map.values()) {
    if (e.deletedAt) continue;
    const root = rootOf(map, e.id);
    if (root.kind === "libraryItem") {
      if (!grant.scopes.includes("library:read")) continue;
    } else if (
      !grant.scopes.includes("trips:read") ||
      (!grant.tripIDs.includes(root.id) &&
        !grant.createdTripIDs.includes(root.id))
    )
      continue;
    if (
      ["photo", "attachment"].includes(e.kind) &&
      !grant.scopes.includes("attachments:read")
    )
      continue;
    result.push(visibleEntity(e, grant));
  }
  return result;
}

/** Policy recheck for a store's commit boundary. SQL adapters need the same
 * checks under their graph/grant locks; an earlier preview is no authority. */
export function assertMutationAccess(map, mutation, grant, newTripIDs = []) {
  const m = mutation;
  if (m.action === "create") {
    if (m.kind === "trip") has(grant, "trips:create");
    else if (m.kind === "libraryItem") has(grant, "library:write");
    else {
      const parent = map.get(m.parentID);
      if (
        !parent ||
        parent.deletedAt ||
        !graphSchema[m.kind]?.parents.includes(parent.kind)
      )
        fail("invalid_parent");
      const root = rootOf(map, parent.id);
      if (newTripIDs.includes(root.id)) has(grant, "trips:create");
      else authorizeEntity(map, parent.id, grant, { write: true });
    }
  } else {
    const current = authorizeEntity(map, m.id, grant, {
      write: true,
      includeDeleted: m.action === "restore",
    });
    if (current.kind !== m.kind) fail("invalid_kind");
    if (["delete", "restore"].includes(m.action))
      deletionRights(map, current, grant);
    if (m.action === "move") {
      const parent = authorizeEntity(map, m.parentID, grant, { write: true });
      if (
        !graphSchema[m.kind].parents.includes(parent.kind) ||
        rootOf(map, m.id).id !== rootOf(map, parent.id).id
      )
        fail("invalid_parent");
    }
  }
  if (["photo", "attachment"].includes(m.kind)) has(grant, "attachments:write");
  for (const [key, value] of Object.entries(m.fields ?? {})) {
    if (!Object.hasOwn(graphSchema[m.kind]?.fields ?? {}, key))
      fail("invalid_field");
    if (key === "assetLocalIdentifier" && value) fail("device_only_field");
    const defaultOnly =
      m.action === "create" &&
      (value === null || value === "" || value === false);
    if (privateFields.has(key) && !defaultOnly) has(grant, "private:write");
    if (assetFields.has(key) && !defaultOnly) has(grant, "attachments:write");
    if (preferenceFields.has(key) && !defaultOnly)
      has(grant, "preferences:write");
  }
}

export const planContentHash = (mutations, preconditions = []) =>
  hash(JSON.stringify(canonical({ mutations, preconditions })));
export function assertPlanPreconditions(map, compiled, grant) {
  for (const expected of compiled.preconditions ?? []) {
    const current = authorizeEntity(map, expected.id, grant, {
      write: expected.access === "write",
    });
    if (
      current.kind !== expected.kind ||
      current.version !== expected.version ||
      current.subtreeVersion !== expected.subtreeVersion
    )
      fail("subtree_conflict", 409);
  }
}
