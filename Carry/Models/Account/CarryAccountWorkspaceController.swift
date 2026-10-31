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
            try library.attach(store)
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
