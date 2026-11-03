/** Only fixed outcome names and a day counter cross this boundary. No input,
 * credential, grant identity, request body or provider error is retained. */
export function oauthResponseEvent(path, status) {
  if (!["/oauth/register", "/oauth/token"].includes(path)) return null;
  if (status === 429) return "oauth_limited";
  if (status >= 500) return "oauth_unavailable";
  return path === "/oauth/register"
    ? status < 300
      ? "register_ok"
      : "register_rejected"
    : status < 300
      ? "token_ok"
      : "token_rejected";
}
export function createOperationsRecorder(driver) {
  return async ({ name, now }) => {
    if (!name) return;
    try {
      await driver.transaction(async (tx) => {
        await tx.query("set local statement_timeout='1s'");
        await tx.query("set local lock_timeout='250ms'");
        await tx.query(
          "select carry_ai.record_auth_event($1::text,$2::bigint)",
          [name, now],
        );
      });
    } catch {
      /* Diagnostic availability never changes an OAuth decision. */
    }
  };
}
