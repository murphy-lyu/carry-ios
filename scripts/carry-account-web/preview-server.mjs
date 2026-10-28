// Loopback visual preview only. Cannot start identity exchange, consent, logout,
// data requests or an Apple redirect, even if someone presses the button.
import http from 'node:http';
import { fixtureRuntime, origin } from './qa-runtime.mjs';
const mf = await fixtureRuntime();
const server = http.createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://127.0.0.1');
    if (req.method !== 'GET' || !['/login', '/account.css'].includes(path.pathname)) {
      res.writeHead(403); res.end('Synthetic visual preview: identity exchange disabled.'); return;
    }
    const locale = path.searchParams.get('lang') ?? 'zh-Hans';
    const response = await mf.dispatchFetch(origin + path.pathname, { headers: { 'Accept-Language': locale } });
    res.writeHead(response.status, Object.fromEntries([...response.headers].filter(([name]) => name !== 'set-cookie')));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch { res.writeHead(503); res.end('Preview unavailable'); }
});
server.listen(0, '127.0.0.1', () => console.log(`Synthetic Carry web preview: http://127.0.0.1:${server.address().port}/login`));
async function stop() { server.close(); await mf.dispose(); }
process.once('SIGINT', () => void stop()); process.once('SIGTERM', () => void stop());
