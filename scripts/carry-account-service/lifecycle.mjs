// No token, Apple code, profile or itinerary is logged by this boundary.
export class AccountRequestError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

export function createAccountHandler(dependencies) {
  const { authenticate, verifyApple, exchangeCode, enroll, status, deleteAccount, rateLimit } = dependencies;
  return async request => {
    const reply = (body, code = 200) => new Response(JSON.stringify(body), {
      status: code, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
    try {
      if (!['GET', 'POST'].includes(request.method)) throw new AccountRequestError(405, 'method_not_allowed');
      const bearer = request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      if (!bearer || bearer.length > 16000) throw new AccountRequestError(401, 'unauthorized');
      const account = await authenticate(bearer);
      if (!account?.id || !Array.isArray(account.appleSubjects) || !account.appleSubjects.length) {
        throw new AccountRequestError(401, 'unauthorized');
      }
      if (!await rateLimit(account.id)) throw new AccountRequestError(429, 'rate_limited');
      if (request.method === 'GET') return reply({ status: await status(account.id) ? 'enrolled' : 'not_enrolled' });
      if (!request.headers.get('content-type')?.startsWith('application/json')) throw new AccountRequestError(415, 'json_required');
      const length = Number(request.headers.get('content-length'));
      if (length > 24000) throw new AccountRequestError(413, 'body_too_large');
      // Bound the body while streaming, rather than after unbounded request.text().
      const reader = request.body?.getReader();
      if (!reader) throw new AccountRequestError(400, 'invalid_request');
      const chunks = []; let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 24000) { await reader.cancel(); throw new AccountRequestError(413, 'body_too_large'); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      let body;
      try { body = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new AccountRequestError(400, 'invalid_request'); }
      if (!body || Array.isArray(body) || !['enroll', 'delete'].includes(body.action) ||
          Object.keys(body).some(key => !['action', 'idToken', 'authorizationCode', 'nonce'].includes(key)) ||
          typeof body.idToken !== 'string' || body.idToken.length < 16 || body.idToken.length > 16000 ||
          typeof body.authorizationCode !== 'string' || body.authorizationCode.length < 8 || body.authorizationCode.length > 4096 ||
          typeof body.nonce !== 'string' || !/^[A-Za-z0-9_-]{32,128}$/.test(body.nonce)) {
        throw new AccountRequestError(400, 'invalid_request');
      }
      const identity = await verifyApple(body.idToken, body.nonce);
      if (!identity?.subject || !account.appleSubjects.includes(identity.subject)) {
        throw new AccountRequestError(403, 'identity_mismatch');
      }
      // Apple exchanges a one-use code; the exchanged ID token must bind to the same
      // subject/audience/nonce as the fresh native authorization, including on deletion.
      const tokens = await exchangeCode(body.authorizationCode, identity.audience);
      const exchanged = await verifyApple(tokens.idToken, body.nonce);
      if (exchanged.subject !== identity.subject || exchanged.audience !== identity.audience || !tokens.refreshToken) {
        throw new AccountRequestError(403, 'identity_mismatch');
      }
      if (body.action === 'enroll') {
        await enroll(account.id, identity, tokens.refreshToken);
        return reply({ status: 'enrolled' });
      }
      // The adapter owns a durable deletion workflow: revoke Apple, purge owned data,
      // revoke AI/device sessions, delete auth identity. Never return success on a partial purge.
      await deleteAccount(account.id, identity, tokens.refreshToken);
      return reply({ status: 'deleted' });
    } catch (error) {
      if (error instanceof AccountRequestError) return reply({ error: error.code }, error.status);
      return reply({ error: 'service_unavailable' }, 503);
    }
  };
}
