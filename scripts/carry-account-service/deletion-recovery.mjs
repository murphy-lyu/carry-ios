import { AccountRequestError } from './lifecycle.mjs';

// This path never creates a deletion hold or claims that a timed-out provider
// DELETE stopped. Operator-held state and provider completion evidence are
// mandatory in SQL before any bytes can be revalidated.
export async function recoverHeldDeletion(adapter, { account, identity, token, ticket }) {
  const operation = crypto.randomUUID();
  const prepared = await adapter.prepareRecovery(account, identity, ticket, operation);
  if (prepared?.status === 'cancelled') return {status:'cancelled'};
  if (prepared?.status !== 'verify' || prepared.operationID !== operation || !Array.isArray(prepared.assets) ||
      prepared.assets.length > 128 || !prepared.fingerprints ||
      !/^[0-9a-f]{64}$/.test(prepared.fingerprints.graph ?? '') || !/^[0-9a-f]{64}$/.test(prepared.fingerprints.assets ?? '')) {
    throw new AccountRequestError(503,'recovery_unavailable');
  }
  const total = prepared.assets.reduce((sum, asset) => sum + asset.byteCount, 0);
  if (!Number.isSafeInteger(total) || total < 0 || total > 128*1024*1024) throw new AccountRequestError(503,'recovery_unavailable');
  const signal = AbortSignal.timeout(45000);
  for (const asset of prepared.assets) {
    if (asset.accountID !== account.id) throw new AccountRequestError(403,'identity_mismatch');
    const measured = await adapter.inspectRecoveryAsset(asset, signal);
    if (measured.sha256 !== asset.sha256 || measured.byteCount !== asset.byteCount) throw new AccountRequestError(409,'recovery_file_changed');
  }
  // The official Auth operation preserves THIS freshly verified native session.
  // Other sessions/old AI grants must not silently regain access on activation.
  await adapter.revokeOtherSessions(account);
  const result = await adapter.commitRecovery(account, identity, token, ticket, operation, prepared.fingerprints, prepared.assets);
  if (result?.status !== 'cancelled') throw new AccountRequestError(503,'recovery_unavailable');
  return {status:'cancelled'};
}
