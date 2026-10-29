import * as jose from 'npm:jose@6.1.3';
import { createAssetUploadAdapter } from '../../../asset-upload-adapter.mjs';
import { createAssetHandler } from '../../../asset-http.mjs';

declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };

function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error('missing_configuration');
  return value;
}

// Native-only file API: platform JWT validation, current Auth identity and
// continued native-session/enrollment checks precede the private Storage key.
// The key/location never leave the adapter. AI needs separate scoped grants.
const adapter = createAssetUploadAdapter({
  jose,
  configuration: {
    projectURL: required('SUPABASE_URL'),
    serviceKey: required('SUPABASE_SERVICE_ROLE_KEY'),
  },
});
// Opportunistic, durable cleanup. A scheduled worker must also drain jobs when
// no native requests arrive; account deletion cannot depend on an open phone.
const handlerAdapter = {
  ...adapter,
  scheduleCleanup(accountID: string) {
    try {
      EdgeRuntime.waitUntil(adapter.cleanupOne(accountID).catch(() => {
        // The durable lease/ledger remains retryable. Never log a bearer,
        // provider URL, private object path or upstream exception payload.
        console.error(JSON.stringify({ event: 'asset_cleanup_deferred' }));
      }));
    } catch {
      console.error(JSON.stringify({ event: 'asset_cleanup_schedule_failed' }));
    }
  },
};
Deno.serve(createAssetHandler(handlerAdapter));
