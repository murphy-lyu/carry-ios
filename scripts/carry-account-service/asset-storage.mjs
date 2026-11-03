import { createHash } from 'node:crypto';

export class AssetInspectionError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const maximumBytes = 50 * 1024 * 1024;

/** Consume bytes incrementally: a client's hash, Content-Length or successful
 * upload acknowledgement alone never proves a stored asset was transferred. */
export async function inspectAssetResponse(response, expected, signal) {
  if (!Number.isSafeInteger(expected.byteCount) || expected.byteCount < 1 || expected.byteCount > maximumBytes ||
      !/^[0-9a-f]{64}$/.test(expected.sha256)) throw new AssetInspectionError('invalid_asset_manifest');
  if (response.status !== 200) {
    await response.body?.cancel();
    throw new AssetInspectionError(response.status === 404 ? 'asset_not_uploaded' : 'asset_storage_unavailable');
  }
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^[0-9]+$/.test(declared) || Number(declared) !== expected.byteCount)) {
    await response.body?.cancel();
    throw new AssetInspectionError('asset_integrity_mismatch');
  }
  if (!response.body) throw new AssetInspectionError('asset_integrity_mismatch');
  const reader = response.body.getReader(), hash = createHash('sha256');
  let bytes = 0, finished = false;
  try {
    while (true) {
      signal?.throwIfAborted();
      const { value, done } = await reader.read();
      signal?.throwIfAborted();
      if (done) { finished = true; break; }
      bytes += value.byteLength;
      if (bytes > expected.byteCount) throw new AssetInspectionError('asset_integrity_mismatch');
      hash.update(value);
    }
    const sha256 = hash.digest('hex');
    if (bytes !== expected.byteCount || sha256 !== expected.sha256) throw new AssetInspectionError('asset_integrity_mismatch');
    return { sha256, byteCount: bytes };
  } finally {
    if (!finished) await reader.cancel();
    reader.releaseLock();
  }
}

/** manifest comes only from the private ledger, never an HTTP-provided URL.
 * The caller must repeat the account/session/deletion check in its final DB
 * transaction after this asynchronous read. No identity or quota is changed
 * here. Only integrity failures qualify for quarantine; outages retain retry. */
export async function inspectStoredAsset({ projectURL, serviceKey, manifest, fetcher = fetch, signal = AbortSignal.timeout(15000) }) {
  const project = new URL(projectURL);
  if (project.protocol !== 'https:' || project.username || project.password || project.search || project.hash ||
      !['', '/'].includes(project.pathname) || !serviceKey || !uuid(manifest?.accountID) || !uuid(manifest?.id) ||
      !/^[0-9a-f]{64}$/.test(manifest?.sha256) || !Number.isSafeInteger(manifest?.byteCount) ||
      manifest.byteCount < 1 || manifest.byteCount > maximumBytes) throw new AssetInspectionError('invalid_asset_configuration');
  if (project.hostname.endsWith('.supabase.co') && !project.hostname.endsWith('.storage.supabase.co')) {
    project.hostname = `${project.hostname.slice(0,-'.supabase.co'.length)}.storage.supabase.co`;
  }
  project.pathname = `/storage/v1/object/authenticated/carry-account-assets/${manifest.accountID.toLowerCase()}/${manifest.id.toLowerCase()}/${manifest.sha256}`;
  const response = await fetcher(project, { method: 'GET', redirect: 'error', signal,
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache' } });
  return inspectAssetResponse(response, manifest, signal);
}
