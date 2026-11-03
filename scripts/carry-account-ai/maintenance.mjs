/** Server-owned bounded retention. The scheduler and this adapter use the same
 * private SQL implementation; no public operation accepts cleanup authority. */
export async function maintainAIRecords(driver, { now = Date.now(), limit = 500 } = {}) {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000 || !Number.isSafeInteger(now))
    throw Error("invalid_maintenance_input");
  return driver.transaction(async tx => (await tx.query(
    "select carry_ai.maintain_records($1::bigint,$2::integer) as result", [now, limit],
  )).rows[0].result);
}
