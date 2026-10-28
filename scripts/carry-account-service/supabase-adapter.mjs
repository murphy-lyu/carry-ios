import { AccountRequestError } from './lifecycle.mjs';

const encode = value => new TextEncoder().encode(value);
const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)));
const unbase64 = value => Uint8Array.from(atob(value), char => char.charCodeAt(0));

/// External operations are injectable for local tests; all URLs derive from operator configuration.
export function createSupabaseAdapter({ configuration, jose, fetcher = fetch }) {
  const { projectURL, serviceKey, appleTeamID, appleKeyID, applePrivateKey, appleClientIDs, encryptionKey } = configuration;
  const appleRedirectURIs = configuration.appleRedirectURIs ?? {};
  for (const [audience, raw] of Object.entries(appleRedirectURIs)) {
    const uri = new URL(raw);
    if (!appleClientIDs?.includes(audience) || uri.protocol !== 'https:' || uri.username || uri.password ||
        uri.search || uri.hash) throw new Error('invalid_configuration');
  }
  if (appleClientIDs?.includes('app.nevestudio.carry.web') && !appleRedirectURIs['app.nevestudio.carry.web']) {
    throw new Error('missing_web_redirect_uri');
  }
  const project = new URL(projectURL);
  if (project.protocol !== 'https:' || project.username || project.password || project.search || project.hash ||
      !['', '/'].includes(project.pathname) || !serviceKey || !appleTeamID || !appleKeyID || !applePrivateKey ||
      !appleClientIDs?.length || unbase64(encryptionKey).length !== 32) throw new Error('invalid_configuration');
  const jwks = jose.createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
  const encryption = crypto.subtle.importKey('raw', unbase64(encryptionKey), 'AES-GCM', false, ['encrypt', 'decrypt']);
  let signingKey;

  async function send(url, options = {}) {
    return fetcher(url, { ...options, signal: AbortSignal.timeout(15000), redirect: 'error' });
  }
  async function api(path, options = {}, userToken) {
    const response = await send(new URL(path, project), { ...options, headers: {
      apikey: serviceKey, Authorization: `Bearer ${userToken ?? serviceKey}`,
      'Content-Type': 'application/json', ...options.headers,
    } });
    if (!response.ok) {
      if (userToken && [401, 403].includes(response.status)) throw new AccountRequestError(401, 'unauthorized');
      const error = await response.json().catch(() => null);
      if (error?.code === '28000') throw new AccountRequestError(401, 'session_expired');
      throw new Error('backend_request_failed');
    }
    return response.status === 204 ? null : response.json();
  }
  async function rpc(name, body) {
    return api(`/rest/v1/rpc/${name}`, { method: 'POST', body: JSON.stringify(body) });
  }
  async function seal(id, identity, token) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const additionalData = encode(`${id}:${identity.subject}:${identity.audience}`);
    const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData }, await encryption, encode(token));
    return `${base64(iv)}.${base64(cipher)}`;
  }
  async function open(row) {
    const [iv, data] = row.encrypted_token.split('.');
    const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unbase64(iv),
      additionalData: encode(`${row.account_id}:${row.apple_subject}:${row.audience}`) }, await encryption, unbase64(data));
    return new TextDecoder().decode(plain);
  }
  async function clientSecret(audience) {
    if (!appleClientIDs.includes(audience)) throw new AccountRequestError(403, 'invalid_audience');
    signingKey ??= jose.importPKCS8(applePrivateKey, 'ES256');
    return new jose.SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: appleKeyID })
      .setIssuer(appleTeamID).setSubject(audience).setAudience('https://appleid.apple.com')
      .setIssuedAt().setExpirationTime('5m').sign(await signingKey);
  }
  async function apple(path, body) {
    const response = await send(`https://appleid.apple.com/auth/${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(body),
    });
    if (!response.ok) throw new AccountRequestError(401, 'invalid_apple_code');
    return path === 'revoke' ? null : response.json();
  }
  async function rows(id) {
    return rpc('carry_account_credentials', { p_account_id: id });
  }
  return {
    authenticate: async bearer => {
      const user = await api('/auth/v1/user', {}, bearer);
      // Auth verified this exact bearer before any decoded claim is trusted.
      // The database then checks continued session existence and OAuth origin.
      let claims;
      try { claims = jose.decodeJwt(bearer); }
      catch { throw new AccountRequestError(401, 'unauthorized'); }
      const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
      if (claims.client_id !== undefined || !uuid(user.id) || claims.sub !== user.id ||
          claims.iss !== new URL('/auth/v1', project).href || !uuid(claims.session_id) ||
          typeof claims.exp !== 'number' || claims.exp <= Date.now() / 1000 ||
          !user.identities?.some(value => value.provider === 'apple')) {
        throw new AccountRequestError(401, 'unauthorized');
      }
      await rpc('carry_account_require_session', { p_account: user.id, p_session: claims.session_id });
      return { id: user.id, appleSubjects: (user.identities ?? []).filter(value => value.provider === 'apple')
        .map(value => value.identity_data?.sub).filter(value => typeof value === 'string') };
    },
    rateLimit: id => rpc('carry_account_rate_limit', { p_account_id: id }),
    verifyApple: async (token, nonce) => {
      try {
        const { payload } = await jose.jwtVerify(token, jwks, {
          issuer: 'https://appleid.apple.com', audience: appleClientIDs, algorithms: ['RS256'],
          requiredClaims: ['sub', 'aud', 'exp', 'iat', 'nonce'], maxTokenAge: '5m', clockTolerance: 10,
        });
        const expected = [...new Uint8Array(await crypto.subtle.digest('SHA-256', encode(nonce)))]
          .map(value => value.toString(16).padStart(2, '0')).join('');
        if (payload.nonce !== expected || typeof payload.aud !== 'string' || !payload.sub) {
          throw new Error('invalid_identity');
        }
        return { subject: payload.sub, audience: payload.aud };
      } catch { throw new AccountRequestError(401, 'invalid_apple_identity'); }
    },
    exchangeCode: async (code, audience) => {
      const result = await apple('token', { client_id: audience, client_secret: await clientSecret(audience),
        code, grant_type: 'authorization_code',
        ...(Object.hasOwn(appleRedirectURIs, audience) ? { redirect_uri: appleRedirectURIs[audience] } : {}) });
      return { idToken: result.id_token, refreshToken: result.refresh_token };
    },
    status: async id => {
      const records = await rows(id);
      return records.length > 0 && records.every(row => row.status === 'active');
    },
    enroll: async (id, identity, token) => {
      // A transaction prevents concurrent enrolment from reviving an account being deleted.
      await rpc('carry_account_enroll', { p_account_id: id, p_subject: identity.subject,
        p_audience: identity.audience, p_encrypted_token: await seal(id, identity, token) });
    },
    deleteAccount: async (id, identity, token) => {
      // Durable tombstone and token save happen before external revocation. A failed/retried
      // purge remains blocked. A fresh login must never reset 'deleting' to 'active'.
      await rpc('carry_account_begin_delete', { p_account_id: id, p_subject: identity.subject,
        p_audience: identity.audience, p_encrypted_token: await seal(id, identity, token) });
      const records = await rows(id);
      if (!records.length || records.some(row => row.status !== 'deleting')) {
        throw new Error('deletion_not_durable');
      }
      for (const row of records) {
        await apple('revoke', { client_id: row.audience, client_secret: await clientSecret(row.audience),
          token: await open(row), token_type_hint: 'refresh_token' });
      }
      // This function intentionally refuses to run until the complete account-owned graph,
      // files and AI grants are implemented. It is not a successful empty purge placeholder.
      await rpc('carry_account_purge_owned_data', { p_account_id: id });
      await api(`/auth/v1/admin/users/${encodeURIComponent(id)}`, { method: 'DELETE' });
    },
  };
}
