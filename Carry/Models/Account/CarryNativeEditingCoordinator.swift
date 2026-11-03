import Foundation

enum CarryNativeEditingFailure: Error { case busy }

@MainActor
final class CarryNativeEditorWriteOutcome {
    var failures = 0
    var wasBusy = false
}

nonisolated enum CarryNativeEditorWriteContext {
    @TaskLocal static var groupID: UUID?
    @TaskLocal static var outcome: CarryNativeEditorWriteOutcome?
}

/// Drafts retain the native materialization they actually displayed. Pulls and
/// receipts advance the durable replica, while native projection waits. Only
/// one top-level group may edit; read-only detail groups may coexist.
@MainActor
final class CarryNativeEditingCoordinator {
    private struct Session { let groupID: UUID; let readOnly: Bool }
    private var sessions: [UUID: Session] = [:]
    private var committingGroups: [UUID] = []
    private var maintenance: [() -> Void] = []
    private(set) var isInvalidated = false
    var didReleaseLastSession: (() -> Void)?
    var hasActiveSessions: Bool { !sessions.isEmpty }
    var hasEditingSessions: Bool { editingGroup != nil }
    private var editingGroup: UUID? { sessions.values.first(where: { !$0.readOnly })?.groupID }

    func isBusy(for groupID: UUID) -> Bool { editingGroup.map { $0 != groupID } ?? false }

    func acquire(groupID: UUID, readOnly: Bool = false) -> CarryNativeEditorLease? {
        guard !isInvalidated, readOnly || !isBusy(for: groupID) else { return nil }
        let id = UUID()
        sessions[id] = Session(groupID: groupID, readOnly: readOnly)
        return CarryNativeEditorLease(id: id, coordinator: self)
    }

    /// UI entry points validate before mutating any @Model. The synchronous
    /// authorization also covers existing methods that save several times.
    func withEditorWrite<Result>(groupID: UUID, _ operation: () -> Result) throws -> Result {
        guard !isInvalidated, !isBusy(for: groupID) else { throw CarryNativeEditingFailure.busy }
        committingGroups.append(groupID)
        defer { committingGroups.removeLast() }
        return operation()
    }

    /// Backstop for a native writer bypassing the trusted editor entry point.
    func validateBusinessWrite() throws {
        guard !isInvalidated,
              editingGroup == nil || (committingGroups.last ?? CarryNativeEditorWriteContext.groupID) == editingGroup else { throw CarryNativeEditingFailure.busy }
    }

    /// Late geocoding/maintenance is not authority to modify an open draft.
    /// Resume from a real editor lifecycle event, with no polling or delay.
    func performMaintenance(_ operation: @escaping () -> Void) {
        guard !isInvalidated else { return }
        if editingGroup == nil || committingGroups.last == editingGroup { operation() }
        else { maintenance.append(operation) }
    }

    fileprivate func release(_ id: UUID) {
        guard sessions.removeValue(forKey: id) != nil, !isInvalidated else { return }
        if editingGroup == nil {
            let ready = maintenance
            maintenance.removeAll()
            for operation in ready { guard !isInvalidated else { break }; operation() }
        }
        if sessions.isEmpty { didReleaseLastSession?() }
    }

    func invalidate() {
        isInvalidated = true
        sessions.removeAll()
        maintenance.removeAll()
        didReleaseLastSession = nil
    }
}

@MainActor
final class CarryNativeEditorLease {
    private let id: UUID
    private let coordinator: CarryNativeEditingCoordinator
    private var isClosed = false

    fileprivate init(id: UUID, coordinator: CarryNativeEditingCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        coordinator.release(id)
    }

    deinit {
        let owner = coordinator, sessionID = id
        Task { @MainActor in owner.release(sessionID) }
    }
}
