import { AccountRequestError } from './lifecycle.mjs';
import { GraphRequestError } from './graph-http.mjs';
import { createAssetCleanupHandler } from './asset-cleanup-http.mjs';
import { runDeletionStep } from './deletion-jobs.mjs';

export function createMaintenanceHandler(accountAdapter,assetAdapter) {
  return createAssetCleanupHandler({
    cleanupAccounts:async token=>{
      try{return await accountAdapter.deletionAccounts(token);}
      catch(error){if(error instanceof AccountRequestError&&error.status===401)throw new GraphRequestError(401,'unauthorized');throw error;}
    },
    cleanupOne:id=>runDeletionStep({...accountAdapter,cleanupFiles:assetAdapter.cleanupOne},id),
  },{credentialHeader:'x-carry-maintenance'});
}
