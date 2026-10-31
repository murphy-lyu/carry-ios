import Foundation
import Combine

enum CarryWorkspaceLibraryFailure: Error { case duplicateIdentity, accountAlreadyAttached }

/// Read aggregation never places models from another container in TripStore.
/// Mutations are routed to the owning store, preserving its journal/save gate.
@MainActor
final class CarryWorkspaceLibrary: ObservableObject {
    let local: TripStore
    @Published private(set) var account: TripStore?
    @Published private(set) var visibleTrips: [TripBundle]
    @Published private(set) var failure: CarryWorkspaceLibraryFailure?
    private var localSubscription: AnyCancellable?
    private var accountSubscription: AnyCancellable?
    private var localTrips: [TripBundle]
    private var accountTrips: [TripBundle] = []

    init(local: TripStore) {
        self.local = local; localTrips = local.trips; visibleTrips = local.trips
        local.visibleTripsProvider = { [weak self, weak local] in self?.visibleTrips ?? local?.trips ?? [] }
        local.owningStoreProvider = { [weak self] id in self?.owningStore(for: id) }
        local.creationStoreProvider = { [weak self, unowned local] in self?.account ?? local }
        localSubscription = local.$trips.sink { [weak self] trips in
            guard let self else { return }
            self.localTrips = trips; self.rebuild()
        }
    }
    private func rebuild() {
        let localIDs = Set(localTrips.map(\.id)), accountIDs = Set(accountTrips.map(\.id))
        guard localIDs.count == localTrips.count, accountIDs.count == accountTrips.count,
              localIDs.isDisjoint(with: accountIDs) else {
            // Ambiguous ownership must never choose a mutable store arbitrarily.
            failure = .duplicateIdentity
            visibleTrips = localTrips
            local.objectWillChange.send()
            return
        }
        failure = nil
        visibleTrips = (localTrips + accountTrips).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        local.objectWillChange.send()
    }
    func attach(_ store: TripStore) throws {
        guard account == nil else { throw CarryWorkspaceLibraryFailure.accountAlreadyAttached }
        guard Set(localTrips.map(\.id)).isDisjoint(with: Set(store.trips.map(\.id))) else {
            throw CarryWorkspaceLibraryFailure.duplicateIdentity
        }
        account = store; accountTrips = store.trips
        accountSubscription = store.$trips.sink { [weak self] trips in
            guard let self else { return }
            self.accountTrips = trips; self.rebuild()
            self.local.refreshVisibleEffects()
        }
        rebuild()
    }
    /// Caller pauses and awaits workspace I/O before removing its navigation.
    func detach() {
        accountSubscription = nil; account = nil; accountTrips = []; rebuild()
        local.refreshVisibleEffects()
    }
    func owningStore(for id: UUID) -> TripStore? {
        let inLocal = localTrips.contains { $0.id == id }, inAccount = accountTrips.contains { $0.id == id }
        guard inLocal != inAccount else { return nil }
        return inLocal ? local : account
    }
    var creationStore: TripStore { account ?? local }
}
