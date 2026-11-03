# Interrupted account deletion: restricted recovery review

## Delivery boundary
Implemented locally on the isolated recovery branch. No real account was restored, no provider evidence gate was set, no production configuration was changed, and no phone was installed. The real request remains paused and restricted. Old revoked Apple credentials cannot be restored.

## Safety model
Recovery supports only a manually held purging job with the original Auth UUID and Apple subject. A fresh native Apple ID token, nonce and one-use code are required. Missing Auth identity, graph, file ledger or file bytes refuse recovery; no data is recreated.

The 110-second client drain is required but insufficient. An operator must first establish verifiable provider-side terminal evidence for every old external DELETE and record its private evidence digest. File presence, elapsed time and a local request timeout do not satisfy this gate. Without evidence, the protocol stays closed.

Prepare and commit use the same account advisory lock as deletion and cleanup. They require no active old main lease, a held cleanup path, exact provider version, full SHA-256 and byte length, and unchanged graph/asset/upload-attempt fingerprints. Commit validates all graph file references without changing graph IDs, fields or versions. Stale deletion and independent cleanup completions remain fenced. The provider metadata version is locked and rechecked in the final transaction.

Official Auth logout(scope=others) runs using the freshly verified native bearer before commit. Auth logout alone does not invalidate a signed JWT. The central native session guard also requires an existing, unexpired, non-OAuth auth.sessions row. Commit adds all still-present other session IDs to a durable private rejection list in the existing deletion job; the guard rejects those IDs after activation even if Auth retained their rows. Graph and asset interfaces call that guard. The current fresh session and later genuine new sign-ins remain usable. Prior AI grants are revoked in the same commit.

Only fresh encrypted Apple credentials become active. The opaque deletion receipt becomes cancelled. The pending native receipt clears last, after authenticated success and local session/profile persistence. Failure retains the pending receipt and all local trips.

## Native integration
- CarryAccountService protocol gains recoverDeletion; its default throws unavailable.
- CarryAccountStore.AppleAction gains recoverDeletion. Existing sign-in, delete and sign-out stay blocked while deleting; recovery is allowed only while a receipt is pending.
- CarryAccountDeletionProgress gains cancelled. Polling that state leaves deleting and revalidates Auth; it does not report completed deletion.
- AccountView has no recovery entry. A future controlled entry must obtain a fresh Sign in with Apple authorization for recoverDeletion after the operator gate is satisfied. Do not repurpose ordinary sign-in or enable a button to bypass evidence.

## Verification
Native account suites passed twice: 39 tests each, zero failures/skips/runtime warnings. Dedicated simulator and DerivedData; no physical-device action. Localization audit: zero errors/warnings. Git whitespace check passed.

Final backend suite passed twice: 139 tests each, zero failures/skips. Includes actual PostgreSQL tests using independent local databases: competing prepares admit one operation; commit racing stale cleanup cannot erase the verified file; retained old native session rows are rejected after recovery. The remaining tests cover wrong account/subject/session/ticket, stages and leases, missing evidence, changed graph/files/version/proofs, partial inspection/Auth failure, idempotence, cancelled receipts, subsequent fresh deletion and public-role denial.

Self-review found and fixed native cancelled status sticking in deleting, an unnecessary receipt UPDATE privilege requirement, and old JWT resurrection protection. Test fixture corrections were required for complete synthetic provider metadata and PostgreSQL JSON-array binding. An interrupted simulator startup attempt is not counted as acceptance. The final native runs used parallel testing disabled; simulator infrastructure startup did not produce compiler warnings.

## Read-only provider evidence follow-up
A separate Supabase log tab showed one candidate TUS resumable DELETE with terminal HTTP 409 at 22:50:02 local time, followed by Storage HEAD 410. No object DELETE appeared in the same last-hour gateway filter. A separate read-only SQL comparison returned one held upload attempt, one exact DELETE-path match, matching attempt/verified versions, matching version encoded in the TUS path, and the same current nonarchived Storage version. This confirms the candidate is the held attempt. Complete file SHA and complete visibility of all prior external operations remain unverified; the evidence gate was not set. Logs retained in the console; no actual provider path or account identifier is included in this report.

## Remaining real recovery gates
1. Correlate all old provider operations to exact ledger upload/object/version and prove their terminal outcome. An empty log search alone cannot prove absence of an unlogged operation.
2. Review/install the protocol and migration without changing the real held request; independently validate current file version and complete SHA.
3. Only after the operator evidence gate passes, obtain the original user's fresh native Apple authorization through a controlled UI entry.
4. Execute conditional prepare/inspection/commit, then independently read back cancelled receipt, fresh credential, original graph/file count and session rejection. Any missing evidence/data keeps the account restricted; no reconstruction is authorized.
