import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { inspectAssetResponse, inspectStoredAsset } from './asset-storage.mjs';
const bytes = new TextEncoder().encode('synthetic private attachment');
const expected = { byteCount: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };

test('storage inspection hashes actual streamed bytes and returns trusted measurements', async () => {
  let offset = 0;
  const stream = new ReadableStream({ pull(controller) {
    if (offset === bytes.length) controller.close();
    else { controller.enqueue(bytes.slice(offset,offset+3)); offset = Math.min(bytes.length,offset+3); }
  } });
  assert.deepEqual(await inspectAssetResponse(new Response(stream),expected),expected);
});

test('storage inspection rejects large declared length without consuming its body', async () => {
  let read = 0, cancelled = false;
  const stream = new ReadableStream({ pull(controller) { read++; controller.enqueue(new Uint8Array(1024)); }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
  await assert.rejects(inspectAssetResponse(new Response(stream,{headers:{'content-length':String(64*1024*1024)}}),expected), /asset_integrity_mismatch/);
  assert.equal(read,0); assert.equal(cancelled,true);
});

test('chunked overflow stops and cancels at the first excess chunk', async () => {
  let read = 0, cancelled = false;
  const stream = new ReadableStream({ pull(controller) { read++; controller.enqueue(new Uint8Array(16)); }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
  await assert.rejects(inspectAssetResponse(new Response(stream),expected), /asset_integrity_mismatch/);
  assert.equal(read,2); assert.equal(cancelled,true);
});

test('same-size corruption and truncated files never count as verified', async () => {
  await assert.rejects(inspectAssetResponse(new Response(new Uint8Array(bytes.length)),expected), /asset_integrity_mismatch/);
  await assert.rejects(inspectAssetResponse(new Response(bytes.slice(0,4)),expected), /asset_integrity_mismatch/);
});

test('storage outage, unfinished upload and cancellation remain distinct from corruption', async () => {
  await assert.rejects(inspectAssetResponse(new Response(null,{status:503}),expected), /asset_storage_unavailable/);
  await assert.rejects(inspectAssetResponse(new Response(null,{status:404}),expected), /asset_not_uploaded/);
  const abort = new AbortController(); abort.abort();
  await assert.rejects(inspectAssetResponse(new Response(bytes),expected,abort.signal), error => error.name === 'AbortError');
});

test('storage requests use only the configured origin and immutable owned path', async () => {
  const manifest = { ...expected, accountID: randomUUID().toUpperCase(), id: randomUUID().toUpperCase(), url: 'https://invalid.example/trap' };
  const result = await inspectStoredAsset({ projectURL:'https://synthetic.storage-qa.supabase.co', serviceKey:'synthetic-server-only', manifest,
    fetcher: async (url,options) => {
      assert.equal(url.hostname,'synthetic.storage-qa.storage.supabase.co');
      assert.equal(url.pathname,`/storage/v1/object/authenticated/carry-account-assets/${manifest.accountID.toLowerCase()}/${manifest.id.toLowerCase()}/${manifest.sha256}`);
      assert.equal(url.search,''); assert.equal(options.redirect,'error');
      assert.equal(options.headers.Authorization,'Bearer synthetic-server-only');
      assert.ok(options.signal instanceof AbortSignal);
      return new Response(bytes);
    } });
  assert.deepEqual(result,expected);
  await assert.rejects(inspectStoredAsset({projectURL:'https://invalid.example',serviceKey:'synthetic',manifest:{...manifest,id:'../victim'}}), /invalid_asset_configuration/);
});
