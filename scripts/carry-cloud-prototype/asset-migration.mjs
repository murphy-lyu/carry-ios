// Synthetic-only migration experiment: verify all assets before publishing a new
// destination. This is not the application's production backup/migration format.
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, writeFileSync, mkdtempSync, existsSync, renameSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const checksum = bytes => createHash('sha256').update(bytes).digest('hex');
export function copyVerifiedAssets(manifest, source, destination) {
  if (!Array.isArray(manifest) || existsSync(destination)) throw new Error('Invalid migration destination');
  const names = new Set();
  for (const entry of manifest) {
    if (!entry || typeof entry.name !== 'string' || !/^[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$/.test(entry.name) || names.has(entry.name) ||
        !Number.isSafeInteger(entry.bytes) || entry.bytes < 0 || !/^[a-f0-9]{64}$/.test(entry.sha256)) throw new Error('Invalid asset manifest');
    names.add(entry.name);
  }
  const staging = mkdtempSync(join(dirname(destination), '.carry-migration-'));
  try {
    for (const entry of manifest) {
      const original = join(source, entry.name), target = join(staging, entry.name);
      if (!lstatSync(original).isFile()) throw new Error('Asset must be a regular file');
      const bytes = readFileSync(original);
      if (bytes.length !== entry.bytes || checksum(bytes) !== entry.sha256) throw new Error('Asset checksum mismatch');
      writeFileSync(target, bytes, { flag: 'wx', mode: 0o600 });
      const copied = readFileSync(target);
      if (copied.length !== entry.bytes || checksum(copied) !== entry.sha256) throw new Error('Copied asset checksum mismatch');
    }
    // Test-only publication. Production needs account ownership, concurrent
    // destination protection, disk-space/streaming limits and resumable transfer.
    renameSync(staging, destination);
    return { files: manifest.length, verified: true };
  } catch (error) { rmSync(staging, { recursive: true, force: true }); throw error; }
}
