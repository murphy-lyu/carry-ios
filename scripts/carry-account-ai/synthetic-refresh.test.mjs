import {test} from 'node:test';
import assert from 'node:assert/strict';
import {syntheticStore} from './synthetic-store.mjs';
import {AIFailure} from './security.mjs';

test('synthetic refresh matches durable scope equality, non-consumption and replay revocation',async()=>{
 const now=1000,accountID=crypto.randomUUID(),sessionID=crypto.randomUUID(),id=crypto.randomUUID();
 const store=syntheticStore({accountID,sessionID});
 const grant={id,accountID,clientID:'client',resource:'https://qa.invalid/mcp',scopes:['trips:read','trips:write'],expiresAt:10000,revokedAt:null};
 store.db.clients.set('client',{id:'client'});
 store.db.grants.set(id,grant);
 store.db.refresh.set('original',{grantID:id,expiresAt:10000,spent:false});
 const base={refreshHash:'original',clientID:'client',resource:grant.resource,now,tokens:{accessHash:'next-access',refreshHash:'next-refresh',accessExpiresAt:10000,refreshExpiresAt:10000}};
 const rejects=(p,code)=>assert.rejects(p,e=>e instanceof AIFailure&&e.code===code);
 for(const requestedScopes of [[],['trips:read'],['trips:read','trips:write','attachments:read'],['unknown'],null,'trips:read trips:write']) {
  await rejects(store.rotateRefresh({...base,requestedScopes}),'invalid_scope');
  assert.equal(store.db.refresh.get('original').spent,false);
 }
 assert.deepEqual((await store.rotateRefresh({...base,requestedScopes:[...grant.scopes].reverse()})).scopes,grant.scopes);
 await rejects(store.rotateRefresh({...base,requestedScopes:['invalid']}),'invalid_grant');
 assert.equal(store.db.grants.get(id).revokedAt,now);
 await rejects(store.resolveAccess({tokenHash:'next-access',resource:grant.resource,now}),'invalid_token');
});
