import Foundation
import SwiftData
import Combine

enum CarryAccountWorkspaceFailure: Error { case synchronizationDisabled, wrongBusinessContainer, assetsUnavailable, writerClosed }

/// One immutable identity owns one local database and one synchronization lease.
/// Creating a workspace never uploads, imports or removes any guest/iCloud data.
@MainActor
final class CarryAccountWorkspace: ObservableObject {
    enum State: Equatable { case paused, pending, synchronizing, synchronized, conflict, failed }

    struct Hooks {
        var prepareJournal: (CarryNativeJournalBatch) async throws -> Void = { batch in
            if batch.changes.contains(where: \.requiresAssetPreparation) { throw CarryAccountWorkspaceFailure.assetsUnavailable }
        }
        var resolveFields: CarryNativeJournalBridge.ResolveFields? = nil
        var didConsumeJournal: (CarryNativeJournalBatch) throws -> Void = { _ in }
        /// Freeze/upload/certify every referenced asset before graph publication.
        var preparePublication: (CarryGraphCommand, ModelContext) async throws -> Void = { command, _ in
            let keys: Set<String> = ["fileAssetID", "thumbnailAssetID", "originalAssetID", "backgroundAssetIDs"]
            for mutation in command.mutations {
                for (key, value) in mutation.fields ?? [:] where keys.contains(key) {
                    if value != .null && value != .array([]) && value != .object([:]) { throw CarryAccountWorkspaceFailure.assetsUnavailable }
                }
            }
        }
        /// Called only after the complete receipt was durably accepted.
        var didAcceptPublication: (UUID, ModelContext) throws -> Void = { _, _ in }
        var prepareProjection: ([CarryNativeProjectionEntity], Set<UUID>) async throws -> Void = { _, _ in }
        var resolveProjectionAssets: CarryNativeGraphProjector.ResolveAssets? = nil
        var projectionSave: CarryPersistence.Save = { try $0.save() }
        var didProject: (CarryNativeProjectionResult) -> Void = { _ in }
    }

    let accountID: UUID
    let container: ModelContainer
    let replica: CarryAccountReplica
    let journal: CarryNativeChangeJournal
    let bridge: CarryNativeJournalBridge
    @Published private(set) var state: State = .paused
    private let currentBusinessContext: () -> ModelContext
    private let transport: any CarryGraphTransporting
    private let hooks: Hooks
    private let projector: CarryNativeGraphProjector
    private var writerOpen = true
    private var synchronizationEnabled = false
    private var lease = UUID()
    private var active: (id: UUID, task: Task<Bool, Error>)?

    init(accountID: UUID, container: ModelContainer, transport: any CarryGraphTransporting,
         businessContext: @escaping () -> ModelContext, hooks: Hooks? = nil) throws {
        self.accountID = accountID
        self.container = container
        self.transport = transport
        currentBusinessContext = businessContext
        let resolvedHooks = hooks ?? Hooks()
        self.hooks = resolvedHooks
        replica = try CarryAccountReplica(container: container, accountID: accountID)
        journal = CarryNativeChangeJournal(accountID: accountID)
        bridge = CarryNativeJournalBridge(replica: replica)
        projector = CarryNativeGraphProjector(accountID: accountID, resolveAssets: resolvedHooks.resolveProjectionAssets)
        guard businessContext().container === container else { throw CarryAccountWorkspaceFailure.wrongBusinessContainer }
    }

    /// Inject this writer into every account business save, including automation
    /// and import. A caller's replacement Context remains supported by provider.
    var businessSave: CarryPersistence.Save {
        { [weak self] context in
            guard let self, context.container === self.container else { throw CarryAccountWorkspaceFailure.wrongBusinessContainer }
            guard self.writerOpen else { throw CarryAccountWorkspaceFailure.writerClosed }
            try self.journal.captureAndSave(context)
            if self.state != .paused && self.state != .synchronizing { self.state = .pending }
        }
    }

    /// Only call after the user has enabled account synchronization. It does not
    /// migrate existing trips or grant access to guest/local file namespaces.
    func enableSynchronization() { guard writerOpen else { return }; synchronizationEnabled = true; state = .pending }

    /// Permanent writer revocation is distinct from offline synchronization pause.
    func revokeWriterLease() { writerOpen = false }

    /// Await before removing account navigation, switching identity or deleting
    /// its cache. The invalidated lease rejects even cancellation-ignoring I/O.
    func pauseAndWait() async {
        synchronizationEnabled = false
        lease = UUID()
        state = .paused
        guard let running = active else { return }
        running.task.cancel()
        _ = await running.task.result
        if active?.id == running.id { active = nil }
    }

    @discardableResult
    func synchronize() async throws -> Bool {
        try Task.checkCancellation()
        guard writerOpen else { throw CarryAccountWorkspaceFailure.writerClosed }
        guard synchronizationEnabled else { throw CarryAccountWorkspaceFailure.synchronizationDisabled }
        if let running = active { return try await running.task.value }
        let id = UUID(), generation = lease
        let task = Task { @MainActor in try await self.performSynchronization(lease: generation) }
        active = (id, task)
        do {
            let completed = try await task.value
            if active?.id == id { active = nil }
            return completed
        } catch {
            if active?.id == id { active = nil }
            throw error
        }
    }

    private func checkLease(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard synchronizationEnabled, lease == generation else { throw CancellationError() }
    }

    /// Synchronous network barriers consume already prepared scalar/asset logs;
    /// fresh file work defers the pass instead of reinterpreting unshown values.
    private func drainPreparedJournal(lease generation: UUID) throws -> Bool {
        try checkLease(generation)
        for _ in 0..<100 {
            guard let batch = try bridge.nextBatch() else { return true }
            let result = try bridge.apply(batch: batch, resolveFields: hooks.resolveFields)
            if result == .deferred { return false }
            try hooks.didConsumeJournal(batch)
        }
        return false
    }

    private func prepareJournal(lease generation: UUID) async throws -> Bool {
        for _ in 0..<100 {
            try checkLease(generation)
            guard let batch = try bridge.nextBatch() else { return true }
            if batch.changes.contains(where: \.requiresAssetPreparation) { try await hooks.prepareJournal(batch) }
            try checkLease(generation)
            let result = try bridge.apply(batch: batch, resolveFields: hooks.resolveFields)
            if result == .deferred { return false }
            try hooks.didConsumeJournal(batch)
        }
        return false
    }

    private func performSynchronization(lease generation: UUID) async throws -> Bool {
        try checkLease(generation)
        state = .synchronizing
        let guarded = CarryWorkspaceTransport(base: transport, check: { try self.checkLease(generation) },
            prepare: { command in
                try await self.hooks.preparePublication(command, self.replica.context)
                try self.checkLease(generation)
            }, accepted: { requestID in try self.hooks.didAcceptPublication(requestID, self.replica.context) })
        let engine = CarryAccountSyncEngine(replica: replica, transport: guarded,
            drainNativeChanges: { try self.drainPreparedJournal(lease: generation) })
        do {
            // Bounded passes: the lifecycle requests continuation; no tight
            // unbounded retry loop can monopolize the UI actor or radio.
            for _ in 0..<4 {
                guard try await prepareJournal(lease: generation) else { state = .pending; return false }
                for request in try replica.abandonedPublicationRequests() {
                    try hooks.didAcceptPublication(request, replica.context)
                    try replica.didReleaseAbandonedPublication(request)
                }
                let complete = try await engine.synchronize()
                try checkLease(generation)
                guard try replica.pendingFailure == nil else { state = .conflict; return false }
                guard complete else { continue }
                let candidates = try replica.projectionCandidates()
                let preparationSnapshot = try await replica.projectionSnapshotAsync()
                try await hooks.prepareProjection(preparationSnapshot, candidates)
                try checkLease(generation)
                // A local edit may have arrived while downloading. Re-read the
                // current replica and allow only prepared immutable bindings.
                guard try drainPreparedJournal(lease: generation) else { continue }
                let currentCandidates = try replica.projectionCandidates()
                let projectionSnapshot = try await replica.projectionSnapshotAsync()
                try checkLease(generation)
                guard try bridge.nextBatch() == nil else { continue }
                let context = currentBusinessContext()
                guard context.container === container else { throw CarryAccountWorkspaceFailure.wrongBusinessContainer }
                let projected = try projector.project(snapshot: projectionSnapshot, candidateIDs: currentCandidates,
                    in: context, save: hooks.projectionSave)
                hooks.didProject(projected)
                try replica.markProjected(currentCandidates)
                if try replica.nextCommand() != nil { continue }
                state = .synchronized
                return true
            }
            state = .pending
            return false
        } catch is CancellationError {
            if lease == generation { state = .paused }
            throw CancellationError()
        } catch CarryReplicaFailure.projectionChanged {
            state = .pending
            return false
        } catch CarryReplicaFailure.blocked {
            state = .conflict
            return false
        } catch CarryAccountWorkspaceAssetFailure.preparationPending {
            state = .pending
            return false
        } catch {
            if lease != generation || !synchronizationEnabled || Task.isCancelled { throw CancellationError() }
            state = .failed
            throw error
        }
    }
}

/// Always presents streaming receipts, even for test/compatibility transports,
/// so publication pins are released only after the caller accepted its last page.
@MainActor
private final class CarryWorkspaceTransport: CarryGraphStreamingTransporting {
    let base: any CarryGraphTransporting
    let check: () throws -> Void
    let prepare: (CarryGraphCommand) async throws -> Void
    let accepted: (UUID) throws -> Void
    init(base: any CarryGraphTransporting, check: @escaping () throws -> Void,
         prepare: @escaping (CarryGraphCommand) async throws -> Void, accepted: @escaping (UUID) throws -> Void) {
        self.base = base; self.check = check; self.prepare = prepare; self.accepted = accepted
    }
    func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
        try check(); try await prepare(command); try check()
        let receipt = try await base.apply(command)
        try check()
        return receipt
    }
    func pull(cursor: Int) async throws -> CarryGraphPage {
        try check()
        let page = try await base.pull(cursor: cursor)
        try check()
        return page
    }
    func applyStreaming(_ command: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
                        receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws {
        try check(); try await prepare(command); try check()
        if let streaming = base as? any CarryGraphStreamingTransporting {
            try await streaming.applyStreaming(command, progress: progress) { summary, page, bytes in
                try self.check()
                try await receive(summary, page, bytes)
                // Acceptance may already be durable when pause invalidates the
                // network lease. Finish old-account pin bookkeeping before the
                // cancellation check; pauseAndWait still waits for this work.
                if !page.hasMore { try self.accepted(command.requestID) }
                try self.check()
            }
        } else {
            let receipt = try await base.apply(command)
            try check()
            let summary = CarryGraphReceiptSummary(status: receipt.status, requestID: receipt.requestID,
                cursor: receipt.cursor, changeCount: receipt.changes.count)
            let offset = progress?.nextOffset ?? 0
            guard offset <= receipt.changes.count else { throw CarryReplicaFailure.invalidReceipt }
            try await receive(summary, CarryGraphReceiptPage(requestID: receipt.requestID, cursor: receipt.cursor,
                changes: Array(receipt.changes.dropFirst(offset)), nextOffset: receipt.changes.count,
                hasMore: false, changeCount: receipt.changes.count), 0)
            try accepted(command.requestID)
            try check()
        }
    }
}
