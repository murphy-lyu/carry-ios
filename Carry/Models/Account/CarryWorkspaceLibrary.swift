import Foundation
import Combine
import SwiftData

enum CarryWorkspaceLibraryFailure: Error { case duplicateIdentity, accountAlreadyAttached, ownershipUnavailable }

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
    private var ownershipIndexes: [UUID: CarryMigrationOwnershipIndex] = [:]
    private var activeAccountID: UUID?
    private var ownershipDirectory: URL?
    private var ownershipIndexFailed = false
    private var hiddenLocalTripIDs: Set<UUID> { Set(ownershipIndexes.values.flatMap(\.roots).filter { $0.kind == "trip" && $0.active }.map(\.id)) }
    private var hiddenLocalLibraryIDs: Set<UUID> { Set(ownershipIndexes.values.flatMap(\.roots).filter { $0.kind == "libraryItem" && $0.active }.map(\.id)) }
    private var hiddenAccountTripIDs: Set<UUID> {
        guard let activeAccountID else { return [] }
        return Set(ownershipIndexes[activeAccountID]?.roots.filter { $0.kind == "trip" && !$0.active }.map(\.id) ?? []).union(localAccountCollisions.filter { $0.kind == "trip" }.map(\.rootID))
    }
    private var hiddenAccountLibraryIDs: Set<UUID> {
        guard let activeAccountID else { return [] }
        return Set(ownershipIndexes[activeAccountID]?.roots.filter { $0.kind == "libraryItem" && !$0.active }.map(\.id) ?? []).union(localAccountCollisions.filter { $0.kind == "libraryItem" }.map(\.rootID))
    }
    struct Collision: Identifiable, Equatable {
        var id: UUID { rootID }
        let rootID: UUID
        let kind: String
        let title: String
    }
    var localAccountCollisions: [Collision] {
        guard activeAccountID != nil else { return [] }
        let migrationPending = Set(ownershipIndexes[activeAccountID!]?.roots.filter { !$0.active && $0.adoptionID == nil }.map(\.id) ?? [])
        let trips = localTrips.filter { !hiddenLocalTripIDs.contains($0.id) && !migrationPending.contains($0.id) }
        var result = trips.filter { local in accountTrips.contains { $0.id == local.id } }.map { Collision(rootID: $0.id, kind: "trip", title: $0.name) }
        let localItems = local.myItems.filter { !hiddenLocalLibraryIDs.contains($0.id) && !migrationPending.contains($0.id) }
        result += localItems.filter { local in account?.myItems.contains { $0.id == local.id } == true }.map { Collision(rootID: $0.id, kind: "libraryItem", title: $0.name) }
        return result.sorted { $0.rootID.uuidString < $1.rootID.uuidString }
    }
    var migrationSourceTrips: [TripBundle] { let collisions = Set(localAccountCollisions.map(\.rootID)); return localTrips.filter { !hiddenLocalTripIDs.contains($0.id) && !collisions.contains($0.id) } }
    func configureOwnershipIndex(directory: URL) {
        ownershipDirectory = directory
        do {
            let indexes = try CarryMigrationOwnershipIndex.readAll(in: directory)
            ownershipIndexes = Dictionary(uniqueKeysWithValues: indexes.map { ($0.accountID, $0) })
            local.migrationWriteGuard.load(indexes: indexes)
            ownershipIndexFailed = false
            rebuild()
        } catch {
            local.migrationWriteGuard.blockAllWrites()
            ownershipIndexFailed = true
            failure = .ownershipUnavailable
        }
    }
    func updateOwnership(accountID: UUID, records: [CarryAccountMigrationOwnershipRecord], adoptions: [CarryAccountLocalAdoptionRecord] = [], materializedRootIDs: Set<UUID>? = nil) throws {
        let index = try CarryMigrationOwnershipIndex(accountID: accountID, records: records, adoptions: adoptions, materializedRootIDs: materializedRootIDs)
        guard let ownershipDirectory else { throw CarryMigrationOwnershipFailure.invalidState }
        try index.write(in: ownershipDirectory)
        ownershipIndexes[accountID] = index
        local.migrationWriteGuard.load(indexes: Array(ownershipIndexes.values))
        rebuild()
    }

    init(local: TripStore) {
        self.local = local; localTrips = local.trips; visibleTrips = local.trips
        CarryMigrationSourceFileRetention.register { [weak self] in
            guard let self else { return nil }
            return try self.currentProtectedFileNames()
        }
        local.visibleTripsProvider = { [weak self, weak local] in self?.visibleTrips ?? local?.trips ?? [] }
        local.visibleMyItemsProvider = { [weak self, weak local] in
            guard let self else { return local?.myItems ?? [] }
            return self.local.myItems.filter { !self.hiddenLocalLibraryIDs.contains($0.id) }
        }
        local.owningStoreProvider = { [weak self] id in self?.owningStore(for: id) }
        local.creationStoreProvider = { [weak self, unowned local] in self?.account ?? local }
        localSubscription = local.$trips.sink { [weak self] trips in
            guard let self else { return }
            self.localTrips = trips; self.rebuild()
        }
    }
    /// Old CloudKit clients may introduce a new immutable file reference after
    /// staging. Read both fresh persisted source and currently observed models
    /// at deletion time, without changing the approved source snapshot.
    private func currentProtectedFileNames() throws -> Set<String> {
        let ids = local.migrationWriteGuard.protectedRootIDs
        guard !ids.isEmpty else { return [] }
        var names: Set<String> = []
        func collect(_ trips: [TripBundle], _ items: [MyItem]) throws {
            func attachments(_ values: [ItineraryAttachment]?) {
                for item in values ?? [] where !item.fileName.isEmpty { names.insert(item.fileName) }
            }
            for trip in trips where ids.contains(trip.id) {
                let bytes = trip.backgroundsData
                if !bytes.isEmpty {
                    for background in try JSONDecoder().decode([TripBackgroundEntry].self, from: bytes) {
                        if let name = background.localFileName { names.insert(name) }
                    }
                }
                for day in trip.safeItineraryDays {
                    for stop in day.stops ?? [] {
                        attachments(stop.attachments)
                        for photo in stop.photos ?? [] where photo.assetLocalIdentifier.hasPrefix("carryphoto1_") { names.insert(photo.assetLocalIdentifier) }
                    }
                    for segment in day.segments ?? [] { attachments(segment.attachments) }
                }
                for stay in trip.safeLodgingStays { attachments(stay.attachments) }
            }
        }
        try collect(local.trips, local.myItems)
        let fresh = ModelContext(local.businessContext.container)
        try collect(fresh.fetch(FetchDescriptor<TripBundle>()), fresh.fetch(FetchDescriptor<MyItem>()))
        guard names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && $0.utf8.count <= 255 }) else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
        return names
    }
    private func rebuild() {
        if ownershipIndexFailed { failure = .ownershipUnavailable; return }
        let visibleLocal = localTrips.filter { !hiddenLocalTripIDs.contains($0.id) }
        let visibleAccount = accountTrips.filter { !hiddenAccountTripIDs.contains($0.id) }
        let localIDs = Set(visibleLocal.map(\.id)), accountIDs = Set(visibleAccount.map(\.id))
        guard localIDs.count == visibleLocal.count, accountIDs.count == visibleAccount.count,
              localIDs.isDisjoint(with: accountIDs) else {
            // Ambiguous ownership must never choose a mutable store arbitrarily.
            failure = .duplicateIdentity
            visibleTrips = visibleLocal
            local.objectWillChange.send()
            return
        }
        failure = localAccountCollisions.isEmpty ? nil : .duplicateIdentity
        visibleTrips = (visibleLocal + visibleAccount).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        local.objectWillChange.send()
    }
    func attach(_ store: TripStore, accountID: UUID? = nil) throws {
        guard account == nil else { throw CarryWorkspaceLibraryFailure.accountAlreadyAttached }
        let active = hiddenLocalTripIDs
        let pending = Set(accountID.flatMap { ownershipIndexes[$0] }?.roots.filter { $0.kind == "trip" && !$0.active }.map(\.id) ?? [])
        guard accountID != nil || Set(localTrips.filter { !active.contains($0.id) }.map(\.id)).isDisjoint(with: Set(store.trips.filter { !pending.contains($0.id) }.map(\.id))) else {
            throw CarryWorkspaceLibraryFailure.duplicateIdentity
        }
        activeAccountID = accountID
        account = store; accountTrips = store.trips
        store.visibleMyItemsProvider = { [weak self, weak store] in
            guard let store else { return [] }
            return store.myItems.filter { !(self?.hiddenAccountLibraryIDs.contains($0.id) ?? true) }
        }
        accountSubscription = store.$trips.sink { [weak self] trips in
            guard let self else { return }
            self.accountTrips = trips; self.rebuild()
            self.local.refreshVisibleEffects()
        }
        rebuild()
    }
    /// Caller pauses and awaits workspace I/O before removing its navigation.
    func detach() {
        accountSubscription = nil; account?.visibleMyItemsProvider = nil; account = nil; accountTrips = []; activeAccountID = nil; rebuild()
        local.refreshVisibleEffects()
    }
    func owningStore(for id: UUID) -> TripStore? {
        let inLocal = !hiddenLocalTripIDs.contains(id) && localTrips.contains { $0.id == id }
        let inAccount = !hiddenAccountTripIDs.contains(id) && accountTrips.contains { $0.id == id }
        guard inLocal != inAccount else { return nil }
        return inLocal ? local : account
    }
    func isActiveAccountRoot(_ id: UUID) -> Bool {
        guard let activeAccountID else { return false }
        return ownershipIndexes[activeAccountID]?.roots.contains { $0.id == id && $0.active } == true
    }
    var creationStore: TripStore { account ?? local }
}
