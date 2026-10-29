// Synthetic loopback TUS fixture. Never deploy or accept production identities.
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
if (process.env.CARRY_ASSET_QA !== 'synthetic-only') throw new Error('Synthetic opt-in required');
const prefixes = ['/storage/v1/upload/resumable', '/functions/v1/carry-assets/tus'];
const fixtures = new Map(), uploads = new Map();
const reply = (res, status, headers = {}, body = '') => {
  res.writeHead(status, { 'Tus-Resumable': '1.0.0', ...headers }); res.end(body);
};
async function body(req, limit) {
  const chunks = []; let length = 0;
  for await (const chunk of req) { length += chunk.length; if (length > limit) throw new Error('oversized'); chunks.push(chunk); }
  return Buffer.concat(chunks);
}
const server = http.createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://127.0.0.1').pathname;
    const prefix = prefixes.find(value => path === value || path.startsWith(value + '/'));
    if (path === '/__fixture' && req.method === 'POST') {
      const { id, mode = 'normal' } = JSON.parse(await body(req, 1024));
      if (!/^[0-9a-f-]{36}$/i.test(id) || !['normal', 'drop_once', 'expired_once', 'bad_location', 'redirect', 'bad_offset_once', 'verify_outage'].includes(mode)) return reply(res, 400);
      fixtures.set(id.toLowerCase(), { mode, creations: 0, heads: 0, chunks: [], offset: 0, dropped: false, expired: false, trap: 0, tokenARequests: 0, tokenBRequests: 0 });
      return reply(res, 201);
    }
    if (path.startsWith('/__stats/')) {
      const fixture = fixtures.get(path.slice('/__stats/'.length).toLowerCase());
      return reply(res, fixture ? 200 : 404, { 'Content-Type': 'application/json' }, JSON.stringify(fixture ?? {}));
    }
    if (path.startsWith('/__recover/') && req.method === 'POST') {
      const fixture=fixtures.get(path.slice('/__recover/'.length).toLowerCase());
      if(!fixture)return reply(res,404);fixture.mode='normal';return reply(res,200);
    }
    if (['/functions/v1/carry-assets/reserve','/functions/v1/carry-assets/verify'].includes(path) && req.method==='POST') {
      if (!['Bearer synthetic-asset-token-a', 'Bearer synthetic-asset-token-b'].includes(req.headers.authorization)) return reply(res,401);
      const input=JSON.parse(await body(req,8192)),fixture=fixtures.get(String(input.id).toLowerCase());
      if(!fixture)return reply(res,404);
      const json=value=>reply(res,200,{'Content-Type':'application/json'},JSON.stringify(value));
      if(path.endsWith('/reserve')) {
        if(fixture.metadata&&(Object.keys(fixture.metadata).length!==Object.keys(input).length||
          Object.keys(fixture.metadata).some(key=>fixture.metadata[key]!==input[key])))return reply(res,409);
        fixture.metadata=input;fixture.reserves=(fixture.reserves??0)+1;
        return json({id:input.id,status:fixture.verified?'verified':'pending'});
      }
      fixture.verifications=(fixture.verifications??0)+1;
      if(fixture.mode==='verify_outage')return reply(res,503);
      if(!fixture.metadata||fixture.offset!==fixture.metadata.byteCount||fixture.sha256!==fixture.metadata.sha256)return reply(res,422);
      fixture.verified=true;return json({id:input.id,status:'verified'});
    }
    if (path === '/__trap') { for (const f of fixtures.values()) f.trap++; return reply(res, 500); }
    if (!prefix) return reply(res, 404);
    if (!['Bearer synthetic-asset-token-a', 'Bearer synthetic-asset-token-b'].includes(req.headers.authorization)) return reply(res, 401);
    if (req.headers['tus-resumable'] !== '1.0.0') return reply(res, 412);
    if (path === prefix && req.method === 'POST') {
      const metadata = Object.fromEntries(String(req.headers['upload-metadata'] ?? '').split(',').map(pair => {
        const [key, value] = pair.split(' '); return [key, Buffer.from(value ?? '', 'base64').toString()];
      }));
      const [account, id, digest, extra] = String(metadata.objectName).split('/');
      const fixture = fixtures.get(id), size = Number(req.headers['upload-length']);
      if (!fixture || extra || !/^[0-9a-f-]{36}$/.test(account) || !/^[0-9a-f]{64}$/.test(digest) || metadata.bucketName !== 'carry-account-assets' || !Number.isInteger(size) || size < 1 || size > 50 * 1024 * 1024) return reply(res, 400);
      fixture.creations++;
      fixture[req.headers.authorization.endsWith('-a') ? 'tokenARequests' : 'tokenBRequests']++;
      if (fixture.mode === 'bad_location') return reply(res, 201, { Location: 'https://invalid.example/storage/v1/upload/resumable/trap' });
      if (fixture.mode === 'redirect') return reply(res, 307, { Location: '/__trap' });
      const location = `${prefix}/${randomUUID()}`;
      uploads.set(location, { fixture, size, offset: 0, hash: createHash('sha256') });
      return reply(res, 201, { Location: location });
    }
    const upload = uploads.get(path);
    if (!upload) return reply(res, 404);
    const f = upload.fixture;
    f[req.headers.authorization.endsWith('-a') ? 'tokenARequests' : 'tokenBRequests']++;
    if (req.method === 'HEAD') {
      f.heads++;
      if (f.mode === 'expired_once' && f.dropped && !f.expired) { f.expired = true; uploads.delete(path); return reply(res, 410); }
      return reply(res, 200, { 'Upload-Offset': upload.offset, 'Upload-Length': upload.size });
    }
    if (req.method === 'PATCH') {
      if (Number(req.headers['upload-offset']) !== upload.offset) return reply(res, 409);
      if (req.headers['content-type'] !== 'application/offset+octet-stream') return reply(res, 415);
      const chunk = await body(req, 6 * 1024 * 1024);
      if (chunk.length !== Math.min(6 * 1024 * 1024, upload.size - upload.offset)) return reply(res, 400);
      upload.hash.update(chunk); upload.offset += chunk.length;
      f.offset = upload.offset; f.chunks.push(chunk.length); f.sha256 = upload.hash.copy().digest('hex');
      if (['drop_once', 'expired_once'].includes(f.mode) && !f.dropped) { f.dropped = true; res.destroy(); return; }
      if (f.mode === 'bad_offset_once' && !f.dropped) { f.dropped = true; return reply(res, 204, { 'Upload-Offset': upload.size + 1 }); }
      return reply(res, 204, { 'Upload-Offset': upload.offset });
    }
    return reply(res, 405);
  } catch { if (!res.destroyed) reply(res, 400); }
});
server.listen(8892, '127.0.0.1', () => process.stdout.write('Synthetic asset fixture listening on loopback:8892\n'));
