/** Inject a server-only node-postgres compatible pool. Credentials and pool
 * setup belong to the deployment adapter, never this module or browser bundle.
 * The pool must use the reviewed service role, TLS and a bounded connection cap.
 */
export function postgresDriver(pool, { role = null } = {}) {
  if (role !== null && role !== "service_role")
    throw new Error("invalid_database_role");
  if (typeof pool?.connect !== "function")
    throw new Error("postgres_pool_required");
  return {
    transaction: async (fn) => {
      const client = await pool.connect();
      let broken = false;
      try {
        await client.query("begin");
        if (role) await client.query("set local role service_role");
        await client.query("set local statement_timeout='15s'");
        await client.query("set local lock_timeout='5s'");
        const result = await fn(client);
        await client.query("commit");
        return result;
      } catch (error) {
        try {
          await client.query("rollback");
        } catch {
          broken = true;
        }
        throw error;
      } finally {
        client.release(broken);
      }
    },
  };
}
