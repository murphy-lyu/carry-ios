import { createHash } from 'node:crypto';
import { openStoredAsset } from '../carry-account-service/asset-download.mjs';
import { AIFailure, fail } from './security.mjs';

// Receives only server-selected verified ledger metadata. The caller owns the
// live grant/entity check; neither an AI argument nor a browser chooses a URL.
export function createAccountAssets({ projectURL, serviceKey, fetcher = fetch }) {
  async function open(manifest, { offset = 0, limit = manifest.byteCount, signal, range = false } = {}) {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 ||
        offset + limit > manifest.byteCount) fail('invalid_range');
    let response;
    try { response = await openStoredAsset({ projectURL, serviceKey, manifest,
      signal: AbortSignal.any([signal ?? new AbortController().signal, AbortSignal.timeout(60000)]),
      fetcher: (url, options) => fetcher(url, { ...options, headers: { ...options.headers,
        ...(range ? { Range: `bytes=${offset}-${offset + limit - 1}` } : {}) } }) });
    } catch { fail('asset_storage_unavailable',503); }
    const contentRange = response.headers.get('Content-Range'), length = response.headers.get('Content-Length'),
      encoding = response.headers.get('Content-Encoding');
    const expectedRange = `bytes ${offset}-${offset + limit - 1}/${manifest.byteCount}`;
    if (!response.body || response.status !== (range ? 206 : 200) ||
        (range && contentRange !== expectedRange) || (!range && contentRange !== null) ||
        (length !== null && (!/^\d+$/.test(length) || Number(length) !== limit)) ||
        (encoding !== null && encoding !== 'identity')) {
      await response.body?.cancel().catch(() => {}); fail('asset_storage_unavailable', 503);
    }
    return response;
  }
  async function stream(manifest, { signal, authorize = async () => {} } = {}) {
    await authorize();
    const response = await open(manifest, { signal });
    try { await authorize(); } catch(error) { await response.body.cancel().catch(()=>{}); throw error; }
    const reader = response.body.getReader(), hash = createHash('sha256');
    let total = 0, ended = false;
    async function stop() { if (!ended) { ended = true; await reader.cancel().catch(() => {}); reader.releaseLock(); } }
    return new ReadableStream({
      async pull(controller) {
        try {
          signal?.throwIfAborted(); await authorize();
          const { done, value } = await reader.read(); signal?.throwIfAborted(); await authorize();
          if (done) {
            if (total !== manifest.byteCount || hash.digest('hex') !== manifest.sha256) throw Error('integrity');
            ended = true; reader.releaseLock(); controller.close(); return;
          }
          total += value.byteLength;
          if (total > manifest.byteCount) throw Error('overflow');
          hash.update(value); controller.enqueue(value);
        } catch { await stop(); controller.error(new Error('asset_download_failed')); }
      }, async cancel() { await stop(); },
    }, { highWaterMark: 0 });
  }
  async function read(manifest, { offset, limit, signal } = {}) {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 65536)
      fail('invalid_range');
    if (offset >= manifest.byteCount) return new Uint8Array();
    const count = Math.min(limit, manifest.byteCount - offset), response = await open(manifest, { offset, limit: count, signal, range: true });
    const reader = response.body.getReader(), output = new Uint8Array(count); let total = 0;
    try {
      while (true) {
        signal?.throwIfAborted(); const { done, value } = await reader.read();
        if (done) break;
        if (total + value.byteLength > count) fail('asset_storage_unavailable', 503);
        output.set(value, total); total += value.byteLength;
      }
      if (total !== count) fail('asset_storage_unavailable', 503);
      return output;
    } catch(error) { if(error instanceof AIFailure)throw error;fail('asset_storage_unavailable',503); } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  }
  return { read, stream };
}
