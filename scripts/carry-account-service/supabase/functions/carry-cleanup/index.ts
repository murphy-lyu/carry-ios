import * as jose from 'npm:jose@6.1.3';
import { createAssetUploadAdapter } from '../../../asset-upload-adapter.mjs';
import { createAssetCleanupHandler } from '../../../asset-cleanup-http.mjs';
function required(key: string): string {
  const value=Deno.env.get(key);
  if(!value)throw new Error('missing_configuration');
  return value;
}
const adapter=createAssetUploadAdapter({jose,configuration:{
  projectURL:required('SUPABASE_URL'),serviceKey:required('SUPABASE_SERVICE_ROLE_KEY'),
}});
Deno.serve(createAssetCleanupHandler(adapter));
