# Native editor baseline and multi-window review — 2026-11-01

## Findings and repair

An editor copied its form values into `@State` before a background pull. The pull could replace native fields and the journal materialization's observed field versions while the form still displayed its older draft. Saving that draft then used versions the user had never seen. It could overwrite a remotely changed field without producing the promised conflict.

Account native presentations now acquire a lifecycle lease before reading their draft. Pulls, receipts and durable replica updates continue; native projection waits while any account presentation owns a lease. Projection checks this condition both before and after asynchronous asset/snapshot preparation. Releasing the final presentation requests synchronization through its current workspace controller; it does not use a timer.

One account workspace permits one top-level editing group, with nested editors sharing that group's UUID. Read-only details can coexist. A second editing group receives an explicit “editing elsewhere” message before constructing or changing a draft. Workspace owner identity is separate from the group UUID: an old form cannot save into another account or a fresh store after signing back into the same account. Account revocation invalidates leases and queued maintenance.

Trusted UI save closures validate group ownership before changing models. Shared task-local authorization and failure outcome follow composite-store delegation into the actual owning or creation store, including library writes whose older APIs return `Void`. A final account writer check remains in place. Guest writes remain supported. The legacy automation writer is already disabled for account stores; this change does not claim new legacy relay error semantics.

Late geocoding captures immutable IDs, the requesting city and resolved values. Deferred application looks up the current model and verifies the city again. It cannot reuse a stale `@Model`, overwrite a newly edited city, or run after account revocation. Ordinary user mutations are rejected when busy, rather than queued as successful work.

## Rejection and failure behavior

The first unified run exposed two real regressions: a rejected foreign writer caused `CarryPersistence.commit` to quarantine the shared context, preventing the original owner from saving afterward; the same path affected delegated library writes. The failing assertions were retained.

`TripStore.persist` now checks admission before entering `CarryPersistence.commit`. A typed busy rejection rolls back uncommitted mutations in the same context, retains cascade models during rollback, and refreshes visible trips. It does not quarantine a context that has attempted no persistence. Actual journal or disk errors retain the existing quarantine and fresh-context recovery behavior. No generic persistence error was converted into success.

Editors keep their drafts and presentation leases on a failed save. Nested dismissal and old dismissal callbacks are generation checked. Successful save is recorded in the journal before the actual presentation dismisses and releases its lease.

## Audited presentation coverage

| Entry | Protection and failure behavior |
| --- | --- |
| Trip metadata | Acquire before copying `TripInfo`; save under the same group; retain draft on failure. The existing Saved display dwell is not a synchronization timer. |
| Stop, transport and lodging details | Read-only presentation lease; immutable ID wrapper resolves the current model. Remote deletion cannot project beneath the open presentation. |
| Stop, transport and lodging editors; note, cost and time sheets | Inherit owner/group; readonly-to-edit upgrade must succeed before draft capture; failed save keeps the sheet. |
| Itinerary additions and route optimization | Existing trip/day parent is protected for add-stop, add-lodging, flight search, add-transport and optimize presentations. |
| Packing names, quantities and sections | Inline edit acquires before draft mutation; section reorder uses value drafts; save/retry preserves identity without reusing invalidated models. |
| Packing and itinerary drag reorder | Acquire before gesture movement; unowned transactions do not persist; gesture completion/cancellation releases the matching generation. Failed order retains an explicit retry. |
| Item and scene selection; suggestions; library writes | Existing trip and library operations inherit actual-store authorization; composite creation-store failure is propagated to the visible editor. |
| Copy trip, photo reconstruction, image reposition | Protect existing source/parent and inherit group; asynchronous work fixes its original store; failure keeps review state. Copy retains its created copy ID for retry. |
| Attachments and links | Fix original importer/store, validate identity at commit, save metadata before adopting staged files; failed commit keeps input. |
| Home delete confirmation | Immutable trip ID/name and actual owning store; explicit group; cancellation/account changes release it. |
| Account switch/sign-out | Workspace invalidation rejects old drafts, clears queued maintenance and prevents an old final-dismiss callback from scheduling a new account. |
| Global local preferences | `AppStorage` device preferences are outside the account graph and do not freeze account projection. |

Copy remains the existing two-step duplicate-and-update API. This repair prevents duplicate creation on retry and freezes copy options after creation; it does not introduce or claim an atomic copy transaction.

## Verification evidence

- Initial unified run: 378 passed, 2 failed, 1 manual skip. The two failures identified the admission/quarantine defect described above.
- Focused corrected build: `/tmp/carry-editor-admission-fix-build-20261101.log`, `TEST BUILD SUCCEEDED`, no compiler warnings or errors.
- Focused corrected execution: `/tmp/carry-editor-admission-focused-r1-20261101.log`, **22 passed = 16 editor + 6 persistence tests**. The later cascade regression was not included in that build; it is not counted as passed here.
- Final unified exact-source execution: `/tmp/CarryEditorUnifiedFinalQA-v2-20261101/round-1.log` and `round-2.log`, each **382 total, 381 passed, 1 manual skip, 0 failed**. Each includes all **17 editor tests**. Cascade rollback/owner continuation passed in round 1 lines 1325–1326 and round 2 lines 833–834.
- Editor tests exercise real SwiftData, journal, replica, workspace and store delegation using a synthetic in-process server: unsaved draft conflict; unchanged-field convergence; remote deletion review; nested/cancel lifetime; async projection preparation; real save failure/retry; owner/account changes; independent window groups; rejected bypass writes; maintenance; guest behavior; composite library writes; and cascade rollback with original parent/child references remaining usable.
- The six existing persistence regressions continue to verify rejected capture, delete, restore and retry behavior. Failure assertions were not weakened.

These tests establish local native/replica behavior. The in-process editor fixture is not a deployed-server or two-device test. The broader final unified suite also includes the pre-existing independent-client HTTP tests, whose evidence is documented separately.

## Review and remaining evidence boundary

Final read-only Core review checked admission placement, account revocation, authorization propagation, ownership/group separation, projection suspension checks, cascade rollback lifetime and immutable maintenance captures. No additional mandatory Core defect was found. Source was frozen for the supervisor's final two rounds and device builds; this agent did not modify signatures, deploy, install, or access real user trips.

Actual iPhone/Mac UI inspection, including busy messaging, nested dismissal, failed-save presentation and no-op drag completion, belongs to the supervisor's device acceptance. Their results must be reported separately from these automated tests. Two physical iOS devices remain a user-deferred platform-specific check; Mac/iPhone evidence is a separate gate. This report does not claim a new TestFlight upload or App Store release.

## Subsequent physical-Mac finding: same-day metadata edits

The supervisor's later physical-Mac inspection found a separate defect after the v2 automated runs: a dateful trip with stored `days = 0` gained a second itinerary day when only its destination changed. `TripInfo.durationDays` incorrectly clamped the elapsed calendar-day difference to at least one, although `TripBundle.days` and AI use zero nights for a same-day trip and derive the inclusive span separately. The date selector already allowed the same departure/return date, but its edit/create/copy callers independently forced return to at least the following day.

The repair uses a zero lower bound for elapsed days and preserves `max(end, start)` at the three date-selection call sites. Existing packing quantity calculations independently clamp consumable quantities to at least one. No schema, graph protocol or stored user data is changed.

A new eighteenth editor regression runs a same-day graph through the actual workspace, native store and journal: rename, then change destination, retaining the original day ID, one-day count and `days = 0`. It compares native fields and outbound mutation fields to reject unrelated name/date/duration/creation changes. The v2 counts above describe their exact earlier source; they do not establish acceptance of this subsequent repair. Updated build, test and physical-device results must be added separately.

The updated whole-app test build passed with no compiler warnings/errors in `/tmp/carry-single-day-fix-build-20261101.log`. The new regression is `testSameDayTripMetadataEditsKeepSingleDayAndUnchangedGraphFields`; final execution evidence is tracked by the supervisor's next exact-source unified runs.
