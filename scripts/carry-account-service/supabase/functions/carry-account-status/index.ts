import { createDeletionStatusAdapter } from '../../../deletion-status-adapter.mjs';
import { createDeletionStatusHandler } from '../../../deletion-status-http.mjs';
function required(key: string): string {
  const value=Deno.env.get(key);
  if(!value)throw new Error('missing_configuration');
  return value;
}
// Dedicated receipt authentication remains valid after Auth/JWT deletion. No
// user/data endpoint disables JWT validation; this endpoint returns only status.
Deno.serve(createDeletionStatusHandler(createDeletionStatusAdapter({configuration:{
  projectURL:required('SUPABASE_URL'),serviceKey:required('SUPABASE_SERVICE_ROLE_KEY'),
}})));
