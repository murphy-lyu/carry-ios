import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checksum, copyVerifiedAssets } from './asset-migration.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'carry-assets-risk-'));
  t.after(() => rmSync(root, { recursive: true }));
  const source = join(root, 'original'), destination = join(root, 'migrated');
  mkdirSync(source);
  const manifest = ['synthetic-cover.bin', 'synthetic-ticket.bin'].map((name, index) => {
    const bytes = Buffer.from('Synthetic file data only: ' + index);
    writeFileSync(join(source, name), bytes);
    return { name, bytes: bytes.length, sha256: checksum(bytes) };
  });
  return { root, source, destination, manifest };
}
test('all synthetic files are verified before publication and source bytes remain unchanged', t => {
  const f = fixture(t);
  assert.deepEqual(copyVerifiedAssets(f.manifest, f.source, f.destination), { files: 2, verified: true });
  for (const entry of f.manifest) {
    assert.equal(checksum(readFileSync(join(f.source, entry.name))), entry.sha256);
    assert.deepEqual(readFileSync(join(f.destination, entry.name)), readFileSync(join(f.source, entry.name)));
  }
  assert.throws(() => copyVerifiedAssets(f.manifest, f.source, f.destination), /destination/);
});
test('a late corrupt file cannot publish a partial destination or damage original data', t => {
  const f = fixture(t);
  writeFileSync(join(f.source, f.manifest[1].name), 'Synthetic corruption');
  assert.throws(() => copyVerifiedAssets(f.manifest, f.source, f.destination), /checksum/);
  assert.equal(existsSync(f.destination), false);
  assert.deepEqual(readdirSync(f.root), ['original']);
  assert.equal(checksum(readFileSync(join(f.source, f.manifest[0].name))), f.manifest[0].sha256);
});
test('duplicate asset names and traversal paths fail before creating migration staging', t => {
  const f = fixture(t);
  assert.throws(() => copyVerifiedAssets([...f.manifest, f.manifest[0]], f.source, f.destination), /manifest/);
  assert.throws(() => copyVerifiedAssets([{ ...f.manifest[0], name: '../outside.bin' }], f.source, f.destination), /manifest/);
  assert.deepEqual(readdirSync(f.root), ['original']);
});
