import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createWebHandler } from './worker.mjs';
import { flowCodec, sha256, safeContinuation, boundedBytes } from './security.mjs';

const origin = 'https://account-qa.invalid';
const env = { ACCOUNT_ORIGIN: origin, SUPABASE_URL: 'https://project-qa.invalid',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_synthetic_only', APPLE_WEB_CLIENT_ID: 'app.nevestudio.carry.web',
  WEB_FLOW_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64url'), ACCOUNT_WEB_ENABLED: 'true' };
const user = { id: '00000000-0000-0000-0000-000000000001', email: 'synthetic@example.invalid', user_metadata: {} };
const session = { access_token: 'synthetic-access', user };
function setup({ enrolled = true, previous = null, signInError = null, upstreamFailure = false, refresh = false, noLaxOnCallback = false, throwAfterPersist = false, getUserError = null } = {}) {
  const calls = [];
  let options;
  const makeClient = (url, key, values) => {
    assert.equal(url, env.SUPABASE_URL); assert.equal(key, env.SUPABASE_PUBLISHABLE_KEY);
    options = values;
    const persist = value => values.cookies.setAll([{ name: '__Host-carry-session', value,
      options: { sameSite: 'lax', maxAge: 3600 } }], { 'Cache-Control': 'private, no-store' });
    return { auth: {
      getUser: async () => {
        if (refresh) persist('refreshed-previous-session');
        const callback = values.cookies.getAll().some(value => value.name === '__Host-carry-apple-flow');
        return { data: { user: noLaxOnCallback && callback ? null : previous }, error: getUserError };
      },
      getSession: async () => ({ data: { session: previous ? { ...session, user: previous } : null }, error: null }),
      signInWithIdToken: async value => {
        calls.push(['signIn', value]);
        if (!signInError) persist('synthetic-new-session');
        if (throwAfterPersist) throw new Error('private-sdk-exception');
        return { data: signInError ? null : { user, session }, error: signInError };
      },
      updateUser: async value => { calls.push(['profile', value]); return { error: null }; },
      signOut: async value => {
        calls.push(['logout', value]); persist(''); return { error: null };
      },
    } };
  };
  const fetcher = async (url, options) => {
    calls.push(['lifecycle', options]);
    assert.equal(url, env.SUPABASE_URL + '/functions/v1/carry-account');
    assert.equal(options.headers.Authorization, 'Bearer synthetic-access');
    if (upstreamFailure) throw new Error('private-provider-detail');
    return Response.json(enrolled ? { status: 'enrolled' } : { error: 'private-backend-detail' }, { status: enrolled ? 200 : 503 });
  };
  return { handler: createWebHandler({ makeClient, fetcher }), calls, options: () => options };
}
function request(path, { cookie = '', body, originHeader = origin, ...headers } = {}) {
  return new Request(origin + path, { method: body ? 'POST' : 'GET', headers: {
    Cookie: cookie, ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded', Origin: originHeader } : {}), ...headers,
  }, body: body ? new URLSearchParams(body) : undefined });
}
function cookies(response) { return response.headers.getSetCookie().map(value => value.split(';')[0]).join('; '); }
async function start(fixture, next = '/') {
  const login = await fixture.handler(request('/login?continue=' + encodeURIComponent(next)), env);
  assert.equal(login.status, 200);
  const html = await login.text();
  const csrf = /name="csrf" value="([^"]+)"/.exec(html)?.[1];
  const result = await fixture.handler(request('/auth/apple/start', {
    cookie: cookies(login), body: { csrf, continue: next },
  }), env);
  assert.equal(result.status, 303);
  return { result, flowCookie: cookies(result), authorize: new URL(result.headers.get('Location')) };
}
function callback(flow, extra = {}) {
  return request('/auth/apple/callback', { cookie: flow.flowCookie, originHeader: 'https://appleid.apple.com',
    body: { state: flow.authorize.searchParams.get('state'), code: 'synthetic-one-use-code',
      id_token: 'synthetic-apple-id-token', ...extra } });
}

test('closed deployment gate and wrong host cannot create login flows', async () => {
  const f = setup();
  assert.equal((await f.handler(request('/login'), { ...env, ACCOUNT_WEB_ENABLED: 'false' })).status, 503);
  assert.equal((await f.handler(new Request('https://other.invalid/login'), env)).status, 400);
  assert.deepEqual(f.calls, []);
});
test('Apple flow uses exact web audience, redirect, form_post and a hashed nonce', async () => {
  const f = setup(), flow = await start(f);
  const params = flow.authorize.searchParams;
  assert.equal(flow.authorize.origin, 'https://appleid.apple.com');
  assert.equal(params.get('client_id'), 'app.nevestudio.carry.web');
  assert.equal(params.get('redirect_uri'), origin + '/auth/apple/callback');
  assert.equal(params.get('response_mode'), 'form_post');
  assert.equal(params.get('response_type'), 'code id_token');
  const flowCookie = flow.flowCookie.split('=')[1];
  const decoded = await (await flowCodec(env.WEB_FLOW_ENCRYPTION_KEY, origin)).open('apple', decodeURIComponent(flowCookie));
  assert.equal(params.get('nonce'), await sha256(decoded.nonce));
  assert.notEqual(params.get('nonce'), decoded.nonce);
  assert.match(flow.result.headers.get('Set-Cookie'), /SameSite=None/);
  assert.match(flow.result.headers.get('Set-Cookie'), /HttpOnly/);
  assert.match(flow.result.headers.get('Set-Cookie'), /Secure/);
});
test('cross-origin start and mismatched form CSRF make no identity request', async () => {
  const f = setup();
  const login = await f.handler(request('/login'), env);
  const text = await login.text(), csrf = /name="csrf" value="([^"]+)"/.exec(text)[1];
  for (const values of [{ csrf: 'wrong' }, { csrf, originHeader: 'https://evil.invalid' }]) {
    const result = await f.handler(request('/auth/apple/start', { cookie: cookies(login),
      body: { csrf: values.csrf }, originHeader: values.originHeader ?? origin }), env);
    assert.equal(result.status, 403);
  }
  assert.equal(f.calls.length, 0);
});
test('tampered, cross-purpose and expired state cookies are rejected before identity exchange', async () => {
  const f = setup(), flow = await start(f);
  const codec = await flowCodec(env.WEB_FLOW_ENCRYPTION_KEY, origin);
  for (const value of ['forged', await codec.seal('form', { expires: Date.now() + 60_000 }),
    await codec.seal('apple', { state: 'state', nonce: 'nonce', next: '/', expires: Date.now() - 1 })]) {
    const result = await f.handler(request('/auth/apple/callback', { cookie: '__Host-carry-apple-flow=' + value,
      body: { state: flow.authorize.searchParams.get('state'), code: 'synthetic-code', id_token: 'synthetic-id-token' } }), env);
    assert.equal(result.status, 400);
  }
  assert.equal(f.calls.length, 0);
});
test('state mismatch or cancellation cannot create a Carry session', async () => {
  const f = setup(), flow = await start(f);
  const mismatch = await f.handler(callback(flow, { state: 'wrong' }), env);
  assert.equal(mismatch.status, 403);
  const cancelled = await f.handler(callback(flow, { error: 'user_cancelled_authorize' }), env);
  assert.equal(cancelled.status, 303);
  assert.equal(cancelled.headers.get('Location'), '/login?cancelled=1');
  assert.equal(f.calls.length, 0);
});
test('successful callback enrolls matching code/nonce before publishing HttpOnly cookies', async () => {
  const f = setup(), flow = await start(f);
  const result = await f.handler(callback(flow, { user: JSON.stringify({ name: { firstName: 'Test', lastName: 'Traveler' } }) }), env);
  assert.equal(result.status, 303);
  assert.equal(result.headers.get('Location'), '/');
  assert.deepEqual(f.calls.map(value => value[0]), ['signIn', 'profile', 'lifecycle']);
  assert.equal(f.calls[0][1].provider, 'apple');
  const enrollment = JSON.parse(f.calls[2][1].body);
  assert.equal(enrollment.nonce, f.calls[0][1].nonce);
  assert.equal(enrollment.authorizationCode, 'synthetic-one-use-code');
  assert.equal(enrollment.idToken, 'synthetic-apple-id-token');
  const saved = result.headers.getSetCookie().find(value => value.startsWith('__Host-carry-session='));
  assert.match(saved, /HttpOnly/); assert.match(saved, /Secure/); assert.match(saved, /SameSite=Lax/);
  assert.doesNotMatch(await result.text(), /synthetic-access|synthetic-apple/);
});
test('failed lifecycle revokes new session and never returns its cookies or provider detail', async () => {
  for (const options of [{ enrolled: false }, { upstreamFailure: true }]) {
    const f = setup(options), flow = await start(f);
    const result = await f.handler(callback(flow), env);
    assert.equal(result.status, 503);
    assert.equal(f.calls.at(-1)[0], 'logout');
    assert.ok(!result.headers.get('Set-Cookie').includes('__Host-carry-session='));
    assert.doesNotMatch(await result.text(), /private-|synthetic-access/);
  }
});
test('invalid Apple identity never calls enrollment or publishes auth cookies', async () => {
  const f = setup({ signInError: new Error('private-provider-detail') }), flow = await start(f);
  const result = await f.handler(callback(flow), env);
  assert.equal(result.status, 401);
  assert.deepEqual(f.calls.map(value => value[0]), ['signIn']);
  assert.ok(!result.headers.get('Set-Cookie').includes('__Host-carry-session='));
});
test('callback cannot silently replace an already signed-in account', async () => {
  const f = setup({ previous: { ...user, id: '00000000-0000-0000-0000-000000000002' }, refresh: true });
  const flow = await start(f);
  const result = await f.handler(callback(flow), env);
  assert.equal(result.status, 409);
  assert.equal(f.calls.at(-1)[0], 'logout');
  assert.ok(result.headers.get('Set-Cookie').includes('refreshed-previous-session'));
  assert.ok(!result.headers.get('Set-Cookie').includes('synthetic-new-session'));
});
test('verified existing refresh cookies survive a temporary lifecycle outage', async () => {
  const f = setup({ previous: user, enrolled: false, refresh: true });
  const result = await f.handler(request('/'), env);
  assert.equal(result.status, 503);
  assert.match(result.headers.get('Set-Cookie'), /refreshed-previous-session/);
});
test('logout requires same-origin form CSRF and revokes only the current session', async () => {
  const f = setup({ previous: user });
  const home = await f.handler(request('/'), env);
  const csrf = /name="csrf" value="([^"]+)"/.exec(await home.text())[1];
  const denied = await f.handler(request('/logout', { cookie: cookies(home), body: { csrf: 'wrong' } }), env);
  assert.equal(denied.status, 403);
  const result = await f.handler(request('/logout', { cookie: cookies(home), body: { csrf } }), env);
  assert.equal(result.status, 303);
  assert.deepEqual(f.calls.at(-1), ['logout', { scope: 'local' }]);
});
test('no open redirects; only bound authorization continuation is accepted', () => {
  for (const value of ['https://evil.invalid', '//evil.invalid', '/\\evil', '/oauth/consent?authorization_id=wrong', '/?token=secret']) {
    assert.throws(() => safeContinuation(value));
  }
  const next = '/oauth/consent?authorization_id=00000000-0000-0000-0000-000000000001';
  assert.equal(safeContinuation(next), next);
});
test('stream limits and duplicate form parameters cannot bypass rejection', async () => {
  const f = setup();
  const invalid = new Request(origin + '/auth/apple/callback', { method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'state=a&state=b' });
  assert.equal((await f.handler(invalid, env)).status, 400);
  const stream = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(256)); controller.close(); } });
  await assert.rejects(boundedBytes(stream, 128), { status: 413 });
  assert.equal(f.calls.length, 0);
});
test('HTML escapes profile text and all responses forbid cache/frame/referrer exposure', async () => {
  const f = setup({ previous: { ...user, user_metadata: { full_name: '<script>private</script>' } } });
  const result = await f.handler(request('/'), env);
  assert.match(result.headers.get('Cache-Control'), /no-store/);
  assert.match(result.headers.get('Content-Security-Policy'), /frame-ancestors 'none'/);
  assert.equal(result.headers.get('Referrer-Policy'), 'no-referrer');
  assert.match(await result.text(), /&lt;script&gt;private&lt;\/script&gt;/);
});

test('the actual Supabase SSR SDK persists and restores browser cookies only after lifecycle enrollment', async () => {
  const apiUser = { ...user, aud: 'authenticated', app_metadata: { provider: 'apple', providers: ['apple'] },
    created_at: '2026-10-28T00:00:00Z', updated_at: '2026-10-28T00:00:00Z', identities: [], is_anonymous: false };
  const jwt = [Buffer.from('{"alg":"ES256"}').toString('base64url'),
    Buffer.from(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 3600 })).toString('base64url'),
    'synthetic-signature'].join('.');
  const paths = [];
  const handler = createWebHandler({ fetcher: async (raw, options) => {
    const url = new URL(raw); paths.push(url.pathname);
    if (url.pathname === '/auth/v1/token') {
      assert.equal(url.searchParams.get('grant_type'), 'id_token');
      const body = JSON.parse(options.body);
      assert.equal(body.provider, 'apple');
      assert.equal(body.id_token, 'synthetic-apple-id-token');
      assert.match(body.nonce, /^[A-Za-z0-9_-]{43}$/);
      return Response.json({ access_token: jwt, refresh_token: 'synthetic-refresh', token_type: 'bearer',
        expires_in: 3600, user: apiUser });
    }
    if (url.pathname === '/auth/v1/user') return Response.json(apiUser);
    if (url.pathname === '/functions/v1/carry-account') {
      assert.equal(options.headers.Authorization, 'Bearer ' + jwt);
      return Response.json({ status: 'enrolled' });
    }
    throw new Error('unexpected_external_request');
  } });
  const flow = await start({ handler });
  const response = await handler(callback(flow), env);
  assert.equal(response.status, 303);
  const stored = response.headers.getSetCookie().filter(value => value.startsWith('__Host-carry-session'));
  assert.ok(stored.length > 0);
  assert.ok(stored.every(value => /HttpOnly/.test(value) && /Secure/.test(value) && /SameSite=Lax/.test(value)));
  assert.equal(paths.at(-1), '/functions/v1/carry-account');
  const home = await handler(request('/', { cookie: cookies(response) }), env);
  assert.equal(home.status, 200);
  assert.match(await home.text(), /synthetic@example.invalid/);
  assert.deepEqual(paths.slice(-2), ['/auth/v1/user', '/functions/v1/carry-account']);
});

test('nine-language pages and errors have complete matching strings with no raw provider detail', async () => {
  const { strings, language } = await import('./strings.mjs');
  const keys = Object.keys(strings.en).sort();
  for (const [locale, text] of Object.entries(strings)) {
    assert.deepEqual(Object.keys(text).sort(), keys);
    const f = setup();
    const page = await f.handler(new Request(origin + '/login', { headers: { 'Accept-Language': locale } }), env);
    const html = await page.text();
    assert.match(html, new RegExp(`lang="${locale}"`));
    assert.ok(html.includes(text.signIn));
    assert.ok(html.includes(`locale=${text.apple}`));
    const error = await f.handler(new Request(origin + '/missing', { headers: {
      'Accept-Language': locale, Accept: 'text/html',
    } }), env);
    assert.equal(error.status, 404);
    assert.ok((await error.text()).includes(text.unavailable));
  }
  assert.equal(language('en;q=0,zh-TW;q=0.9,de;q=0.4'), 'zh-Hant');
  assert.equal(language('xx,pt-PT;q=0.8'), 'pt-BR');
  assert.equal(language('xx;q=1,en;q=0,zh-CN;q=0.8'), 'zh-Hans');
});

test('cross-site callback lacking Lax session cookies still cannot swap the initiating account', async () => {
  const f = setup({ previous: { ...user, id: '00000000-0000-0000-0000-000000000002' }, noLaxOnCallback: true });
  const flow = await start(f);
  const result = await f.handler(callback(flow), env);
  assert.equal(result.status, 409);
  assert.equal(f.calls.at(-1)[0], 'logout');
  assert.ok(!result.headers.get('Set-Cookie').includes('synthetic-new-session'));
});
test('duplicate or excessive cookies are rejected before creating a client or issuing a flow', async () => {
  const f = setup();
  for (const [cookie, status] of [['__Host-carry-form=one; __Host-carry-form=two', 400], ['a=' + 'x'.repeat(16384), 431]]) {
    const response = await f.handler(request('/login', { cookie }), env);
    assert.equal(response.status, status);
  }
  assert.equal(f.calls.length, 0);
});

test('an SDK exception after cookie mutation cannot publish an unenrolled session', async () => {
  const f = setup({ throwAfterPersist: true }), flow = await start(f);
  const result = await f.handler(callback(flow), env);
  assert.equal(result.status, 503);
  assert.equal(f.calls.at(-1)[0], 'logout');
  assert.ok(!result.headers.get('Set-Cookie').includes('synthetic-new-session'));
  assert.doesNotMatch(await result.text(), /private-sdk-exception/);
});

test('a transient identity lookup failure is never treated as a signed-out browser', async () => {
  const f = setup({ previous: user, getUserError: { status: 503, message: 'private-outage' } });
  const response = await f.handler(request('/login'), env);
  assert.equal(response.status, 503);
  assert.equal(f.calls.length, 0);
  assert.ok(!response.headers.get('Set-Cookie')?.includes('__Host-carry-apple-flow'));
});
