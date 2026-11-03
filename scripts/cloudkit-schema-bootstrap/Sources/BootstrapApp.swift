import SwiftUI
import SwiftData
import CoreData
import CloudKit

private let containerIdentifier = "iCloud.app.nevestudio.carry"

private struct BootstrapResult: Encodable {
    let completedAt = Date()
    let mode: String
    let stage: String
    let success: Bool
    let modelTypes: [String]
    let errorDomainsAndCodes: [String]
}

private func readNativeModel() throws -> NSManagedObjectModel {
    guard let url = Bundle.main.url(forResource: "CarrySchema.generated", withExtension: "mom") else {
        throw CocoaError(.fileNoSuchFile)
    }
    let data = try Data(contentsOf: url)
    guard let model = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSManagedObjectModel.self, from: data) else {
        throw CocoaError(.coderReadCorrupt)
    }
    let names = model.entities.compactMap(\.name)
    guard names.count == 11, names.contains("TripBundle"), names.contains("AutomationExecutionRecord") else {
        throw CocoaError(.coderReadCorrupt)
    }
    return model
}

private func initializeSchema(upload: Bool) throws -> [String] {
    try autoreleasepool {
        let model = try readNativeModel()
        let names = model.entities.compactMap(\.name).sorted()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("bootstrap.store"))
        description.shouldAddStoreAsynchronously = false
        let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        options.databaseScope = .private
        description.cloudKitContainerOptions = options
        let container = NSPersistentCloudKitContainer(name: "CarrySchemaBootstrap", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        // The completion runs synchronously because shouldAddStoreAsynchronously is false.
        var loadResult: Result<Void, Error> = .failure(CocoaError(.persistentStoreOpen))
        container.loadPersistentStores { _, error in
            loadResult = error.map { .failure($0) } ?? .success(())
        }
        func cleanup() throws {
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
            try FileManager.default.removeItem(at: directory)
        }
        do {
            try loadResult.get()
            try container.initializeCloudKitSchema(options: upload ? [] : .dryRun)
        } catch {
            let originalError = error
            do { try cleanup() }
            catch {
                throw NSError(domain: "CarrySchemaBootstrap.Cleanup", code: (error as NSError).code,
                              userInfo: [NSUnderlyingErrorKey: originalError])
            }
            throw originalError
        }
        try cleanup()
        return names
    }
}

@main
struct BootstrapApp: App {
    @State private var status = "Checking CloudKit development access…"
    @State private var started = false

    var body: some Scene {
        WindowGroup {
            Text(status).padding().task { await run() }
        }
    }

    @MainActor
    private func run() async {
        guard !started else { return }
        started = true
        let inspect = ProcessInfo.processInfo.arguments.contains("--inspect-model")
        let upload = ProcessInfo.processInfo.arguments.contains("--initialize-development-schema")
        let mode = inspect ? "inspect-model" : upload ? "initialize-development" : "dry-run"
        var stage = "model-archive"
        let result: BootstrapResult
        do {
            var names = try readNativeModel().entities.compactMap(\.name).sorted()
            if !inspect {
                stage = "account-status"
                let account = try await CKContainer(identifier: containerIdentifier).accountStatus()
                guard account == .available else { throw CKError(.notAuthenticated) }
                stage = "native-schema"
                names = try await Task.detached { try initializeSchema(upload: upload) }.value
            }
            result = BootstrapResult(mode: mode, stage: stage, success: true, modelTypes: names, errorDomainsAndCodes: [])
            status = inspect ? "Native model archive verified. No CloudKit access." : upload ? "Development schema initialized." : "Development schema dry-run passed."
        } catch {
            var codes: [String] = []
            var next: NSError? = error as NSError
            while let current = next, codes.count < 8 {
                codes.append("\(current.domain):\(current.code)")
                next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            result = BootstrapResult(mode: mode, stage: stage, success: false, modelTypes: [], errorDomainsAndCodes: codes)
            status = "Check failed at \(stage): \(codes.joined(separator: ", "))"
        }
        do {
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("bootstrap-result.json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(result).write(to: destination, options: .atomic)
            print("Bootstrap result: mode=\(mode), stage=\(result.stage), success=\(result.success)")
        } catch {
            status = "Could not save bootstrap result."
        }
    }
}
