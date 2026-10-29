import XCTest
import SwiftData
import CoreData
@testable import Carry

/// Produces the exact native model for the isolated schema bootstrap app.
/// No CloudKit store, account, or existing user database is opened here.
@MainActor
final class CloudKitModelExportTests: XCTestCase {
    func testExportNativeModelForIsolatedSchemaBootstrap() throws {
        let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models))
        let expected = Set(SchemaV1.models.map { String(describing: $0) })
        XCTAssertEqual(Set(model.entities.compactMap(\.name)), expected)
        let data = try NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: NSManagedObjectModel.self, from: data))
        XCTAssertEqual(Set(decoded.entities.compactMap(\.name)), expected)
        XCTAssertEqual(decoded.entityVersionHashesByName, model.entityVersionHashesByName)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CarrySchema.generated.mom")
        try data.write(to: destination, options: .atomic)
        print("Schema export: \(expected.count) native model types, \(data.count) bytes; no user records or CloudKit upload.")
        for entity in decoded.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            print("Schema entity: \(entity.name ?? "unnamed") / \(entity.managedObjectClassName ?? "unspecified")")
        }
    }
}
