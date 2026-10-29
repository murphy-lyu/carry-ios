import XCTest
import SwiftData
@testable import Carry

@MainActor
final class ReorderLookupTests: XCTestCase {
    func testPartialOrdersKeepOmittedObjectsAndApplyTheLastRepeatedID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryReorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("reorder.store"), cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let items = (0..<3).map { PackingItem(name: "Item \($0)", isAlert: false, sortOrder: $0 == 2 ? 9 : $0) }
        let sections = (0..<3).map { PackingSection(title: "Section \($0)",
            items: $0 == 0 ? items : [PackingItem(name: "Other \($0)", isAlert: false)],
            sortOrder: $0 == 2 ? 9 : $0) }
        let stops = (0..<3).map { ItineraryStop(name: "Stop \($0)", sortOrder: $0 == 2 ? 9 : $0) }
        let day = ItineraryDay(stops: stops)
        let trip = TripBundle(name: "Synthetic reorder", destinationCity: "", days: 0, dateRange: "", isDateless: true)
        trip.sections = sections; trip.itineraryDays = [day]
        context.insert(trip); try context.save()
        let store = TripStore(context: context)
        for _ in 0..<1000 where !store.automationReady { await Task.yield() }
        XCTAssertTrue(store.automationReady)
        let missingID = UUID()
        store.reorderItems(tripId: trip.id, sectionId: sections[0].id,
            newOrder: [items[1].id, missingID, items[1].id, items[0].id])
        store.reorderSections(tripId: trip.id,
            newOrder: [sections[1].id, missingID, sections[1].id, sections[0].id])
        store.reorderItineraryStops(tripId: trip.id, dayId: day.id,
            newOrder: [stops[1].id, missingID, stops[1].id, stops[0].id])

        // Verify committed storage, including unchanged omitted records. Repeated
        // input IDs retain their original last-assignment semantics; unknown IDs
        // still occupy an index without creating or removing any native record.
        let reopened = ModelContext(container)
        let persistedItems = try reopened.fetch(FetchDescriptor<PackingItem>())
        let persistedSections = try reopened.fetch(FetchDescriptor<PackingSection>())
        let persistedStops = try reopened.fetch(FetchDescriptor<ItineraryStop>())
        XCTAssertEqual(persistedItems.count, 5)
        XCTAssertEqual(persistedSections.count, 3)
        XCTAssertEqual(persistedStops.count, 3)
        for (index, expected) in [3, 2, 9].enumerated() {
            XCTAssertEqual(persistedItems.first { $0.id == items[index].id }?.sortOrder, expected)
            XCTAssertEqual(persistedSections.first { $0.id == sections[index].id }?.sortOrder, expected)
            XCTAssertEqual(persistedStops.first { $0.id == stops[index].id }?.sortOrder, expected)
        }
    }
}
