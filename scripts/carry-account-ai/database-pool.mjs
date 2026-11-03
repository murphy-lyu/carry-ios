/** Pool connection acquisition and dead sockets must fail within a bound,
 * without leaking credentials or crashing an isolate on an idle error. */
export function createDatabasePool(
  pg,
  connectionString,
  { onIdleError = () => console.warn("carry_ai_database_idle_error") } = {},
) {
  const pool = new pg.Pool({
    connectionString,
    max: 2,
    connectionTimeoutMillis: 5000,
    query_timeout: 20000,
    idleTimeoutMillis: 30000,
    maxLifetimeSeconds: 300,
    keepAlive: true,
    ssl: { rejectUnauthorized: true },
  });
  pool.on("error", () => {
    try {
      onIdleError();
    } catch {}
  });
  return pool;
}
