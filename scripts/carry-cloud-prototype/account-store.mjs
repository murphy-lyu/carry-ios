// Isolated algorithm prototype; not an authenticated API or a production schema.
// Test callers supply synthetic account IDs. Never connect this to user data.
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';

const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const hash = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
export class Rejected extends Error {
  constructor(code, details = {}) { super(code); this.code = code; this.details = details; }
}
const reject = (code, details) => { throw new Rejected(code, details); };

export class AccountStore {
  constructor(path, { beforeCommit = () => {} } = {}) {
    this.db = new DatabaseSync(path);
    this.beforeCommit = beforeCommit;
    this.db.exec(`PRAGMA journal_mode=WAL;
      CREATE TABLE IF NOT EXISTS entities (
        account TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL,
        version INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
        data TEXT NOT NULL, field_versions TEXT NOT NULL,
        PRIMARY KEY(account, id)
      );
      CREATE TABLE IF NOT EXISTS receipts (
        account TEXT NOT NULL, request_id TEXT NOT NULL, digest TEXT NOT NULL, result TEXT NOT NULL,
        PRIMARY KEY(account, request_id)
      );
      CREATE TABLE IF NOT EXISTS changes (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, entity TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS changes_account_seq ON changes(account, seq);`);
  }
  close() { this.db.close(); }
  get(account, id) {
    const row = this.db.prepare('SELECT * FROM entities WHERE account=? AND id=?').get(account, id);
    return row ? { id: row.id, kind: row.kind, version: row.version, deleted: Boolean(row.deleted), data: JSON.parse(row.data), fieldVersions: JSON.parse(row.field_versions) } : null;
  }
  changes(account, cursor = 0, limit = 100) {
    if (!Number.isSafeInteger(cursor) || cursor < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) reject('invalid_cursor');
    const rows = this.db.prepare('SELECT seq,entity FROM changes WHERE account=? AND seq>? ORDER BY seq LIMIT ?').all(account, cursor, limit);
    return { changes: rows.map(row => ({ seq: row.seq, entity: JSON.parse(row.entity) })), cursor: rows.at(-1)?.seq ?? cursor };
  }
  apply(account, command) {
    if (typeof account !== 'string' || !account || !command || typeof command.requestId !== 'string' || !command.requestId ||
        !Array.isArray(command.mutations) || !command.mutations.length || command.mutations.length > 100) reject('invalid_command');
    const digest = hash(command);
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const prior = this.db.prepare('SELECT digest,result FROM receipts WHERE account=? AND request_id=?').get(account, command.requestId);
      if (prior) {
        if (prior.digest !== digest) reject('request_id_reused');
        this.db.exec('COMMIT');
        return JSON.parse(prior.result);
      }
      const results = command.mutations.map(mutation => this.mutate(account, mutation));
      const result = { status: 'saved_to_account', entities: results };
      this.db.prepare('INSERT INTO receipts VALUES(?,?,?,?)').run(account, command.requestId, digest, JSON.stringify(result));
      this.beforeCommit();
      this.db.exec('COMMIT');
      return result;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  mutate(account, mutation) {
    const { id, kind, baseVersion, patch, action } = mutation ?? {};
    if (typeof id !== 'string' || !id || !['trip', 'stop', 'packingItem'].includes(kind) ||
        !['create', 'patch', 'delete'].includes(action) || !Number.isSafeInteger(baseVersion) || baseVersion < 0) reject('invalid_mutation');
    const prior = this.get(account, id);
    if (action === 'create') {
      if (baseVersion !== 0 || prior) reject(prior?.deleted ? 'deleted_entity' : 'entity_exists');
    } else {
      if (!prior || prior.kind !== kind) reject('entity_not_found');
      if (prior.deleted) reject('deleted_entity');
      if (baseVersion < 1 || baseVersion > prior.version) reject('invalid_version');
    }
    let data, fieldVersions;
    const version = (prior?.version ?? 0) + 1;
    if (action === 'delete') {
      if (baseVersion !== prior.version) reject('conflict', { fields: ['*'], current: prior });
      // A product implementation also needs explicit subtree deletion semantics.
      if (this.db.prepare('SELECT 1 FROM entities WHERE account=? AND deleted=0 AND json_extract(data,\'$.tripId\')=? LIMIT 1').get(account, id)) reject('parent_has_children');
      data = prior.data; fieldVersions = prior.fieldVersions;
    } else {
      if (!patch || Array.isArray(patch) || typeof patch !== 'object' || !Object.keys(patch).length) reject('invalid_patch');
      const allowed = kind === 'trip' ? ['name', 'destination', 'departureDate', 'returnDate']
        : kind === 'stop' ? ['name', 'tripId', 'note'] : ['name', 'tripId', 'quantity', 'isPacked'];
      if (Object.keys(patch).some(field => !allowed.includes(field))) reject('unknown_field');
      const conflicts = Object.keys(patch).filter(field => (prior?.fieldVersions[field] ?? 0) > baseVersion);
      if (conflicts.length) reject('conflict', { fields: conflicts, current: prior, proposed: patch });
      data = { ...prior?.data, ...patch };
      if (typeof data.name !== 'string' || !data.name.trim() || data.name.length > 500) reject('invalid_name');
      if (kind === 'trip') {
        for (const field of ['departureDate', 'returnDate']) if (data[field] != null) {
          if (typeof data[field] !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(data[field]) ||
              !Number.isFinite(Date.parse(data[field])) || new Date(data[field]).toISOString().slice(0,10) !== data[field]) reject('invalid_date');
        }
        if (Boolean(data.departureDate) !== Boolean(data.returnDate) || data.departureDate > data.returnDate) reject('invalid_date_range');
      } else {
        if (prior && data.tripId !== prior.data.tripId) reject('immutable_parent');
        if (typeof data.tripId !== 'string') reject('invalid_parent');
        const parent = this.get(account, data.tripId);
        if (!parent || parent.kind !== 'trip' || parent.deleted) reject('parent_not_found');
        if (kind === 'packingItem' && (!Number.isInteger(data.quantity) || data.quantity < 1 || data.quantity > 999 || typeof data.isPacked !== 'boolean')) reject('invalid_item');
        if (kind === 'stop' && data.note != null && (typeof data.note !== 'string' || data.note.length > 2000)) reject('invalid_note');
      }
      fieldVersions = { ...prior?.fieldVersions, ...Object.fromEntries(Object.keys(patch).map(field => [field, version])) };
    }
    this.db.prepare(`INSERT INTO entities VALUES(?,?,?,?,?,?,?) ON CONFLICT(account,id)
      DO UPDATE SET version=excluded.version,deleted=excluded.deleted,data=excluded.data,field_versions=excluded.field_versions`)
      .run(account, id, kind, version, action === 'delete' ? 1 : 0, JSON.stringify(data), JSON.stringify(fieldVersions));
    const result = this.get(account, id);
    this.db.prepare('INSERT INTO changes(account,entity) VALUES(?,?)').run(account, JSON.stringify(result));
    return result;
  }
}
