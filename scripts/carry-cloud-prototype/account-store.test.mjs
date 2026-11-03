import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountStore } from './account-store.mjs';

function fixture(t, options) {
  const dir = mkdtempSync(join(tmpdir(), 'carry-cloud-risk-'));
  const path = join(dir, 'synthetic.sqlite');
  let store = new AccountStore(path, options);
  t.after(() => { store.close(); rmSync(dir, { recursive: true }); });
  return { get store() { return store; }, reopen() { store.close(); store = new AccountStore(path); return store; } };
}
const createTrip = (requestId = 'create-trip') => ({ requestId, mutations: [
  { id: 'trip', kind: 'trip', action: 'create', baseVersion: 0, patch: { name: 'Synthetic Tokyo', destination: 'Tokyo', departureDate: '2030-11-15', returnDate: '2030-11-17' } },
] });
const patchTrip = (requestId, baseVersion, patch) => ({ requestId, mutations: [{ id: 'trip', kind: 'trip', action: 'patch', baseVersion, patch }] });
const item = (id = 'item') => ({ id, kind: 'packingItem', action: 'create', baseVersion: 0, patch: { name: 'Synthetic charger', tripId: 'trip', quantity: 1, isPacked: false } });
const errorCode = code => error => error.code === code;

test('account writes persist without a phone and survive store reopening', t => {
  const f = fixture(t);
  const receipt = f.store.apply('alice', createTrip());
  assert.equal(receipt.status, 'saved_to_account');
  const persisted = f.reopen().get('alice', 'trip');
  assert.equal(persisted.data.name, 'Synthetic Tokyo');
  assert.equal(persisted.version, 1);
  assert.deepEqual(f.store.apply('alice', createTrip()), receipt);
  assert.equal(f.store.changes('alice').changes.length, 1);
});

test('two offline edits on different fields merge without overwriting either value', t => {
  const { store } = fixture(t); store.apply('alice', createTrip());
  store.apply('alice', patchTrip('phone-offline', 1, { name: 'My revised title' }));
  store.apply('alice', patchTrip('ai-other-field', 1, { destination: 'Yokohama' }));
  const result = store.get('alice', 'trip');
  assert.equal(result.data.name, 'My revised title');
  assert.equal(result.data.destination, 'Yokohama');
  assert.equal(result.version, 3);
});

test('same-field conflict preserves the remote and proposed values without advancing history', t => {
  const { store } = fixture(t); store.apply('alice', createTrip());
  store.apply('alice', patchTrip('phone', 1, { name: 'Phone title' }));
  assert.throws(() => store.apply('alice', patchTrip('ai', 1, { name: 'AI title' })), error => {
    assert.equal(error.code, 'conflict');
    assert.equal(error.details.current.data.name, 'Phone title');
    assert.equal(error.details.proposed.name, 'AI title');
    return true;
  });
  assert.equal(store.get('alice', 'trip').version, 2);
  assert.equal(store.changes('alice').changes.length, 2);
  store.apply('alice', patchTrip('ai-resolved', 2, { name: 'Merged decision' }));
  assert.equal(store.get('alice', 'trip').data.name, 'Merged decision');
});

test('an invalid item rolls back the entire itinerary, its change stream and receipt', t => {
  const { store } = fixture(t);
  const command = { requestId: 'whole-plan', mutations: [...createTrip().mutations,
    { id: 'stop', kind: 'stop', action: 'create', baseVersion: 0, patch: { tripId: 'trip', name: 'Synthetic museum' } },
    { ...item(), patch: { ...item().patch, quantity: 0 } }] };
  assert.throws(() => store.apply('alice', command), errorCode('invalid_item'));
  assert.equal(store.get('alice', 'trip'), null);
  assert.equal(store.get('alice', 'stop'), null);
  assert.deepEqual(store.changes('alice'), { changes: [], cursor: 0 });
  command.mutations[2] = item();
  assert.equal(store.apply('alice', command).entities.length, 3);
});

test('a storage exception before commit leaves no business data or success receipt', t => {
  const f = fixture(t, { beforeCommit() { throw new Error('Synthetic disk failure'); } });
  assert.throws(() => f.store.apply('alice', createTrip()), /Synthetic disk failure/);
  assert.equal(f.reopen().get('alice', 'trip'), null);
  assert.equal(f.store.changes('alice').changes.length, 0);
  assert.equal(f.store.apply('alice', createTrip()).status, 'saved_to_account');
});

test('lost response and duplicate complete-plan submission create no duplicate rows or changes', t => {
  const f = fixture(t), command = { requestId: 'whole-plan', mutations: [...createTrip().mutations, item()] };
  const receipt = f.store.apply('alice', command);
  assert.deepEqual(f.reopen().apply('alice', command), receipt);
  assert.equal(f.store.changes('alice').changes.length, 2);
  assert.equal(f.store.get('alice', 'item').data.quantity, 1);
  assert.throws(() => f.store.apply('alice', { ...command, mutations: createTrip().mutations }), errorCode('request_id_reused'));
});

test('account-scoped queries, commands, receipts and parent references cannot cross accounts', t => {
  const { store } = fixture(t); store.apply('alice', createTrip());
  assert.equal(store.get('bob', 'trip'), null);
  assert.deepEqual(store.changes('bob'), { changes: [], cursor: 0 });
  assert.throws(() => store.apply('bob', patchTrip('foreign-edit', 1, { name: 'Wrong owner' })), errorCode('entity_not_found'));
  assert.throws(() => store.apply('bob', { requestId: 'foreign-parent', mutations: [item()] }), errorCode('parent_not_found'));
  store.apply('bob', createTrip());
  store.apply('bob', patchTrip('own-edit', 1, { name: 'Bob trip' }));
  assert.equal(store.get('alice', 'trip').data.name, 'Synthetic Tokyo');
  assert.equal(store.get('bob', 'trip').data.name, 'Bob trip');
});

test('deletion knowledge survives restart and rejects late offline edits or recreation', t => {
  const f = fixture(t); f.store.apply('alice', createTrip());
  f.store.apply('alice', { requestId: 'delete', mutations: [{ id: 'trip', kind: 'trip', action: 'delete', baseVersion: 1 }] });
  f.reopen();
  assert.throws(() => f.store.apply('alice', patchTrip('late-offline', 1, { name: 'Should not return' })), errorCode('deleted_entity'));
  assert.throws(() => f.store.apply('alice', createTrip('late-create')), errorCode('deleted_entity'));
  assert.equal(f.store.get('alice', 'trip').deleted, true);
  assert.equal(f.store.changes('alice').changes.at(-1).entity.deleted, true);
});

test('delete refuses stale versions and parents with children instead of orphaning rows', t => {
  const { store } = fixture(t); store.apply('alice', createTrip());
  store.apply('alice', patchTrip('rename', 1, { name: 'Current' }));
  const deletion = { requestId: 'delete', mutations: [{ id: 'trip', kind: 'trip', action: 'delete', baseVersion: 1 }] };
  assert.throws(() => store.apply('alice', deletion), errorCode('conflict'));
  store.apply('alice', { requestId: 'item', mutations: [item()] });
  deletion.mutations[0].baseVersion = 2;
  assert.throws(() => store.apply('alice', deletion), errorCode('parent_has_children'));
  assert.equal(store.get('alice', 'trip').deleted, false);
});

test('catch-up reads are paginated, account-scoped and replayable after client interruption', t => {
  const { store } = fixture(t); store.apply('alice', createTrip());
  store.apply('bob', createTrip());
  store.apply('alice', patchTrip('name', 1, { name: 'Version two' }));
  const page = store.changes('alice', 0, 1);
  assert.deepEqual(store.changes('alice', 0, 1), page);
  const next = store.changes('alice', page.cursor, 1);
  assert.equal(next.changes[0].entity.data.name, 'Version two');
  assert.equal(next.changes[0].entity.version, 2);
  assert.equal(store.changes('alice', next.cursor).changes.length, 0);
  assert.throws(() => store.changes('alice', -1), errorCode('invalid_cursor'));
});

test('dates and packing state are explicit and invalid changes preserve prior data', t => {
  const { store } = fixture(t); store.apply('alice', createTrip());
  assert.throws(() => store.apply('alice', patchTrip('bad-date', 1, { departureDate: '2030-02-31' })), errorCode('invalid_date'));
  assert.throws(() => store.apply('alice', patchTrip('bad-range', 1, { departureDate: '2031-01-01' })), errorCode('invalid_date_range'));
  store.apply('alice', { requestId: 'item', mutations: [item()] });
  const packed = { requestId: 'pack', mutations: [{ id: 'item', kind: 'packingItem', action: 'patch', baseVersion: 1, patch: { isPacked: true } }] };
  store.apply('alice', packed); store.apply('alice', packed);
  assert.equal(store.get('alice', 'item').data.isPacked, true);
  assert.equal(store.get('alice', 'item').version, 2);
  assert.equal(store.get('alice', 'trip').data.departureDate, '2030-11-15');
});
