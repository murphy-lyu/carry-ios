// QA only: fixed synthetic identity configuration, all outbound IO forbidden.
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { readFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
export const origin = 'https://account-qa.invalid';
export async function fixtureRuntime() {
  if (process.env.CARRY_WEB_QA !== 'synthetic-only') throw new Error('synthetic_qa_opt_in_required');
  const script = await readFile(process.env.CARRY_WEB_QA_BUNDLE ?? '/tmp/CarryAccountWebBundle/worker.js', 'utf8');
  // Miniflare 5's current file-backed loader fails even for a minimal module.
  // Feed the identical bundled source in memory; no product security changes.
  return new Miniflare(convertV4MiniflareOptions({ modules: true, script,
    compatibilityDate: '2026-10-01', bindings: {
      ACCOUNT_ORIGIN: origin, SUPABASE_URL: 'https://project-qa.invalid',
      SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_synthetic_only', APPLE_WEB_CLIENT_ID: 'app.nevestudio.carry.web',
      WEB_FLOW_ENCRYPTION_KEY: randomBytes(32).toString('base64url'), ACCOUNT_WEB_ENABLED: 'true',
    }, outboundService: () => { throw new Error('outbound_requests_forbidden'); } }));
}
