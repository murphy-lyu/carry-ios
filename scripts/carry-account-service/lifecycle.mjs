import { boundedJSON, GraphRequestError } from './graph-http.mjs';
// No token, Apple code, profile or itinerary is logged by this boundary.
export class AccountRequestError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

export function createAccountHandler(dependencies) {
  const { authenticate, verifyApple, exchangeCode, enroll, status, requestDeletion, rateLimit } = dependencies;
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
      const body=await boundedJSON(request,24000);
      if (!body || Array.isArray(body) || !['enroll', 'delete'].includes(body.action) ||
          Object.keys(body).some(key => !['action', 'idToken', 'authorizationCode', 'nonce','deletionReceipt'].includes(key)) ||
          (body.action==='delete'&&(typeof body.deletionReceipt!=='string'||!/^[0-9a-f]{64}$/.test(body.deletionReceipt))) ||
          (body.action==='enroll'&&body.deletionReceipt!==undefined) ||
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
      const result=await requestDeletion(account, identity, tokens.refreshToken,body.deletionReceipt);
      if(!result||!['deleting','deleted'].includes(result.status))throw new Error('invalid_deletion_result');
      return reply({status:result.status},result.status==='deleting'?202:200);
    } catch (error) {
      if(error instanceof GraphRequestError)return reply({error:error.code},error.status);
      if (error instanceof AccountRequestError) return reply({ error: error.code }, error.status);
      return reply({ error: 'service_unavailable' }, 503);
    }
  };
}
