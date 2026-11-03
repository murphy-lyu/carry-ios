// Real workerd + bundled Supabase SSR. Synthetic configuration only: never
// permit outbound requests or point this harness at a deployed account.
import assert from 'node:assert/strict';
import { fixtureRuntime, origin } from './qa-runtime.mjs';
const mf = await fixtureRuntime();
try {
  const login = await mf.dispatchFetch(origin + '/login', { headers: { 'Accept-Language': 'zh-CN' } });
  assert.equal(login.status, 200);
  // Fetch Standard: navigate-mode POST with no-referrer serializes Origin as
  // null. Keep a same-origin policy so the real HTML form passes exact CSRF.
  assert.equal(login.headers.get('Referrer-Policy'), 'same-origin');
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

// Exercise the actual Supabase SDK fetch in workerd, not just /login and the
// Apple redirect. The original redirect:error failed before this stub was hit.
for (const mode of ['invalid-token', 'redirect', 'success']) {
  const redirectUpstream = mode === 'redirect', success = mode === 'success';
  const user = { id: '00000000-0000-4000-8000-000000000001', email: 'synthetic@example.invalid',
    aud: 'authenticated', app_metadata: { provider: 'apple', providers: ['apple'] }, user_metadata: {},
    created_at: '2026-01-01T00:00:00Z', identities: [], is_anonymous: false };
  const token = [ { alg: 'none' }, { sub: user.id, exp: Math.floor(Date.now() / 1000) + 3600 } ]
    .map(value => Buffer.from(JSON.stringify(value)).toString('base64url')).join('.') + '.synthetic';
  let calls = 0;
  const runtime = await fixtureRuntime({ onAuthRequest: () => { calls++; },
    enrollmentFixture: success ? user : null,
    authTokenResponse: () => redirectUpstream
      ? new Response(null, { status: 302, headers: { Location: 'https://must-never-follow.invalid' } })
      : success ? Response.json({ access_token: token, refresh_token: 'synthetic-refresh', token_type: 'bearer', expires_in: 3600, user })
      : Response.json({ error: 'invalid_request', error_description: 'Bad ID token' }, { status: 400 }),
  });
  try {
    const login = await runtime.dispatchFetch(origin + '/login');
    const csrf = /name="csrf" value="([^"]+)"/.exec(await login.text())[1];
    const started = await runtime.dispatchFetch(origin + '/auth/apple/start', { method: 'POST', redirect: 'manual',
      headers: { Cookie: login.headers.getSetCookie().map(v => v.split(';')[0]).join('; '), Origin: origin,
        'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ csrf }).toString() });
    const state = new URL(started.headers.get('Location')).searchParams.get('state');
    const result = await runtime.dispatchFetch(origin + '/auth/apple/callback', { method: 'POST', redirect: 'manual',
      headers: { Cookie: started.headers.getSetCookie().map(v => v.split(';')[0]).join('; '),
        'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: new URLSearchParams({ state, code: 'synthetic-never-exchanged', id_token: 'synthetic-invalid-apple-token' }).toString() });
    assert.equal(calls, 1, 'the actual SDK must reach the fixed upstream once, without following redirects');
    if (success) {
      assert.equal(result.status, 303);
      const cookies = result.headers.getSetCookie().map(v => v.split(';')[0]).join('; ');
      assert.ok(cookies.includes('__Host-carry-session'));
      const home = await runtime.dispatchFetch(origin + '/', { headers: { Cookie: cookies } });
      assert.equal(home.status, 200);
      assert.ok((await home.text()).includes(user.email));
    } else {
      assert.equal(result.status, redirectUpstream ? 503 : 401);
      assert.equal((await result.json()).error, redirectUpstream ? 'identity_unavailable' : 'invalid_apple_identity');
      assert.ok(!result.headers.getSetCookie().some(v => v.startsWith('__Host-carry-session')));
    }
    console.log(`workerd actual SDK ${mode}: passed; only synthetic provider traffic`);
  } finally { await runtime.dispose(); }
}
