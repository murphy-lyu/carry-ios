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
  assert.deepEqual(await adapter.authenticate(bearer), { id: accountID, sessionID, appleSubjects: ['apple-subject'] });
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
test('deletion request only persists a durable job and never calls Auth deletion inline',async()=>{
  const paths=[];
  const adapter=setup(async(url,options)=>{
    paths.push(url.pathname);assert.equal(url.pathname,'/rest/v1/rpc/carry_account_request_deletion');
    const value=JSON.parse(options.body);assert.equal(value.p_account,accountID);assert.equal(value.p_session,sessionID);
    assert.equal(value.p_ticket,'a'.repeat(64));assert.equal(value.p_encrypted_token.includes('refresh'),false);
    return Response.json({status:'deleting'});
  });
  assert.deepEqual(await adapter.requestDeletion({id:accountID,sessionID},{subject:'synthetic-subject',audience:'app.nevestudio.carry'},'refresh','a'.repeat(64)),{status:'deleting'});
  assert.equal(paths.length,1);
});
test('a deleting account is never restored as active', async () => {
  const adapter = setup(async () => Response.json([{ status: 'deleting' }]));
  assert.equal(await adapter.status('internal-account'), false);
});

test('Apple revocation decrypts the bound stored credential without touching Auth identity',async()=>{
  let row;
  const adapter=setup(async(url,options)=>{
    if(new URL(url).pathname.endsWith('carry_account_enroll')) {
      const value=JSON.parse(options.body);row={account_id:value.p_account_id,apple_subject:value.p_subject,audience:value.p_audience,encrypted_token:value.p_encrypted_token};
      return new Response(null,{status:204});
    }
    assert.equal(String(url),'https://appleid.apple.com/auth/revoke');
    assert.equal(options.body.get('token'),'synthetic-refresh');assert.equal(options.body.get('token_type_hint'),'refresh_token');
    return new Response(null,{status:200});
  });
  await adapter.enroll(accountID,{subject:'synthetic-subject',audience:'app.nevestudio.carry'},'synthetic-refresh');
  await adapter.revokeCredential(row);
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

test('Auth deletion accepts only confirmed success or the provider user-not-found response',async()=>{
  for(const body of [{code:'user_not_found'},{code:404,error_code:'user_not_found'}]) {
    const adapter=setup(async(url,options)=>{
      assert.equal(new URL(url).pathname,'/auth/v1/admin/users/'+accountID);
      assert.equal(options.headers['X-Supabase-Api-Version'],'2024-01-01');
      return Response.json(body,{status:404});
    });
    await adapter.deleteAuthIdentity(accountID);
  }
  for(const status of [401,403,404,500]) {
    const adapter=setup(async()=>Response.json({message:'unknown error'},{status}));
    await assert.rejects(adapter.deleteAuthIdentity(accountID),/auth_deletion_unconfirmed/);
  }
});

test('held recovery hashes complete provider bytes, revokes other sessions with fresh bearer and commits encrypted credentials only',async()=>{
  const bearer=await sessionToken(),id=crypto.randomUUID(),version=crypto.randomUUID();
  const bytes=new TextEncoder().encode('synthetic recovery file');
  const sha256=Buffer.from(await crypto.subtle.digest('SHA-256',bytes)).toString('hex');
  const manifest={accountID,id,sha256,byteCount:bytes.length,storageVersion:version};
  const calls=[];
  const adapter=setup(async(url,options)=>{
    calls.push(url.pathname+url.search);
    if(url.pathname==='/auth/v1/user')return Response.json({id:accountID,identities:[{provider:'apple',identity_data:{sub:'synthetic-subject'}}]});
    if(url.pathname.endsWith('/carry_account_require_session'))return Response.json(null);
    if(url.pathname.endsWith('/carry_account_recovery_prepare')){
      const body=JSON.parse(options.body);assert.equal(body.p_account,accountID);assert.equal(body.p_session,sessionID);
      return Response.json({status:'verify',operationID:body.p_operation,fingerprints:{graph:'a'.repeat(64),assets:'b'.repeat(64)},assets:[manifest]});
    }
    if(url.pathname.startsWith('/storage/v1/object/authenticated/')){
      assert.equal(options.method,'GET');assert.equal(options.headers.Authorization,'Bearer synthetic-service-role');
      assert.equal(url.pathname,`/storage/v1/object/authenticated/carry-account-assets/${accountID}/${id}/${sha256}`);
      return new Response(bytes);
    }
    if(url.pathname==='/auth/v1/logout'){
      assert.equal(url.search,'?scope=others');assert.equal(options.headers.Authorization,'Bearer '+bearer);
      return new Response(null,{status:204});
    }
    if(url.pathname.endsWith('/carry_account_recovery_commit')){
      const body=JSON.parse(options.body);assert.deepEqual(body.p_assets,[manifest]);
      assert.notEqual(body.p_encrypted_token,'fresh-private-refresh');assert.ok(!body.p_encrypted_token.includes('fresh-private-refresh'));
      assert.ok(calls.indexOf('/auth/v1/logout?scope=others')<calls.length-1);
      return Response.json({status:'cancelled'});
    }
    throw Error('unexpected recovery path');
  });
  const owner=await adapter.authenticate(bearer);
  assert.equal(Object.hasOwn(owner,'accessToken'),false);
  assert.deepEqual(await adapter.recoverDeletion(owner,{subject:'synthetic-subject',audience:'app.nevestudio.carry'},'fresh-private-refresh','a'.repeat(64)),{status:'cancelled'});
});
