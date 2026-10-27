import * as jose from 'npm:jose@6.1.3';
import { createGraphHandler } from '../../../graph-http.mjs';
import { createGraphAdapter } from '../../../graph-adapter.mjs';

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error('missing_configuration');
  return value;
}

// Supabase supplies these server-only environment values. They are never
// returned, logged or embedded in the app. No Apple private key is needed here.
const adapter = createGraphAdapter({
  jose,
  configuration: {
    projectURL: required('SUPABASE_URL'),
    serviceKey: required('SUPABASE_SERVICE_ROLE_KEY'),
  },
});

// Keep platform verification AND current-user/session/enrollment checks. OAuth
// clients are explicitly rejected; AI access needs a separate scoped endpoint.
Deno.serve(createGraphHandler(adapter));
