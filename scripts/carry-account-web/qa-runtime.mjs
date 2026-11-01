// QA only: fixed synthetic identity configuration, all outbound IO forbidden.
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { readFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
export const origin = 'https://account-qa.invalid';
export async function fixtureRuntime({ authTokenResponse = null, onAuthRequest = () => {}, enrollmentFixture = null } = {}) {
  if (process.env.CARRY_WEB_QA !== 'synthetic-only') throw new Error('synthetic_qa_opt_in_required');
  const script = await readFile(process.env.CARRY_WEB_QA_BUNDLE ?? '/tmp/CarryAccountWebBundle/worker.js', 'utf8');
  // Miniflare 5's current file-backed loader fails even for a minimal module.
  // Feed the identical bundled source in memory; no product security changes.
  return new Miniflare(convertV4MiniflareOptions({ modules: true, script,
    compatibilityDate: '2026-10-01', bindings: {
      ACCOUNT_ORIGIN: origin, SUPABASE_URL: 'https://project-qa.invalid',
      SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_synthetic_only', APPLE_WEB_CLIENT_ID: 'app.nevestudio.carry.web',
      WEB_FLOW_ENCRYPTION_KEY: randomBytes(32).toString('base64url'), ACCOUNT_WEB_ENABLED: 'true',
    }, outboundService: async request => {
      if (authTokenResponse) {
        const url = new URL(request.url);
        if (enrollmentFixture && url.origin === 'https://project-qa.invalid') {
          if (url.pathname === '/functions/v1/carry-account' && ['POST', 'GET'].includes(request.method))
            return Response.json({ status: 'enrolled' });
          if (url.pathname === '/auth/v1/user' && request.method === 'GET')
            return Response.json(enrollmentFixture);
        }
        if (url.origin !== 'https://project-qa.invalid' || url.pathname !== '/auth/v1/token' || request.method !== 'POST')
          throw new Error('unexpected_synthetic_auth_request');
        const body = await request.json();
        if (body.provider !== 'apple' || body.id_token !== 'synthetic-invalid-apple-token')
          throw new Error('non_synthetic_identity_forbidden');
        onAuthRequest();
        return authTokenResponse();
      }
      throw new Error('outbound_requests_forbidden');
    } }));
}
