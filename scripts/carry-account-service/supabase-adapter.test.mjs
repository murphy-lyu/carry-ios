import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as jose from 'jose';
import { createSupabaseAdapter } from './supabase-adapter.mjs';

const rsa = await jose.generateKeyPair('RS256');
const publicKey = await jose.exportJWK(rsa.publicKey);
publicKey.kid = 'synthetic-apple-key'; publicKey.alg = 'RS256';
const privateKey = await jose.generateKeyPair('ES256', { extractable: true });
const configuration = {
  projectURL: 'https://account-qa.invalid', serviceKey: 'synthetic-service-role',
  appleTeamID: 'SYNTHETIC', appleKeyID: 'synthetic-apple-key',
  applePrivateKey: await jose.exportPKCS8(privateKey.privateKey),
  appleClientIDs: ['app.nevestudio.carry'], encryptionKey: Buffer.alloc(32, 7).toString('base64'),
};
const nonce = 'a'.repeat(43);
const digest = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(nonce))).toString('hex');
const accountID = '00000000-0000-0000-0000-000000000001';
const sessionID = '00000000-0000-0000-0000-000000000002';
async function sessionToken(claims = {}) {
  return new jose.SignJWT({ sub: accountID, session_id: sessionID,
    iss: configuration.projectURL + '/auth/v1', exp: Math.floor(Date.now() / 1000) + 3600, ...claims })
    .setProtectedHeader({ alg: 'ES256' }).sign(privateKey.privateKey);
}
async function token(overrides = {}, key = rsa.privateKey) {
  return new jose.SignJWT({ nonce: digest, ...overrides }).setProtectedHeader({ alg: 'RS256', kid: publicKey.kid })
    .setIssuer('https://appleid.apple.com').setAudience('app.nevestudio.carry')
    .setSubject('synthetic-subject').setIssuedAt().setExpirationTime('5m').sign(key);
}
function setup(fetcher = async () => { throw new Error('unexpected_network'); }) {
  return createSupabaseAdapter({ configuration,
    jose: { ...jose, createRemoteJWKSet: () => jose.createLocalJWKSet({ keys: [publicKey] }) }, fetcher });
}
test('real JOSE verifies signature, issuer, audience and hashed nonce', async () => {
  const adapter = setup();
  assert.deepEqual(await adapter.verifyApple(await token(), nonce), {
    subject: 'synthetic-subject', audience: 'app.nevestudio.carry',
  });
  await assert.rejects(adapter.verifyApple(await token({ nonce: 'wrong' }), nonce), { status: 401 });
  const other = await jose.generateKeyPair('RS256');
  await assert.rejects(adapter.verifyApple(await token({}, other.privateKey), nonce), { status: 401 });
  const invalid = await new jose.SignJWT({ nonce: digest }).setProtectedHeader({ alg: 'RS256', kid: publicKey.kid })
    .setIssuer('https://malicious.invalid').setAudience('app.nevestudio.carry').setSubject('subject')
    .setIssuedAt().setExpirationTime('5m').sign(rsa.privateKey);
  await assert.rejects(adapter.verifyApple(invalid, nonce), { status: 401 });
});
test('expired tokens and tokens for another audience are rejected', async () => {
  const adapter = setup();
  for (const [audience, expires] of [['app.nevestudio.carry', '-1m'], ['different-app', '5m']]) {
    const jwt = await new jose.SignJWT({ nonce: digest }).setProtectedHeader({ alg: 'RS256', kid: publicKey.kid })
      .setIssuer('https://appleid.apple.com').setAudience(audience).setSubject('subject')
      .setIssuedAt().setExpirationTime(expires).sign(rsa.privateKey);
    await assert.rejects(adapter.verifyApple(jwt, nonce), { status: 401 });
  }
});
test('authentication derives account and Apple subjects from server user lookup', async () => {
  const bearer = await sessionToken();
  const paths = [];
  const adapter = setup(async (url, options) => {
    paths.push(url.pathname);
    if (url.pathname.endsWith('carry_account_require_session')) {
      assert.deepEqual(JSON.parse(options.body), { p_account: accountID, p_session: sessionID });
      return new Response(null, { status: 204 });
    }
    assert.equal(url.href, 'https://account-qa.invalid/auth/v1/user');
    assert.equal(options.headers.Authorization, `Bearer ${bearer}`);
    return Response.json({ id: accountID, identities: [
      { provider: 'apple', identity_data: { sub: 'apple-subject' } },
      { provider: 'other', identity_data: { sub: 'must-not-match' } },
    ] });
  });
  assert.deepEqual(await adapter.authenticate(bearer), { id: accountID, appleSubjects: ['apple-subject'] });
  assert.deepEqual(paths, ['/auth/v1/user', '/rest/v1/rpc/carry_account_require_session']);
});
test('account lifecycle rejects OAuth, mismatched and expired claims before credential access', async () => {
  const adapter = setup(async url => {
    assert.equal(url.pathname, '/auth/v1/user', 'Invalid claims must never reach privileged RPCs');
    return Response.json({ id: accountID, identities: [{ provider: 'apple', identity_data: { sub: 'subject' } }] });
  });
  for (const claims of [{ client_id: 'mcp-client' }, { sub: sessionID }, { iss: 'https://other.invalid/auth/v1' },
    { exp: 0 }, { session_id: null }]) {
    await assert.rejects(adapter.authenticate(await sessionToken(claims)), { status: 401, code: 'unauthorized' });
  }
  await assert.rejects(adapter.authenticate('malformed'), { status: 401, code: 'unauthorized' });
});
test('database session revocation denies lifecycle even while Auth still accepts the access JWT', async () => {
  const adapter = setup(async url => url.pathname === '/auth/v1/user'
    ? Response.json({ id: accountID, identities: [{ provider: 'apple', identity_data: { sub: 'subject' } }] })
    : Response.json({ code: '28000', message: 'session_expired' }, { status: 400 }));
  await assert.rejects(adapter.authenticate(await sessionToken()), { status: 401, code: 'session_expired' });
});
test('code exchange signs short-lived client secret and validates selected audience', async () => {
  const adapter = setup(async (url, options) => {
    assert.equal(String(url), 'https://appleid.apple.com/auth/token');
    const values = options.body;
    assert.equal(values.get('grant_type'), 'authorization_code');
    assert.equal(values.has('redirect_uri'), false, 'Native code exchanges must omit redirect_uri');
    assert.equal(values.get('code'), 'synthetic-code');
    const { payload } = await jose.jwtVerify(values.get('client_secret'), privateKey.publicKey, {
      issuer: 'SYNTHETIC', audience: 'https://appleid.apple.com', algorithms: ['ES256'],
    });
    assert.equal(payload.sub, 'app.nevestudio.carry');
    assert.equal(payload.exp - payload.iat, 300);
    return Response.json({ id_token: 'synthetic-id-token', refresh_token: 'synthetic-refresh' });
  });
  assert.deepEqual(await adapter.exchangeCode('synthetic-code', 'app.nevestudio.carry'), {
    idToken: 'synthetic-id-token', refreshToken: 'synthetic-refresh',
  });
  await assert.rejects(adapter.exchangeCode('synthetic-code', 'other-app'), { status: 403 });
});
test('enrollment encrypts refresh credentials with authenticated account binding', async () => {
  let encrypted;
  const adapter = setup(async (url, options) => {
    assert.equal(url.pathname, '/rest/v1/rpc/carry_account_enroll');
    const value = JSON.parse(options.body);
    assert.equal(value.p_account_id, 'internal-account');
    encrypted = value.p_encrypted_token;
    assert.equal(encrypted.includes('synthetic-refresh'), false);
    return new Response(null, { status: 204 });
  });
  await adapter.enroll('internal-account', { subject: 'synthetic-subject', audience: 'app.nevestudio.carry' }, 'synthetic-refresh');
  const [iv, cipher] = encrypted.split('.').map(value => Buffer.from(value, 'base64'));
  const key = await crypto.subtle.importKey('raw', Buffer.from(configuration.encryptionKey, 'base64'), 'AES-GCM', false, ['decrypt']);
  const text = await crypto.subtle.decrypt({ name: 'AES-GCM', iv,
    additionalData: new TextEncoder().encode('internal-account:synthetic-subject:app.nevestudio.carry') }, key, cipher);
  assert.equal(new TextDecoder().decode(text), 'synthetic-refresh');
  await assert.rejects(crypto.subtle.decrypt({ name: 'AES-GCM', iv,
    additionalData: new TextEncoder().encode('different-account:synthetic-subject:app.nevestudio.carry') }, key, cipher));
});
test('incomplete data purge cannot delete auth identity or claim completion', async () => {
  const paths = [];
  const adapter = setup(async (url, options) => {
    const path = new URL(url).pathname; paths.push(path);
    if (path.endsWith('carry_account_begin_delete')) return new Response(null, { status: 204 });
    if (path.endsWith('carry_account_credentials')) return Response.json([]);
    if (path.endsWith('carry_account_purge_owned_data')) return Response.json({ error: 'not_implemented' }, { status: 500 });
    throw new Error('must_not_reach_auth_deletion');
  });
  await assert.rejects(adapter.deleteAccount('internal-account', { subject: 'synthetic-subject', audience: 'app.nevestudio.carry' }, 'token'));
  assert.equal(paths.some(path => path.includes('/admin/users/')), false);
});
test('a deleting account is never restored as active', async () => {
  const adapter = setup(async () => Response.json([{ status: 'deleting' }]));
  assert.equal(await adapter.status('internal-account'), false);
});

test('Apple revocation uses encrypted stored token before purge and auth deletion', async () => {
  let record;
  const paths = [];
  const adapter = setup(async (url, options) => {
    const path = new URL(url).pathname; paths.push(path);
    if (path.endsWith('carry_account_begin_delete')) {
      const value = JSON.parse(options.body);
      record = { account_id: value.p_account_id, apple_subject: value.p_subject,
        audience: value.p_audience, encrypted_token: value.p_encrypted_token, status: 'deleting' };
      return new Response(null, { status: 204 });
    }
    if (path.endsWith('carry_account_credentials')) return Response.json([record]);
    if (path === '/auth/revoke') {
      assert.equal(options.body.get('token'), 'synthetic-fresh-refresh');
      assert.equal(options.body.get('token_type_hint'), 'refresh_token');
      return new Response(null, { status: 200 });
    }
    if (path.endsWith('carry_account_purge_owned_data')) return new Response(null, { status: 204 });
    if (path.includes('/auth/v1/admin/users/')) return Response.json({});
    throw new Error('unexpected_route');
  });
  await adapter.deleteAccount('internal-account', { subject: 'synthetic-subject', audience: 'app.nevestudio.carry' }, 'synthetic-fresh-refresh');
  assert.deepEqual(paths, ['/rest/v1/rpc/carry_account_begin_delete', '/rest/v1/rpc/carry_account_credentials',
    '/auth/revoke', '/rest/v1/rpc/carry_account_purge_owned_data', '/auth/v1/admin/users/internal-account']);
});

test('web code exchange binds the exact operator-configured redirect without changing native exchange', async () => {
  const webID = 'app.nevestudio.carry.web';
  const webConfig = { ...configuration, appleClientIDs: [configuration.appleClientIDs[0], webID],
    appleRedirectURIs: { [webID]: 'https://account-qa.invalid/auth/apple/callback' } };
  const adapter = createSupabaseAdapter({ configuration: webConfig, jose, fetcher: async (url, options) => {
    assert.equal(String(url), 'https://appleid.apple.com/auth/token');
    assert.equal(options.body.get('client_id'), webID);
    assert.equal(options.body.get('redirect_uri'), webConfig.appleRedirectURIs[webID]);
    const { payload } = await jose.jwtVerify(options.body.get('client_secret'), privateKey.publicKey,
      { issuer: configuration.appleTeamID, audience: 'https://appleid.apple.com' });
    assert.equal(payload.sub, webID);
    return Response.json({ id_token: 'synthetic-web-token', refresh_token: 'synthetic-refresh' });
  } });
  assert.equal((await adapter.exchangeCode('synthetic-web-code', webID)).idToken, 'synthetic-web-token');
  assert.throws(() => createSupabaseAdapter({ configuration: { ...webConfig, appleRedirectURIs: {} }, jose }),
    /missing_web_redirect_uri/);
  for (const uri of ['http://account-qa.invalid/auth/apple/callback', 'https://user:pass@account-qa.invalid/path',
    'https://account-qa.invalid/path?next=evil', 'https://account-qa.invalid/path#fragment']) {
    assert.throws(() => createSupabaseAdapter({ configuration: { ...webConfig, appleRedirectURIs: { [webID]: uri } }, jose }));
  }
});
