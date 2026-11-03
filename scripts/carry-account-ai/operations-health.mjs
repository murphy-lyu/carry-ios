/** Aggregate-only operational decisions, deliberately independent of identity. */
export function evaluateOperationsHealth(snapshot,cron,{now=Date.now()}={}) {
  if(!snapshot||!Number.isSafeInteger(snapshot.clients)||!Number.isSafeInteger(snapshot.clientBytes)||Number(snapshot.clients)<0||Number(snapshot.clientBytes)<0||!Array.isArray(snapshot.events))throw Error('invalid_operations_snapshot');
  const warnings=[],critical=[];
  const fraction=Math.max(Number(snapshot.clients)/1024,Number(snapshot.clientBytes)/16777216);
  if(fraction>=0.9)critical.push('registry_capacity');else if(fraction>=0.75)warnings.push('registry_capacity');
  if(!cron?.active)critical.push('retention_disabled');
  else if(!cron.lastSuccess||!Number.isFinite(Date.parse(cron.lastSuccess))||now-Date.parse(cron.lastSuccess)>45*60000)critical.push('retention_stale');
  if(Number(cron?.failuresLastDay)>0)warnings.push('retention_failures');
  const events=snapshot.events.filter(e=>e.day>=Math.floor(now/86400000)-1&&e.day<=Math.floor(now/86400000));
  const total=name=>events.filter(e=>e.event===name).reduce((n,e)=>n+Number(e.count),0);
  const rejected=total('token_rejected'),tokens=total('token_ok')+rejected;
  if(total('refresh_replay')>0)warnings.push('refresh_replay_observed');
  if(total('oauth_unavailable')>=5)warnings.push('oauth_unavailable');
  if(tokens>=20&&rejected/tokens>=0.2)warnings.push('token_rejection_rate');
  return {status:critical.length?'critical':warnings.length?'warning':'ok',critical,warnings,
    clients:Number(snapshot.clients),clientBytes:Number(snapshot.clientBytes),capacityRatio:fraction,
    tokenRequests:tokens,tokenRejections:rejected};
}
