import Foundation
import SwiftData
import Combine

enum CarryAccountWorkspaceControllerFailure: Error { case busy, unavailable, invalidOwner, missingSource }

/// Owns one active account's entire IO lifetime. Guest data stays in the root
/// store. Enabling creates an empty account cache or reopens that owner's cache.
@MainActor
final class CarryAccountWorkspaceController: ObservableObject {
    struct Dependencies {
        let transport: any CarryGraphTransporting
        let manifest: CarryAccountWorkspaceAssets.Manifest
        let download: CarryAccountWorkspaceAssets.Download
        let upload: CarryNativeAssetCoordinator.Upload
        let close: () async -> Void
    }
    typealias Factory = (UUID, URL) async throws -> Dependencies
    private final class StoreReference { weak var store: TripStore? }
    private struct Runtime {
        let accountID: UUID
        let container: ModelContainer
        let workspace: CarryAccountWorkspace
        let store: TripStore
        let cache: CarryAccountAssetCache
        let uploads: CarryNativeAssetCoordinator
        let assets: CarryAccountWorkspaceAssets
        let importer: CarryAccountImportService
        let lease: CarryAccountFileAccess.Lease
        let dependencies: Dependencies
    }
    @Published private(set) var accountID: UUID?
    @Published private(set) var workspace: CarryAccountWorkspace?
    @Published private(set) var failure: Error?
    @Published private(set) var migrationBusy = false
    @Published private(set) var migrationFailureKey: String?
    @Published private(set) var migrationFinished = false
    private var migrationTask: Task<Void, Error>?
    private let rootDirectory: URL
    private let library: CarryWorkspaceLibrary
    private let access: CarryAccountFileAccess
    private let factory: Factory
    private let clearAccountNavigation: () -> Void
    private var runtime: Runtime?
    private var transition = false
    private var syncTask: Task<Void, Never>?
    private var enableTask: (id: UUID, task: Task<Void, Error>)?
    private var syncRequested = false
    private var isSuspended = true

    init(library: CarryWorkspaceLibrary, rootDirectory: URL, access: CarryAccountFileAccess? = nil,
         factory: @escaping Factory, clearAccountNavigation: @escaping () -> Void = {}) {
        self.library = library; self.rootDirectory = rootDirectory
        self.access = access ?? .shared; self.factory = factory; self.clearAccountNavigation = clearAccountNavigation
        library.configureOwnershipIndex(directory: rootDirectory)
    }

    convenience init(library: CarryWorkspaceLibrary, service: CarryAccountService,
                     clearAccountNavigation: @escaping () -> Void = {}) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CarryAccounts", isDirectory: true)
        self.init(library: library, rootDirectory: directory, factory: { accountID, directory in
            guard let configuration = service.workspaceConfiguration else { throw CarryAccountWorkspaceControllerFailure.unavailable }
            let graph = try service.graphTransport(for: accountID)
            let transfer = try service.assetTransfer(for: accountID, directory: directory.appendingPathComponent("transfers"))
            var manifestToClose: CarryAccountAssetManifestClient?
            do {
                let manifest = try CarryAccountAssetManifestClient(accountID: accountID, projectURL: configuration.projectURL,
                    publishableKey: configuration.publishableKey, accessToken: { try await service.accessToken(for: accountID) })
                manifestToClose = manifest
                let downloader = try CarryAssetDownloader(accountID: accountID, projectURL: configuration.projectURL,
                    directory: directory.appendingPathComponent("transfers"), publishableKey: configuration.publishableKey,
                    accessToken: { try await service.accessToken(for: accountID) })
                return Dependencies(transport: graph,
                    manifest: { try await manifest.manifest($0) }, download: { asset in
                        if let cached = try await downloader.cached(asset) { return cached }
                        return try await downloader.download(asset)
                    }, upload: { try await transfer.transfer($0, from: $1) }, close: {
                        await manifest.close(); await transfer.close()
                        do { try await downloader.close() }
                        catch { CarryLogger.shared.log(.persistFailed, context: "account_downloader_close") }
                    })
            } catch {
                if let manifestToClose { await manifestToClose.close() }
                await transfer.close()
                throw error
            }
        }, clearAccountNavigation: clearAccountNavigation)
    }

    /// Explicit cloud opt-in only. The caller establishes the authenticated
    /// identity; this API does not select or upload existing local trips.
    func enable(accountID: UUID) async throws {
        try await activate(accountID: accountID, allowNetwork: true)
    }

    /// Restores an existing owner's offline cache only. It neither creates a
    /// new account cache nor contacts graph, asset or authentication endpoints.
    @discardableResult
    func openCached(accountID: UUID) async throws -> Bool {
        if self.accountID == accountID, runtime != nil { await suspend(); return true }
        let url = rootDirectory.appendingPathComponent(accountID.uuidString.lowercased()).appendingPathComponent("account.store")
        guard await Self.exists(url) else { return false }
        try await activate(accountID: accountID, allowNetwork: false)
        return true
    }
    private func activate(accountID: UUID, allowNetwork: Bool) async throws {
        try Task.checkCancellation()
        guard enableTask == nil else { throw CarryAccountWorkspaceControllerFailure.busy }
        let id = UUID(), task = Task { @MainActor in try await self.performEnable(accountID: accountID, allowNetwork: allowNetwork) }
        enableTask = (id, task)
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            if enableTask?.id == id { enableTask = nil }
        } catch {
            if enableTask?.id == id { enableTask = nil }
            if !(error is CancellationError) { failure = error }
            throw error
        }
    }
    private func performEnable(accountID: UUID, allowNetwork: Bool) async throws {
        try Task.checkCancellation()
        guard !transition else { throw CarryAccountWorkspaceControllerFailure.busy }
        if self.accountID == accountID, let current = runtime {
            isSuspended = false
            current.workspace.enableSynchronization()
            transition = false
            requestSynchronization()
            return
        }
        transition = true; defer { transition = false }
        await closeRuntime()
        try Task.checkCancellation()
        let directory = rootDirectory.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        try await Self.prepareDirectory(directory)
        let container = try CarryAccountReplica.container(at: directory.appendingPathComponent("account.store"))
        let cache = try CarryAccountAssetCache(root: directory.appendingPathComponent("assets"), accountID: accountID)
        // The old runtime has fully stopped; the new factory, import lease,
        // store and navigation have not been exposed. This is the exclusive
        // writer gate required by retention across all background file IO.
        do {
            let replica = try CarryAccountReplica(container: container, accountID: accountID)
            let retention = try CarryAccountAssetRetention(accountID: accountID, replica: replica, cache: cache, pins: { .init() })
            _ = try await retention.collect(lease: .init(accountID: accountID, isValid: {
                self.transition && self.runtime == nil && self.accountID == nil
            }))
        } catch is CancellationError { throw CancellationError() }
        catch { CarryLogger.shared.log(.persistFailed, context: "account_startup_retention_deferred") }
        try Task.checkCancellation()
        let dependencies = try await factory(accountID, directory)
        var openedLease: CarryAccountFileAccess.Lease?
        do {
            try Task.checkCancellation()
            let lease = try access.begin(accountID: accountID)
            openedLease = lease
            let assets = try CarryAccountWorkspaceAssets(accountID: accountID, cache: cache,
                manifest: dependencies.manifest, download: dependencies.download)
            let fileAccess = access
            let uploads = try CarryNativeAssetCoordinator(accountID: accountID, cache: cache, resolveSource: { request in
                try await MainActor.run {
                    guard request.accountID == accountID,
                          let url = fileAccess.url(named: request.reference) else { throw CarryAccountWorkspaceControllerFailure.missingSource }
                    return url
                }
            }, upload: dependencies.upload)
            let importer = try CarryAccountImportService(accountID: accountID, cache: cache, access: access, lease: lease)
            let context = ModelContext(container), reference = StoreReference()
            context.autosaveEnabled = false
            var hooks = CarryAccountWorkspace.Hooks()
            hooks.prepareJournal = uploads.prepareJournal
            hooks.resolveFields = uploads.resolveFields
            hooks.didConsumeJournal = uploads.didConsumeJournal
            hooks.preparePublication = { command, raw in try await uploads.preparePublication(command, in: raw) }
            hooks.didAcceptPublication = { id, raw in try uploads.releasePublication(requestID: id, in: raw) }
            hooks.prepareProjection = { snapshot, candidates in
                try await assets.prepare(snapshot: snapshot, candidateIDs: candidates, in: ModelContext(container))
                try fileAccess.publish(assets.preparedReadyURLs, lease: lease)
            }
            hooks.resolveProjectionAssets = assets.resolve
            hooks.projectionSave = { try assets.saveProjection($0) }
            hooks.didProject = { _ in reference.store?.refresh() }
            let workspace = try CarryAccountWorkspace(accountID: accountID, container: container, transport: dependencies.transport,
                businessContext: { reference.store?.businessContext ?? context }, hooks: hooks)
            let store = TripStore(context: context, persistenceSave: workspace.businessSave, scope: .account(didChange: { [weak self] in
                self?.library.local.refreshVisibleEffects()
                self?.requestSynchronization()
            }))
            reference.store = store; store.assetImporter = importer; store.refresh()
            let value = Runtime(accountID: accountID, container: container, workspace: workspace, store: store,
                cache: cache, uploads: uploads, assets: assets, importer: importer, lease: lease, dependencies: dependencies)
            // Reopen offline files from durable jobs before showing native views.
            let warmFailure = try await warmFiles(value, allowNetwork: allowNetwork)
            try Task.checkCancellation()
            let ownership = try CarryAccountMigrationOwnership(accountID: accountID, context: workspace.replica.context)
            try library.updateOwnership(accountID: accountID, records: ownership.records(), adoptions: try CarryAccountLocalAdoption(accountID: accountID, context: ModelContext(container)).records(), materializedRootIDs: try await verifiedAdoptionRoots(value))
            try library.attach(store, accountID: accountID)
            runtime = value; self.accountID = accountID; self.workspace = workspace; failure = warmFailure
            isSuspended = !allowNetwork
            transition = false
            if allowNetwork { workspace.enableSynchronization(); requestSynchronization() }
        } catch {
            if let openedLease { access.revoke(openedLease) }
            await dependencies.close()
            failure = error
            throw error
        }
    }

    func requestSynchronization() {
        guard !transition, !isSuspended, let current = runtime, current.workspace.state != .paused else { return }
        syncRequested = true
        guard syncTask == nil else { return }
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.failure = nil
            defer { self.syncTask = nil }
            do {
                while !Task.isCancelled {
                    self.syncRequested = false
                    let before = try self.progress(current)
                    let complete = try await current.workspace.synchronize()
                    self.failure = nil
                    guard !Task.isCancelled, self.runtime?.accountID == current.accountID else { return }
                    if current.workspace.state == .conflict || current.workspace.state == .paused || current.workspace.state == .failed { return }
                    let progressed = try self.progress(current) != before
                    guard self.syncRequested || (!complete && current.workspace.state == .pending && progressed) else { return }
                    // Continue real bounded work (journal/assets/history), not
                    // a clock-based polling loop. No progress leaves pending.
                    await Task.yield()
                }
            }
            catch is CancellationError { }
            catch { self.failure = error }
        }
    }

    private func progress(_ current: Runtime) throws -> [String] {
        let raw = current.workspace.replica.context
        let checkpoint = try raw.fetch(FetchDescriptor<CarryReplicaCheckpoint>()).first
        var value = [String(checkpoint?.cursor ?? 0), checkpoint?.flightID?.uuidString ?? "",
            try current.workspace.bridge.nextBatch()?.id.uuidString ?? "",
            String(current.assets.retainedTokens.count)]
        if let flight = checkpoint?.flightID {
            value.append(String(try current.workspace.replica.receiptProgress(for: flight)?.nextOffset ?? 0))
        }
        return value
    }

    /// Called before sign-out, deletion or identity changes. Cache and pending
    /// journals remain on disk; only this identity's navigation/read lease ends.
    func close() async throws {
        if let migrating = migrationTask {
            migrating.cancel(); _ = await migrating.result
            migrationTask = nil
        }
        if let preparing = enableTask {
            preparing.task.cancel()
            _ = await preparing.task.result
            if enableTask?.id == preparing.id { enableTask = nil }
        }
        guard !transition else { throw CarryAccountWorkspaceControllerFailure.busy }
        transition = true; defer { transition = false }
        await closeRuntime()
    }

    /// Session expiry/offline state pauses delivery while retaining the local
    /// account graph, navigation and verified file lease for offline editing.
    func suspend() async {
        if let migrating = migrationTask {
            migrating.cancel(); _ = await migrating.result
            migrationTask = nil
        }
        await pauseSynchronization()
    }
    private func pauseSynchronization() async {
        isSuspended = true
        if let preparing = enableTask {
            preparing.task.cancel()
            _ = await preparing.task.result
            if enableTask?.id == preparing.id { enableTask = nil }
        }
        guard let current = runtime else { return }
        syncTask?.cancel()
        await current.workspace.pauseAndWait()
        if let syncTask { await syncTask.value }
        await current.workspace.pauseAndWait()
        syncTask = nil
        syncRequested = false
    }
    private func closeRuntime() async {
        isSuspended = true
        guard let current = runtime else { return }
        current.workspace.revokeWriterLease()
        current.importer.close(); current.uploads.close(); current.assets.close()
        syncTask?.cancel()
        await current.workspace.pauseAndWait()
        await current.dependencies.close()
        if let syncTask { await syncTask.value }
        syncTask = nil
        syncRequested = false
        clearAccountNavigation()
        library.detach()
        access.revoke(current.lease)
        runtime = nil; accountID = nil; workspace = nil
    }
    private func warmFiles(_ current: Runtime, allowNetwork: Bool) async throws -> Error? {
        let context = ModelContext(current.container)
        var unavailable: Error?
        let changes = try context.fetch(FetchDescriptor<CarryNativeChange>())
        let materialized = try context.fetch(FetchDescriptor<CarryNativeMaterialization>())
        let sources = materialized.map(\.sourceData) + changes.flatMap { change in
            [change.sourceData] + (change.previousSourceData.map { [$0] } ?? [])
        }
        let nativeTokens = try await Self.nativeTokens(sources, accountID: current.accountID)
        for token in nativeTokens {
            do {
                let snapshot = try await current.cache.verify(token)
                let url = try await current.cache.verify(snapshot)
                try access.publish([token.rawValue: url], lease: current.lease)
            } catch {
                if error is CancellationError { throw error }
                unavailable = error
            }
        }
        let bindings = try context.fetch(FetchDescriptor<CarryAccountAssetBinding>())
        guard bindings.allSatisfy({ $0.accountID == current.accountID }) else { throw CarryAccountWorkspaceControllerFailure.invalidOwner }
        let bound = Set(bindings.map(\.assetID))
        for job in try context.fetch(FetchDescriptor<CarryAccountAssetJob>()) where bound.contains(job.assetID) || !job.frozenRequestIDs.isEmpty {
            let token = try CarryAccountAssetToken(rawValue: job.fileToken)
            guard job.accountID == current.accountID, token.accountID == current.accountID,
                  token.assetID == job.assetID, token.sha256 == job.sha256,
                  try CarryAccountAssetIdentity.id(accountID: current.accountID, entityID: job.entityID,
                    slot: job.slot, sha256: job.sha256) == job.assetID else { throw CarryAccountWorkspaceControllerFailure.invalidOwner }
            let snapshot = CarryAccountAssetSnapshot(token: token, byteCount: job.byteCount)
            let url: URL
            do { url = try await current.cache.verify(snapshot) }
            catch {
                if !allowNetwork { unavailable = error; continue }
                // Only a remotely verified asset may be recovered from the
                // account service. Missing unsent originals remain an explicit
                // error; neither their journals nor source records are removed.
                guard job.phase == "verified" else { throw error }
                let metadata = try await current.dependencies.manifest(job.assetID)
                guard metadata.accountID == current.accountID, metadata.assetID == job.assetID,
                      metadata.entityID == job.entityID, metadata.kind == job.entityKind, metadata.slot == job.slot,
                      metadata.sha256 == job.sha256, metadata.byteCount == job.byteCount else {
                    throw CarryAccountWorkspaceControllerFailure.invalidOwner
                }
                let downloaded = try await current.dependencies.download(CarryAssetDownload(id: job.assetID, accountID: current.accountID,
                    sha256: job.sha256, byteCount: job.byteCount))
                let restored = try await current.cache.snapshot(fileURL: downloaded, assetID: job.assetID,
                    expectedSHA256: job.sha256, expectedByteCount: job.byteCount)
                url = try await current.cache.verify(restored)
            }
            try access.publish([token.rawValue: url], lease: current.lease)
        }
        if allowNetwork {
            if nativeTokens.contains(where: { access.url(named: $0.rawValue) == nil }), let unavailable { throw unavailable }
            return nil
        }
        return unavailable
    }
    @concurrent nonisolated private static func nativeTokens(_ sources: [Data], accountID: UUID) async throws -> Set<CarryAccountAssetToken> {
        var result: Set<CarryAccountAssetToken> = []
        for bytes in sources {
            try Task.checkCancellation()
            let source = try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: bytes)
            var files = source.fileReferences
            if source.kind == "photo", case .string(let name) = source.fields["assetLocalIdentifier"], CarryAccountFileAccess.isAccountReference(name) {
                files["original"] = name
            }
            for (slot, name) in files {
                guard CarryAccountFileAccess.isAccountReference(name) else { throw CarryAccountWorkspaceControllerFailure.missingSource }
                let token = try CarryAccountAssetToken(rawValue: name)
                guard token.accountID == accountID else {
                    throw CarryAccountWorkspaceControllerFailure.invalidOwner
                }
                // A duplicate may reference prior immutable bytes from another
                // entity in THIS account. The upload coordinator re-snapshots
                // those bytes under the new entity/slot identity before binding.
                _ = slot
                result.insert(token)
            }
        }
        return result
    }
    private nonisolated static func prepareDirectory(_ directory: URL) async throws {
        let task = Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var value = directory, resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try value.setResourceValues(resources)
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    @concurrent nonisolated private static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}


extension CarryAccountWorkspaceController {
    var migrationCandidates: [TripBundle] { library.migrationSourceTrips }
    var localLibraryCount: Int { let collisions = Set(library.localAccountCollisions.map(\.rootID)); return library.local.myItems.filter { !library.local.migrationWriteGuard.isProtected($0.id) && !collisions.contains($0.id) }.count }

    private static func materializedRootIDs(_ store: TripStore) -> Set<UUID> {
        Set(store.trips.map(\.id)).union(store.myItems.map(\.id))
    }
    private static func routingRootIDs(_ store: TripStore) throws -> Set<UUID> {
        try materializedRootIDs(store).union(CarryAccountLocalAdoption.verifiedDeletedRoots(in: ModelContext(store.businessContext.container)))
    }
    func isMigrationMaterialized(batchID: UUID) -> Bool {
        guard let current = runtime,
              let ownership = try? CarryAccountMigrationOwnership(accountID: current.accountID, context: ModelContext(current.container)),
              let records = try? ownership.records() else { return false }
        let roots = records.filter { $0.batchID == batchID }
        return !roots.isEmpty && roots.allSatisfy { $0.active && library.isActiveAccountRoot($0.rootID) }
    }
    private func projectMigration(_ proof: CarryAccountMigrationProof, current: Runtime) async throws {
        current.workspace.enableSynchronization()
        guard try await current.workspace.synchronize() else { throw CarryMigrationOwnershipFailure.invalidState }
        try Task.checkCancellation()
        guard runtime?.accountID == current.accountID,
              proof.tripIDs.isSubset(of: Set(current.store.trips.map(\.id))),
              proof.libraryIDs.isSubset(of: Set(current.store.myItems.map(\.id))) else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
    }

    func migrationBatches() throws -> [CarryAccountMigrationBatch] {
        guard let current = runtime else { return [] }
        return try ModelContext(current.container).fetch(FetchDescriptor<CarryAccountMigrationBatch>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    /// The view selects exact roots. No current trip is migrated as a side
    /// effect of signing in, enabling synchronization or opening this screen.
    func migrate(tripIDs: Set<UUID>, includeLibrary: Bool) async throws {
        guard migrationTask == nil, !migrationBusy, let current = runtime, !isSuspended else {
            throw CarryAccountWorkspaceControllerFailure.busy
        }
        let task = Task { @MainActor in try await self.performMigration(current, tripIDs: tripIDs, includeLibrary: includeLibrary) }
        migrationTask = task
        migrationBusy = true; migrationFailureKey = nil; migrationFinished = false
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            migrationTask = nil; migrationBusy = false; migrationFinished = true
        } catch {
            migrationTask = nil; migrationBusy = false
            migrationFailureKey = Self.migrationMessage(error)
            throw error
        }
    }

    private func performMigration(_ current: Runtime, tripIDs: Set<UUID>, includeLibrary: Bool) async throws {
        let sourceStore = library.local
        guard !sourceStore.businessContext.hasChanges else { throw CarryMigrationOwnershipFailure.sourceChanged }
        guard tripIDs.allSatisfy({ !sourceStore.migrationWriteGuard.isProtected($0) }) else { throw CarryMigrationOwnershipFailure.sourceReadOnly }
        let trips = sourceStore.trips.filter { tripIDs.contains($0.id) }
        let items = includeLibrary ? sourceStore.myItems.filter { item in !sourceStore.migrationWriteGuard.isProtected(item.id) && !self.library.localAccountCollisions.contains(where: { $0.rootID == item.id }) } : []
        guard trips.count == tripIDs.count, Set(items.map(\.id)).count == items.count, !trips.isEmpty || !items.isEmpty,
              tripIDs.isSubset(of: Set(migrationCandidates.map(\.id))) else { throw CarryMigrationOwnershipFailure.invalidScope }
        let snapshots = try trips.map { try CarryMigrationSourceSnapshot.capture(trip: $0) } + items.map { try CarryMigrationSourceSnapshot.capture(item: $0) }
        let fingerprints = try Dictionary(uniqueKeysWithValues: snapshots.map { ($0.rootID, try $0.fingerprint()) })
        let batchID = UUID()
        sourceStore.migrationWriteGuard.protect(batchID: batchID, snapshots: snapshots)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryMigrationPreparation-" + UUID().uuidString, isDirectory: true)
        var persistedBatchID: UUID?
        do {
            await pauseSynchronization()
            defer {
                if runtime?.accountID == current.accountID, !Task.isCancelled {
                    isSuspended = false; current.workspace.enableSynchronization(); requestSynchronization()
                }
            }
            try await Self.prepareDirectory(directory)
            let bare = DataBackupManager.shared.migrationSnapshot(trips: trips, myItems: items)
            let urls = try Self.sourceFileURLs(bare)
            let photos = bare.trips.flatMap { $0.itineraryDays ?? [] }.flatMap(\.stops).flatMap { $0.photos ?? [] }
            let originals = try await CarryMigrationPhotoCollector().collect(photos, directory: directory)
            let prepared = try await CarryMigrationBackupPreparation.prepare(bare, attachments: urls.attachments,
                backgrounds: urls.backgrounds, originalPhotos: originals, directory: directory)
            try Task.checkCancellation()
            guard runtime?.accountID == current.accountID else { throw CancellationError() }
            let packet = try await Self.migrationPacket(prepared.backup, accountID: current.accountID, batchID: batchID,
                tripIDs: tripIDs, includeLibrary: includeLibrary)
            let raw = ModelContext(current.container); raw.autosaveEnabled = false
            let engine = try CarryAccountTripMigration(accountID: current.accountID, context: raw, cache: current.cache,
                backupRoot: rootDirectory.appendingPathComponent(current.accountID.uuidString.lowercased()).appendingPathComponent("migration-backups"))
            let preparedID = try await engine.prepare(packet: packet, sourceFingerprints: fingerprints,
                backupURL: prepared.url, originalPhotos: prepared.originalPhotos)
            persistedBatchID = preparedID
            let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: raw)
            do { try ownership.stage(batchID: preparedID, snapshots: snapshots); try raw.save() }
            catch { raw.rollback(); throw error }
            // Pending recovery index is durable before the first network write.
            try library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container)).records(), materializedRootIDs: try Self.routingRootIDs(current.store))
            let transport = CarryMigrationGuardedTransport(base: current.dependencies.transport, valid: { self.runtime?.accountID == current.accountID })
            let proof = try await engine.run(batchID: preparedID, transport: transport, upload: current.dependencies.upload,
                manifest: current.dependencies.manifest, validateSource: {
                    try Task.checkCancellation()
                    return try self.sourceFingerprints(tripIDs: tripIDs, libraryIDs: Set(items.map(\.id)))
                }, activate: { proof, transaction in
                    try Task.checkCancellation()
                    guard self.runtime?.accountID == proof.accountID else { throw CancellationError() }
                    try CarryAccountMigrationOwnership(accountID: proof.accountID, context: transaction).activate(proof)
                })
            try await projectMigration(proof, current: current)
            try library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container)).records(), materializedRootIDs: try Self.routingRootIDs(current.store))
            sourceStore.migrationWriteGuard.release(batchID: batchID)
            try await CarryMigrationBackupPreparation.discard(directory)
        } catch {
            if persistedBatchID == nil { sourceStore.migrationWriteGuard.release(batchID: batchID) }
            do { try await CarryMigrationBackupPreparation.discard(directory) }
            catch { CarryLogger.shared.log(.loadFailed, context: "migration_preparation_cleanup") }
            throw error
        }
    }

    func resumeMigration(batchID: UUID) async throws {
        guard migrationTask == nil, !migrationBusy, let current = runtime, !isSuspended else { throw CarryAccountWorkspaceControllerFailure.busy }
        migrationBusy = true; migrationFailureKey = nil; migrationFinished = false
        let task = Task { @MainActor in
            await self.pauseSynchronization()
            defer {
                if self.runtime?.accountID == current.accountID, !Task.isCancelled {
                    self.isSuspended = false; current.workspace.enableSynchronization(); self.requestSynchronization()
                }
            }
            let raw = ModelContext(current.container); raw.autosaveEnabled = false
            let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: raw)
            let selected = try ownership.records().filter { $0.batchID == batchID }
            guard !selected.isEmpty else { throw CarryMigrationOwnershipFailure.invalidState }
            let trips = Set(selected.filter { $0.kind == "trip" }.map(\.rootID))
            let items = Set(selected.filter { $0.kind == "libraryItem" }.map(\.rootID))
            let engine = try CarryAccountTripMigration(accountID: current.accountID, context: raw, cache: current.cache,
                backupRoot: self.rootDirectory.appendingPathComponent(current.accountID.uuidString.lowercased()).appendingPathComponent("migration-backups"))
            let approvedEvidence = try engine.approvedRecoveryEvidence(batchID: batchID)
            let validateRecovery: (() throws -> [CarryMigrationRecoveryEvidence])? = approvedEvidence.map { evidence in
                { try self.recaptureRecoveryEvidence(evidence) }
            }
            do {
                let proof = try await engine.run(batchID: batchID,
                    transport: CarryMigrationGuardedTransport(base: current.dependencies.transport, valid: { self.runtime?.accountID == current.accountID }),
                    upload: current.dependencies.upload, manifest: current.dependencies.manifest,
                    validateSource: { try Task.checkCancellation(); return try self.sourceFingerprints(tripIDs: trips, libraryIDs: items) },
                    validateRecovery: validateRecovery,
                    activate: { proof, transaction in
                        try Task.checkCancellation()
                        guard self.runtime?.accountID == proof.accountID else { throw CancellationError() }
                        try CarryAccountMigrationOwnership(accountID: proof.accountID, context: transaction).activate(proof)
                    })
                try await self.projectMigration(proof, current: current)
                try self.library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container)).records(), materializedRootIDs: try Self.routingRootIDs(current.store))
            } catch {
                throw error
            }
        }
        migrationTask = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            migrationTask = nil; migrationBusy = false; migrationFinished = true
        } catch {
            migrationTask = nil; migrationBusy = false; migrationFailureKey = Self.migrationMessage(error); throw error
        }
    }
    func cancelPreparedMigration(batchID: UUID) async throws {
        guard let current = runtime else { throw CarryAccountWorkspaceControllerFailure.unavailable }
        defer {
            if runtime?.accountID == current.accountID, !Task.isCancelled {
                isSuspended = false; current.workspace.enableSynchronization(); requestSynchronization()
            }
        }
        if let task = migrationTask { task.cancel(); _ = await task.result; migrationTask = nil }
        let raw = ModelContext(current.container); raw.autosaveEnabled = false
        var query = FetchDescriptor<CarryAccountMigrationBatch>(predicate: #Predicate { $0.id == batchID })
        query.fetchLimit = 1
        guard let batch = try raw.fetch(query).first, batch.accountID == current.accountID,
              !batch.publicationStarted, ["prepared", "uploading", "sourceChanged"].contains(batch.phase) else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
        let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: raw)
        do { try ownership.cancel(batchID: batchID); batch.phase = "cancelled"; try raw.save() }
        catch { raw.rollback(); throw error }
        try library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container)).records(), materializedRootIDs: try Self.routingRootIDs(current.store))
        library.local.migrationWriteGuard.release(batchID: batchID)
        migrationBusy = false; migrationFailureKey = nil
    }
    func migrationForkReview(batchID: UUID) throws -> CarryMigrationForkReview {
        guard let current = runtime else { throw CarryAccountWorkspaceControllerFailure.unavailable }
        let raw = ModelContext(current.container)
        let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: raw)
        let records = try ownership.records().filter { $0.batchID == batchID }
        let source = ModelContext(library.local.businessContext.container)
        let trips = try Self.selectedLocalTrips(Set(records.filter { $0.kind == "trip" }.map(\.rootID)), in: source)
        let items = try Self.selectedLocalItems(Set(records.filter { $0.kind == "libraryItem" }.map(\.rootID)), in: source)
        var snapshots: [CarryMigrationSourceSnapshot] = [], differences: [CarryMigrationSourceDifference] = []
        for record in records {
            let snapshot: CarryMigrationSourceSnapshot
            if record.kind == "trip", let trip = trips[record.rootID] { snapshot = try CarryMigrationSourceSnapshot.capture(trip: trip) }
            else if record.kind == "libraryItem", let item = items[record.rootID] { snapshot = try CarryMigrationSourceSnapshot.capture(item: item) }
            else { snapshot = CarryMigrationSourceSnapshot(rootID: record.rootID, kind: record.kind, entities: []) }
            snapshots.append(snapshot)
            differences += try ownership.differences(rootID: record.rootID, current: snapshot)
        }
        guard !snapshots.isEmpty else { throw CarryMigrationOwnershipFailure.invalidScope }
        return CarryMigrationForkReview(batchID: batchID, sources: snapshots.sorted { $0.rootID.uuidString < $1.rootID.uuidString },
            differences: differences.sorted { $0.entityID.uuidString < $1.entityID.uuidString })
    }
    func keepBothMigrationVersions(_ review: CarryMigrationForkReview) async throws {
        try Task.checkCancellation()
        guard !isSuspended, !library.local.businessContext.hasChanges else { throw CarryMigrationOwnershipFailure.sourceChanged }
        let batchID = review.batchID
        guard try migrationForkReview(batchID: batchID) == review else { throw CarryMigrationOwnershipFailure.sourceChanged }
        guard !migrationBusy, migrationTask == nil, let current = runtime else { throw CarryAccountWorkspaceControllerFailure.busy }
        let raw = ModelContext(current.container); raw.autosaveEnabled = false
        let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: raw)
        let records = try ownership.records().filter { $0.batchID == batchID }
        guard !records.isEmpty else { throw CarryMigrationOwnershipFailure.invalidState }
        var query = FetchDescriptor<CarryAccountMigrationBatch>(predicate: #Predicate { $0.id == batchID }); query.fetchLimit = 1
        guard let batch = try raw.fetch(query).first, batch.publicationStarted, batch.phase == "sourceChanged" else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
        // A stale review cannot authorize a different source. Capturing and
        // saving the full recovery graph occurs synchronously on this actor.
        library.local.refresh()
        guard try migrationForkReview(batchID: batchID) == review else { throw CarryMigrationOwnershipFailure.sourceChanged }
        let evidence = try library.local.recoverMigrationSourceCopies(
            tripIDs: Set(records.filter { $0.kind == "trip" }.map(\.rootID)),
            libraryIDs: Set(records.filter { $0.kind == "libraryItem" }.map(\.rootID)), batchID: batchID, expectedSources: review.sources)
        guard evidence.map(\.source).sorted(by: { $0.rootID.uuidString < $1.rootID.uuidString }) == review.sources else { throw CarryMigrationOwnershipFailure.sourceChanged }
        let engine = try CarryAccountTripMigration(accountID: current.accountID, context: raw, cache: current.cache,
            backupRoot: rootDirectory.appendingPathComponent(current.accountID.uuidString.lowercased()).appendingPathComponent("migration-backups"))
        try engine.approveFork(batchID: batchID, evidence: evidence, validateEvidence: { try self.recaptureRecoveryEvidence(evidence) })
        try await resumeMigration(batchID: batchID)
    }
    private func recaptureRecoveryEvidence(_ evidence: [CarryMigrationRecoveryEvidence]) throws -> [CarryMigrationRecoveryEvidence] {
        let source = ModelContext(library.local.businessContext.container)
        let deleted = Set(evidence.filter { $0.source.entities.isEmpty }.map { $0.source.rootID })
        let tripIDs = Set(evidence.filter { $0.source.kind == "trip" }.flatMap { [$0.source.rootID, $0.copy.rootID] }).union(deleted)
        let itemIDs = Set(evidence.filter { $0.source.kind == "libraryItem" }.flatMap { [$0.source.rootID, $0.copy.rootID] }).union(deleted)
        let trips = try Self.selectedLocalTrips(tripIDs, in: source)
        let items = try Self.selectedLocalItems(itemIDs, in: source)
        return try evidence.map { expected in
            let currentSource: CarryMigrationSourceSnapshot, copy: CarryMigrationSourceSnapshot
            if expected.source.entities.isEmpty {
                guard expected.identityMap.isEmpty, trips[expected.source.rootID] == nil, items[expected.source.rootID] == nil else { throw CarryMigrationOwnershipFailure.sourceChanged }
                return CarryMigrationRecoveryEvidence(source: expected.source, copy: expected.copy, identityMap: [:])
            }
            if expected.source.kind == "trip" {
                guard let original = trips[expected.source.rootID], let recovered = trips[expected.copy.rootID] else { throw CarryMigrationOwnershipFailure.sourceChanged }
                currentSource = try CarryMigrationSourceSnapshot.capture(trip: original); copy = try CarryMigrationSourceSnapshot.capture(trip: recovered)
            } else {
                guard let original = items[expected.source.rootID], let recovered = items[expected.copy.rootID] else { throw CarryMigrationOwnershipFailure.sourceChanged }
                currentSource = try CarryMigrationSourceSnapshot.capture(item: original); copy = try CarryMigrationSourceSnapshot.capture(item: recovered)
            }
            return CarryMigrationRecoveryEvidence(source: currentSource, copy: copy, identityMap: expected.identityMap)
        }
    }

    func sourceForks() throws -> [CarryMigrationSourceDifference] {
        guard let current = runtime else { return [] }
        let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: ModelContext(current.container))
        var result: [CarryMigrationSourceDifference] = []
        let changedBatches = Set(try ModelContext(current.container).fetch(FetchDescriptor<CarryAccountMigrationBatch>()).filter { $0.phase == "sourceChanged" }.map(\.id))
        let source = ModelContext(library.local.businessContext.container)
        let records = try ownership.records().filter { $0.active || changedBatches.contains($0.batchID) }
        let adoptions = try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container)).records().filter { $0.phase == "activated" }
        let trips = try Self.selectedLocalTrips(Set(records.filter { $0.kind == "trip" }.map(\.rootID)).union(adoptions.filter { $0.kind == "trip" }.map(\.rootID)), in: source)
        let items = try Self.selectedLocalItems(Set(records.filter { $0.kind == "libraryItem" }.map(\.rootID)).union(adoptions.filter { $0.kind == "libraryItem" }.map(\.rootID)), in: source)
        for record in records {
            let snapshot: CarryMigrationSourceSnapshot
            if record.kind == "trip" {
                snapshot = try trips[record.rootID].map { try CarryMigrationSourceSnapshot.capture(trip: $0) }
                    ?? CarryMigrationSourceSnapshot(rootID: record.rootID, kind: "trip", entities: [])
            } else {
                snapshot = try items[record.rootID].map { try CarryMigrationSourceSnapshot.capture(item: $0) }
                    ?? CarryMigrationSourceSnapshot(rootID: record.rootID, kind: "libraryItem", entities: [])
            }
            result += try ownership.differences(rootID: record.rootID, current: snapshot)
        }
        for row in adoptions {
            let review = try JSONDecoder().decode(CarryLocalAdoptionReview.self, from: row.reviewData)
            let currentSource: CarryMigrationSourceSnapshot
            if row.kind == "trip" {
                currentSource = try trips[row.rootID].map { try .capture(trip: $0) } ?? .init(rootID: row.rootID, kind: row.kind, entities: [])
            } else {
                currentSource = try items[row.rootID].map { try .capture(item: $0) } ?? .init(rootID: row.rootID, kind: row.kind, entities: [])
            }
            result += CarryAccountMigrationOwnership.differences(baseline: review.source, current: currentSource)
        }
        return result
    }

    private func sourceFingerprints(tripIDs: Set<UUID>, libraryIDs: Set<UUID>) throws -> [UUID: String] {
        let source = ModelContext(library.local.businessContext.container)
        let trips = try Self.selectedLocalTrips(tripIDs, in: source)
        let items = try Self.selectedLocalItems(libraryIDs, in: source)
        var result: [UUID: String] = [:]
        for id in tripIDs {
            let snapshot = try trips[id].map { try CarryMigrationSourceSnapshot.capture(trip: $0) }
                ?? CarryMigrationSourceSnapshot(rootID: id, kind: "trip", entities: [])
            result[id] = try snapshot.fingerprint()
        }
        for id in libraryIDs {
            let snapshot = try items[id].map { try CarryMigrationSourceSnapshot.capture(item: $0) }
                ?? CarryMigrationSourceSnapshot(rootID: id, kind: "libraryItem", entities: [])
            result[id] = try snapshot.fingerprint()
        }
        return result
    }

    private static func selectedLocalTrips(_ ids: Set<UUID>, in context: ModelContext) throws -> [UUID: TripBundle] {
        var result: [UUID: TripBundle] = [:]
        let all = Array(ids)
        for offset in stride(from: 0, to: all.count, by: 256) {
            let scope = Array(all[offset..<min(offset + 256, all.count)])
            for value in try context.fetch(FetchDescriptor<TripBundle>(predicate: #Predicate { scope.contains($0.id) })) {
                guard result.updateValue(value, forKey: value.id) == nil else { throw CarryMigrationOwnershipFailure.invalidScope }
            }
        }
        return result
    }
    private static func selectedLocalItems(_ ids: Set<UUID>, in context: ModelContext) throws -> [UUID: MyItem] {
        var result: [UUID: MyItem] = [:]
        let all = Array(ids)
        for offset in stride(from: 0, to: all.count, by: 256) {
            let scope = Array(all[offset..<min(offset + 256, all.count)])
            for value in try context.fetch(FetchDescriptor<MyItem>(predicate: #Predicate { scope.contains($0.id) })) {
                guard result.updateValue(value, forKey: value.id) == nil else { throw CarryMigrationOwnershipFailure.invalidScope }
            }
        }
        return result
    }
    private static func sourceFileURLs(_ backup: CarryBackup) throws -> (attachments: [String: URL], backgrounds: [String: URL]) {
        var files: [String: URL] = [:], backgrounds: [String: URL] = [:]
        func attachments(_ values: [BackupAttachment]?) throws {
            for value in values ?? [] where !value.fileName.isEmpty {
                try safe(value.fileName)
                files[value.fileName] = AttachmentStore.fileURL(named: value.fileName)
            }
        }
        func safe(_ name: String) throws {
            guard name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name.utf8.count <= 255 else {
                throw CarryMigrationBackupFailure.invalidFile
            }
        }
        for trip in backup.trips {
            if let data = trip.backgroundsData, !data.isEmpty {
                for background in try JSONDecoder().decode([TripBackgroundEntry].self, from: data) {
                    if let name = background.localFileName { try safe(name); backgrounds[name] = BackgroundImageStore.fileURL(named: name) }
                }
            }
            for day in trip.itineraryDays ?? [] {
                for stop in day.stops { try attachments(stop.attachments) }
                for segment in day.segments ?? [] { try attachments(segment.attachments) }
            }
            for stay in trip.lodgingStays ?? [] { try attachments(stay.attachments) }
        }
        return (files, backgrounds)
    }
    @concurrent nonisolated private static func migrationPacket(_ backup: CarryBackup, accountID: UUID, batchID: UUID,
                                                              tripIDs: Set<UUID>, includeLibrary: Bool) async throws -> CarryGraphMigrationPacket {
        try Task.checkCancellation()
        return try CarryGraphMigrationCodec.prepare(backup, accountID: accountID, migrationID: batchID,
            tripIDs: tripIDs, includeLibrary: includeLibrary)
    }
    private static func migrationMessage(_ error: Error) -> String {
        switch error {
        case CarryMigrationBackupFailure.photoPermission, CarryMigrationBackupFailure.photoUnavailable,
             CarryAccountTripMigrationFailure.originalPhotosRequired: return "account.migration.error.photos"
        case CarryMigrationBackupFailure.batchTooLarge: return "account.migration.error.large"
        case CarryMigrationOwnershipFailure.sourceChanged, CarryAccountTripMigrationFailure.sourceChanged: return "account.migration.error.changed"
        case is CancellationError: return "account.migration.error.cancelled"
        default: return "account.migration.error.retry"
        }
    }
}

@MainActor
private final class CarryMigrationGuardedTransport: CarryGraphStreamingTransporting {
    private let base: any CarryGraphTransporting
    private let valid: () -> Bool
    init(base: any CarryGraphTransporting, valid: @escaping () -> Bool) { self.base = base; self.valid = valid }
    private func check() throws { try Task.checkCancellation(); guard valid() else { throw CancellationError() } }
    func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
        try check(); let receipt = try await base.apply(command); try check(); return receipt
    }
    func pull(cursor: Int) async throws -> CarryGraphPage {
        try check(); let page = try await base.pull(cursor: cursor); try check(); return page
    }
    func applyStreaming(_ command: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
                        receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws {
        try check()
        if let streaming = base as? any CarryGraphStreamingTransporting {
            try await streaming.applyStreaming(command, progress: progress) { summary, page, bytes in
                try self.check(); try await receive(summary, page, bytes); try self.check()
            }
        } else {
            let result = try await apply(command), offset = progress?.nextOffset ?? 0
            guard offset <= result.changes.count else { throw CarryAccountTripMigrationFailure.invalidReceipt }
            let summary = CarryGraphReceiptSummary(status: result.status, requestID: result.requestID, cursor: result.cursor, changeCount: result.changes.count)
            let page = CarryGraphReceiptPage(requestID: result.requestID, cursor: result.cursor,
                changes: Array(result.changes.dropFirst(offset)), nextOffset: result.changes.count, hasMore: false, changeCount: result.changes.count)
            try await receive(summary, page, 0); try check()
        }
    }
}


extension CarryAccountWorkspaceController {
    var localAccountCollisions: [CarryWorkspaceLibrary.Collision] { library.localAccountCollisions }
    private func verifiedAdoptionRoots(_ current: Runtime) async throws -> Set<UUID> {
        var roots = try Self.routingRootIDs(current.store)
        let engine = try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container))
        for row in try engine.records() where row.phase == "activated" {
            do {
                let previous = try JSONDecoder().decode(CarryLocalAdoptionReview.self, from: row.reviewData)
                let live = try engine.review(source: previous.source)
                _ = try await engine.verify(live, cache: current.cache)
            } catch {
                if error is CancellationError { throw error }
                if !(try CarryAccountLocalAdoption.verifiedDeletedRoots(in: engine.context)).contains(row.rootID) { roots.remove(row.rootID) }
                CarryLogger.shared.log(.loadFailed, context: "local_adoption_native_not_ready")
            }
        }
        return roots
    }
    func reviewLocalAccountCollision(rootID: UUID, kind: String) async throws -> CarryLocalAdoptionReview {
        guard let current = runtime, !library.local.businessContext.hasChanges, !current.store.businessContext.hasChanges,
              library.localAccountCollisions.contains(where: { $0.rootID == rootID && $0.kind == kind }) else { throw CarryMigrationOwnershipFailure.invalidScope }
        let source = try CarryAccountLocalAdoption.capture(rootID: rootID, kind: kind, context: ModelContext(library.local.businessContext.container))
        let engine = try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container))
        let review = try engine.review(source: source)
        _ = try await engine.verify(review, cache: current.cache)
        guard runtime?.accountID == current.accountID,
              try CarryAccountLocalAdoption.capture(rootID: rootID, kind: kind, context: ModelContext(library.local.businessContext.container)) == source else { throw CarryMigrationOwnershipFailure.sourceChanged }
        return review
    }
    func isLocalAdoptionStaged(rootID: UUID) -> Bool {
        guard let current = runtime, let engine = try? CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container)),
              let rows = try? engine.records() else { return false }
        return rows.contains { $0.rootID == rootID && $0.phase == "staged" }
    }
    func cancelLocalAdoption(rootID: UUID) throws {
        guard !migrationBusy, migrationTask == nil, let current = runtime else { throw CarryAccountWorkspaceControllerFailure.busy }
        let engine = try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container))
        guard let row = try engine.records().first(where: { $0.rootID == rootID }), row.phase == "staged" else { throw CarryMigrationOwnershipFailure.invalidState }
        let id = row.id
        try engine.cancel(rootID: rootID)
        let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: engine.context)
        try library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: engine.records(), materializedRootIDs: try Self.routingRootIDs(current.store))
        library.local.migrationWriteGuard.release(batchID: id)
        migrationFailureKey = nil; migrationFinished = false
    }
    func adoptLocalAccountCollision(_ review: CarryLocalAdoptionReview) async throws {
        guard migrationTask == nil, !migrationBusy, !isSuspended, let current = runtime,
              current.accountID == review.accountID else { throw CarryAccountWorkspaceControllerFailure.busy }
        migrationBusy = true; migrationFinished = false; migrationFailureKey = nil
        let task = Task { @MainActor in try await self.performLocalAdoption(review, current: current) }
        migrationTask = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            migrationTask = nil; migrationBusy = false; migrationFinished = true
        } catch {
            migrationTask = nil; migrationBusy = false; migrationFailureKey = Self.migrationMessage(error); throw error
        }
    }
    private func performLocalAdoption(_ review: CarryLocalAdoptionReview, current: Runtime) async throws {
        let sourceStore = library.local
        guard !sourceStore.businessContext.hasChanges, !current.store.businessContext.hasChanges else { throw CarryMigrationOwnershipFailure.sourceChanged }
        await pauseSynchronization()
        defer {
            if runtime?.accountID == current.accountID, !Task.isCancelled {
                isSuspended = false; current.workspace.enableSynchronization(); requestSynchronization()
            }
        }
        let engine = try CarryAccountLocalAdoption(accountID: current.accountID, context: ModelContext(current.container))
        _ = try await engine.verify(review, cache: current.cache)
        let sourceContext = ModelContext(sourceStore.businessContext.container)
        guard try CarryAccountLocalAdoption.capture(rootID: review.source.rootID, kind: review.source.kind, context: sourceContext) == review.source else { throw CarryMigrationOwnershipFailure.sourceChanged }
        sourceStore.migrationWriteGuard.protect(batchID: review.id, snapshots: [review.source])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryMigrationPreparation-" + UUID().uuidString, isDirectory: true)
        var staged = false
        do {
            try await Self.prepareDirectory(directory)
            let trips = review.source.kind == "trip" ? try sourceContext.fetch(FetchDescriptor<TripBundle>()).filter { $0.id == review.source.rootID } : []
            let items = review.source.kind == "libraryItem" ? try sourceContext.fetch(FetchDescriptor<MyItem>()).filter { $0.id == review.source.rootID } : []
            let backup = DataBackupManager.shared.migrationSnapshot(trips: trips, myItems: items), files = try Self.sourceFileURLs(backup)
            let photos = backup.trips.flatMap { $0.itineraryDays ?? [] }.flatMap(\.stops).flatMap { $0.photos ?? [] }
            let originals = try await CarryMigrationPhotoCollector().collect(photos, directory: directory)
            let prepared = try await CarryMigrationBackupPreparation.prepare(backup, attachments: files.attachments, backgrounds: files.backgrounds, originalPhotos: originals, directory: directory)
            let archiveRoot = rootDirectory.appendingPathComponent(current.accountID.uuidString.lowercased()).appendingPathComponent("local-adoption-backups")
            let archive = try await CarryLocalAdoptionArchive.create(prepared, root: archiveRoot, review: review)
            let archiveProof = try await archive.verify(in: archiveRoot, review: review)
            let verified = try await engine.verify(review, cache: current.cache)
            try Task.checkCancellation()
            guard runtime?.accountID == current.accountID, !sourceStore.businessContext.hasChanges,
                  try CarryAccountLocalAdoption.capture(rootID: review.source.rootID, kind: review.source.kind, context: ModelContext(sourceStore.businessContext.container)) == review.source else { throw CarryMigrationOwnershipFailure.sourceChanged }
            try engine.stage(review, archive: archiveProof); staged = true
            let ownership = try CarryAccountMigrationOwnership(accountID: current.accountID, context: engine.context)
            try library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: engine.records(), materializedRootIDs: try Self.routingRootIDs(current.store))
            sourceStore.migrationWriteGuard.release(batchID: review.id)
            sourceStore.refresh()
            let copies = try sourceStore.recoverMigrationSourceCopies(tripIDs: review.source.kind == "trip" ? [review.source.rootID] : [],
                libraryIDs: review.source.kind == "libraryItem" ? [review.source.rootID] : [], batchID: review.id, expectedSources: [review.source])
            guard let evidence = copies.first, copies.count == 1 else { throw CarryMigrationOwnershipFailure.invalidState }
            try engine.activate(verified, evidence: evidence, validateSource: {
                try CarryAccountLocalAdoption.capture(rootID: review.source.rootID, kind: review.source.kind, context: ModelContext(sourceStore.businessContext.container))
            }, validateCopy: {
                try CarryAccountLocalAdoption.capture(rootID: evidence.copy.rootID, kind: evidence.copy.kind, context: ModelContext(sourceStore.businessContext.container))
            })
            try library.updateOwnership(accountID: current.accountID, records: ownership.records(), adoptions: engine.records(), materializedRootIDs: try Self.routingRootIDs(current.store))
            sourceStore.migrationWriteGuard.release(batchID: review.id)
            try await CarryMigrationBackupPreparation.discard(directory)
        } catch {
            if !staged { sourceStore.migrationWriteGuard.release(batchID: review.id) }
            do { try await CarryMigrationBackupPreparation.discard(directory) } catch { CarryLogger.shared.log(.loadFailed, context: "local_adoption_cleanup") }
            throw error
        }
    }
}
