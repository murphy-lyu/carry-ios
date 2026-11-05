import XCTest
import SwiftUI
import SwiftData
@testable import Carry

@MainActor
final class NativeEditorPresentationLifecycleTests: XCTestCase {
    @MainActor private struct Fixture {
        let store: TripStore
        let tripID: UUID
        let info: TripInfo
        init() throws {
            let container = try ModelContainer(for: Schema(versionedSchema: SchemaV1.self),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            store = TripStore(context: ModelContext(container), scope: .account(didChange: {}))
            store.nativeEditing = CarryNativeEditingCoordinator()
            let start = Calendar.current.startOfDay(for: Date())
            info = TripInfo(name: "Synthetic trip", destinationCity: "Seoul", departureDate: start,
                returnDate: Calendar.current.date(byAdding: .day, value: 2, to: start)!,
                resolvedDestinations: [.init(name: "Seoul", countryCode: "KR", latitude: 37.56, longitude: 126.97)])
            tripID = try XCTUnwrap(store.createTrip(from: info))
        }
    }

    func testCreatedTripCanBeRenamedRepeatedlyAndAnotherEditorCanOpenAfterEachDismissal() async throws {
        let f = try Fixture(), control = EditorLifecycleControl()
        let window = try host(control: control, store: f.store)
        defer { control.parent.closeAll(); window.isHidden = true }
        try await waitUntil { control.parent.ownerIdentity != nil }
        for round in 1...2 {
            XCTAssertTrue(control.parent.begin(key: "edit", store: f.store))
            control.showEditor = true
            try await waitUntil { control.editorAppearances == round }
            XCTAssertEqual(control.editor.groupIdentity, control.parent.groupIdentity)
            var renamed = f.info; renamed.name = "Renamed trip \(round)"
            XCTAssertTrue(control.editor.save(store: f.store) { f.store.updateTripInfo(tripId: f.tripID, info: renamed) })
            control.showEditor = false
            try await waitUntil { control.dismissals == round }
            XCTAssertFalse(f.store.nativeEditing!.hasActiveSessions)
            XCTAssertEqual(f.store.bundle(for: f.tripID)?.name, renamed.name)
            XCTAssertTrue(control.page.save(store: f.store) { f.store.syncItineraryDays(tripId: f.tripID) })
            let next = try XCTUnwrap(f.store.beginNativeEditing(groupID: UUID()))
            next.close()
        }
        XCTAssertFalse(control.page.saveFailed)
        XCTAssertFalse(control.editor.saveFailed)
    }

    func testItemSheetsReleaseOnCancelAndCanBeReopened() async throws {
        let f = try Fixture(), control = EditorLifecycleControl()
        let window = try host(control: control, store: f.store)
        defer { control.parent.closeAll(); window.isHidden = true }
        try await waitUntil { control.parent.ownerIdentity != nil }
        for round in 1...2 {
            XCTAssertTrue(control.parent.begin(key: "item", store: f.store))
            control.item = .init()
            try await waitUntil { control.itemAppearances == round }
            control.item = nil
            try await waitUntil { control.dismissals == round }
            XCTAssertFalse(f.store.nativeEditing!.hasActiveSessions)
        }
        XCTAssertEqual(f.store.bundle(for: f.tripID)?.name, f.info.name)
    }

    func testLifetimeCreatedBeforeAcquisitionCapturesAtAppearanceAndDismissesOnlyOnce() throws {
        let f = try Fixture(), presenter = CarryNativeEditorPresentations()
        let lifetime = CarryNativeEditorSheetLifetime()
        XCTAssertTrue(presenter.begin(key: "edit", store: f.store))
        var dismissals = 0
        lifetime.appeared(presentations: presenter, sessionKey: "edit", after: { dismissals += 1 })
        lifetime.appeared(presentations: presenter, sessionKey: "edit", after: { XCTFail("Reappearance must not replace the captured dismissal") })
        lifetime.dismissed(); lifetime.dismissed()
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(f.store.nativeEditing!.hasActiveSessions)
        XCTAssertTrue(presenter.begin(key: "edit", store: f.store))
        lifetime.appeared(presentations: presenter, sessionKey: "edit", after: { dismissals += 1 })
        lifetime.dismissed()
        XCTAssertEqual(dismissals, 2)
        XCTAssertFalse(f.store.nativeEditing!.hasActiveSessions)
    }

    func testStaleSheetLifetimeCannotReleaseReplacementSession() throws {
        let f = try Fixture(), presenter = CarryNativeEditorPresentations()
        let oldSheet = CarryNativeEditorSheetLifetime()
        XCTAssertTrue(presenter.begin(key: "edit", store: f.store))
        oldSheet.appeared(presentations: presenter, sessionKey: "edit", after: { XCTFail("Stale dismissal must not run follow-up work") })
        presenter.end(key: "edit")
        XCTAssertTrue(presenter.begin(key: "edit", store: f.store))
        oldSheet.dismissed()
        XCTAssertTrue(f.store.nativeEditing!.hasActiveSessions)
        XCTAssertNil(f.store.beginNativeEditing(groupID: UUID()))
        presenter.closeAll()
        XCTAssertFalse(f.store.nativeEditing!.hasActiveSessions)
    }

    private func host(control: EditorLifecycleControl, store: TripStore) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: EditorLifecycleHost(control: control).environmentObject(store))
        window.makeKeyAndVisible()
        return window
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Editor presentation lifecycle did not finish", file: file, line: line)
        throw NSError(domain: "EditorLifecycleTimeout", code: 1)
    }
}

@MainActor
private final class EditorLifecycleControl: ObservableObject {
    struct Item: Identifiable { let id = UUID() }
    let parent = CarryNativeEditorPresentations()
    let page = CarryNativeEditorPresentations()
    let editor = CarryNativeEditorPresentations()
    @Published var showEditor = false
    @Published var item: Item?
    var editorAppearances = 0
    var itemAppearances = 0
    var dismissals = 0
}

private struct EditorLifecycleHost: View {
    @ObservedObject var control: EditorLifecycleControl
    var body: some View {
        Text("Synthetic itinerary").nativeEditorErrors(control.page)
            .nativeEditorErrors(control.parent)
            .nativeEditorSheet(isPresented: $control.showEditor, presentations: control.parent,
                sessionKey: "edit", onDismiss: { control.dismissals += 1 }) {
                    Text("Synthetic metadata editor").nativeEditorErrors(control.editor)
                        .onAppear { control.editorAppearances += 1 }
                }
            .nativeEditorSheet(item: $control.item, presentations: control.parent,
                sessionKey: "item", onDismiss: { control.dismissals += 1 }) { _ in
                    Text("Synthetic item editor").nativeEditorErrors(control.editor)
                        .onAppear { control.itemAppearances += 1 }
                }
    }
}
