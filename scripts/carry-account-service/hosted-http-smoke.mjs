// Negative authorization probes only; no existing user or itinerary is addressed.
const base = new URL(process.env.CARRY_ACCOUNT_DEV_URL ?? '');
const key = process.env.CARRY_ACCOUNT_PUBLISHABLE_KEY ?? '';
if (base.protocol !== 'https:' || !base.hostname.endsWith('.supabase.co') || base.pathname !== '/' ||
    base.search || base.hash || base.username || base.password || !key.startsWith('sb_publishable_')) {
  throw new Error('An explicit development project URL and publishable key are required');
}
const probes = [
  ['private_credentials', '/rest/v1/carry_apple_credentials?select=account_id', null],
  ['private_graph', '/rest/v1/graph_entities?select=id', null],
  ['graph_pull_rpc', '/rest/v1/rpc/carry_graph_pull', {p_account:'00000000-0000-0000-0000-000000000001',p_session:'00000000-0000-0000-0000-000000000003',p_cursor:0,p_limit:1}],
  ['graph_apply_rpc', '/rest/v1/rpc/carry_graph_apply', {p_account:'00000000-0000-0000-0000-000000000001',p_session:'00000000-0000-0000-0000-000000000003',p_command:{}}],
  ['credential_rpc', '/rest/v1/rpc/carry_account_credentials', { p_account_id: '00000000-0000-0000-0000-000000000001' }],
  ['enrollment_rpc', '/rest/v1/rpc/carry_account_enroll', {
    p_account_id: '00000000-0000-0000-0000-000000000001', p_subject: 'synthetic-subject',
    p_audience: 'app.nevestudio.carry', p_encrypted_token: 'synthetic-encrypted',
  }],
];
for (const [name, path, body] of probes) {
  const response = await fetch(new URL(path, base), {
    method: body ? 'POST' : 'GET', headers: { apikey: key, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined, redirect: 'error', signal: AbortSignal.timeout(20000),
  });
  const result = await response.json();
  // A generic gateway 401 (invalid key, routing problem) does not prove SQL permissions.
  const denied = body ? [401, 403].includes(response.status) && result.code === '42501'
    : response.status === 404 && ['PGRST205', '42P01'].includes(result.code);
  console.log(JSON.stringify({ check: name, status: response.status, code: result.code, denied }));
  if (!denied) throw new Error(`Authorization probe failed: ${name}`);
}
