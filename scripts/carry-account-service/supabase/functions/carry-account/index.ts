import * as jose from 'npm:jose@6.1.3';
import { createAccountHandler } from '../../../lifecycle.mjs';
import { createSupabaseAdapter } from '../../../supabase-adapter.mjs';

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error('missing_configuration');
  return value;
}

const adapter = createSupabaseAdapter({
  jose,
  configuration: {
    projectURL: required('SUPABASE_URL'),
    serviceKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    appleTeamID: required('CARRY_APPLE_TEAM_ID'),
    appleKeyID: required('CARRY_APPLE_KEY_ID'),
    applePrivateKey: required('CARRY_APPLE_PRIVATE_KEY'),
    appleClientIDs: required('CARRY_APPLE_CLIENT_IDS').split(',').map(value => value.trim()).filter(Boolean),
    encryptionKey: required('CARRY_ACCOUNT_ENCRYPTION_KEY'),
  },
});

// Keep platform verify_jwt enabled. The adapter also fetches the current user from
// Auth, so an authenticated JWT alone cannot select an arbitrary account ID.
Deno.serve(createAccountHandler(adapter));
