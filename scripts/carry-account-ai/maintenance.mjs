/** Server-owned bounded cleanup, run by a reviewed scheduler with the database
 * role. No HTTP/public operation accepts account IDs or a cleanup capability.
 * Receipt before-images expire after 30 days; previews after one day. Spent
 * refresh evidence stays until grant expiry, so cleanup cannot defeat replay
 * detection. Native Graph request receipts retain global idempotency knowledge.
 */
export async function maintainAIRecords(
  driver,
  { now = Date.now(), limit = 500 } = {},
) {
  if (
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 1000 ||
    !Number.isSafeInteger(now)
  )
    throw Error("invalid_maintenance_input");
  return driver.transaction(async (tx) => {
    const removed = (
      await tx.query(
        `with candidates as (
   select bucket,id from carry_ai.records where
    (bucket='authorization' and (value->>'expiresAt')::bigint<$1) or
    (bucket='code' and (value->>'codeExpiresAt')::bigint<$1) or
    (bucket='access' and (value->>'expiresAt')::bigint<$1) or
    (bucket='preview' and (value->>'expiresAt')::bigint<$1-86400000) or
    (bucket='undo' and (value->>'createdAt')::bigint<$1-2592000000) or
    (bucket='refresh' and (value->>'expiresAt')::bigint<$1)
   order by bucket,id limit $2 for update skip locked
  ) delete from carry_ai.records r using candidates c where r.bucket=c.bucket and r.id=c.id returning r.bucket`,
        [now, limit],
      )
    ).rows;
    const compacted = (
      await tx.query(
        `with old as (
      select bucket,id from carry_ai.records where bucket='receipt' and (value->>'createdAt')::bigint<$1-2592000000
        and not coalesce((value->>'undoExpired')::boolean,false) order by id limit $2 for update skip locked
    ) update carry_ai.records r set value=(r.value-'before'-'after'-'mutations')||'{"undoExpired":true}'::jsonb
      from old where r.bucket=old.bucket and r.id=old.id returning r.id`,
        [now, limit],
      )
    ).rows;
    const rates = (
      await tx.query(
        `with old as(select key from carry_ai.rate_limits where window_id<$1 order by key limit $2 for update skip locked)
   delete from carry_ai.rate_limits r using old where r.key=old.key returning r.key`,
        [Math.floor(now / 60000) - 1440, limit],
      )
    ).rows;
    return {
      records: removed.length,
      compactedReceipts: compacted.length,
      rateBuckets: rates.length,
    };
  });
}
