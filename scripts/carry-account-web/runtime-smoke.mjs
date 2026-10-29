// Real workerd + bundled Supabase SSR. Synthetic configuration only: never
// permit outbound requests or point this harness at a deployed account.
import assert from 'node:assert/strict';
import { fixtureRuntime, origin } from './qa-runtime.mjs';
const mf = await fixtureRuntime();
try {
  const login = await mf.dispatchFetch(origin + '/login', { headers: { 'Accept-Language': 'zh-CN' } });
  assert.equal(login.status, 200);
  const html = await login.text();
  assert.ok(html.includes('登录启程'));
  const csrf = /name="csrf" value="([^"]+)"/.exec(html)[1];
  const cookies = login.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
  const started = await mf.dispatchFetch(origin + '/auth/apple/start', { method: 'POST', redirect: 'manual',
    headers: { Cookie: cookies, Origin: origin, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ csrf, continue: '/' }).toString() });
  assert.equal(started.status, 303);
  const target = new URL(started.headers.get('Location'));
  assert.equal(target.origin, 'https://appleid.apple.com');
  assert.equal(target.searchParams.get('redirect_uri'), origin + '/auth/apple/callback');
  assert.match(started.headers.get('Set-Cookie'), /HttpOnly/);
  const denied = await mf.dispatchFetch(origin + '/auth/apple/start', { method: 'POST', redirect: 'manual',
    headers: { Cookie: cookies, Origin: 'https://evil.invalid', 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ csrf }).toString() });
  assert.equal(denied.status, 403);
  console.log('workerd login, encrypted cookies, exact Apple redirect and CSRF rejection: 4/4 passed; no outbound traffic');
} finally { await mf.dispose(); }
