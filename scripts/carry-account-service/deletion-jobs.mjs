import { isUUID } from './graph-http.mjs';

// One durable step per invocation. No Auth deletion can run before the database
// commits a successful owned-data purge. Timeouts/failures retain the receipt.
export async function runDeletionStep(adapter,accountID) {
  if(!isUUID(accountID))throw new Error('invalid_deletion_account');
  const operation=crypto.randomUUID(),job=await adapter.claimDeletion(accountID,operation);
  if(!job)return false;
  if(job.accountID!==accountID||!['revoking','purging','deleting_auth'].includes(job.stage))throw new Error('invalid_deletion_job');
  try {
    if(job.stage==='revoking') {
      const credential=await adapter.deletionCredential(accountID,operation);
      if(credential) {
        if(credential.account_id!==accountID)throw new Error('invalid_deletion_credential');
        await adapter.revokeCredential(credential);
        const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(credential.encrypted_token)))]
          .map(byte=>byte.toString(16).padStart(2,'0')).join('');
        await adapter.recordRevocation(accountID,operation,credential,hash);
        await adapter.releaseDeletion(accountID,operation,false);
      }else await adapter.advanceDeletion(accountID,operation,'purging');
    }else if(job.stage==='purging') {
      await adapter.cleanupFiles(accountID);
      await adapter.advanceDeletion(accountID,operation,'deleting_auth');
    }else {
      await adapter.deleteAuthIdentity(accountID);
      await adapter.advanceDeletion(accountID,operation,'deleted');
    }
    return true;
  }catch(error) {
    // Losing a lease can make release fail too. Neither failure may turn an
    // incomplete deletion into success; the existing lease expires for retry.
    try {await adapter.releaseDeletion(accountID,operation,true);}
    catch {throw new Error('deletion_retry_pending');}
    throw error;
  }
}
