import XCTest
import SwiftData
@testable import Carry

@MainActor
final class WorkspaceLibraryTests: XCTestCase {
    private func store() throws -> TripStore {
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        return TripStore(context: ModelContext(container), scope: .account(didChange: {}))
    }
    func testReadsAggregateButMutationsUseOriginalOwningContext() throws {
        let local = try store(), account = try store()
        let a = TripBundle(name: "Local", destinationCity: "", days: 1, dateRange: "")
        let b = TripBundle(name: "Account", destinationCity: "", days: 1, dateRange: "")
        local.addTrip(a); account.addTrip(b)
        let library = CarryWorkspaceLibrary(local: local)
        try library.attach(account)
        XCTAssertEqual(Set(library.visibleTrips.map(\.id)), Set([a.id, b.id]))
        XCTAssertTrue(library.owningStore(for: a.id) === local)
        XCTAssertTrue(library.owningStore(for: b.id) === account)
        XCTAssertTrue(library.creationStore === account)
        library.owningStore(for: b.id)?.removeTrip(withId: b.id)
        XCTAssertEqual(local.trips.map(\.id), [a.id]); XCTAssertTrue(account.trips.isEmpty)
        library.detach()
        XCTAssertTrue(library.creationStore === local)
        XCTAssertNil(library.owningStore(for: b.id))
    }
    func testDuplicateOwnershipFailsClosed() throws {
        let local = try store(), account = try store()
        let a = TripBundle(name: "Local", destinationCity: "", days: 1, dateRange: "")
        let b = TripBundle(name: "Account", destinationCity: "", days: 1, dateRange: ""); b.id = a.id
        local.addTrip(a); account.addTrip(b)
        let library = CarryWorkspaceLibrary(local: local)
        XCTAssertThrowsError(try library.attach(account))
        XCTAssertNil(library.account)
        XCTAssertTrue(library.owningStore(for: a.id) === local)
    }
}
