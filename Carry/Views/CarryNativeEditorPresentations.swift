import SwiftUI
import Combine

private struct CarryNativeEditorOwnerKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct CarryNativeEditorGroupKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var nativeEditorOwner: UUID? {
        get { self[CarryNativeEditorOwnerKey.self] }
        set { self[CarryNativeEditorOwnerKey.self] = newValue }
    }
    var nativeEditorGroup: UUID? {
        get { self[CarryNativeEditorGroupKey.self] }
        set { self[CarryNativeEditorGroupKey.self] = newValue }
    }
}

@MainActor
final class CarryNativeEditorPresentations: ObservableObject {
    private struct Session {
        let id = UUID()
        let lease: CarryNativeEditorLease?
        let readOnly: Bool
    }
    private var sessions: [String: Session] = [:]
    @Published private(set) var ownerIdentity: UUID?
    private(set) var groupIdentity = UUID()
    @Published var saveFailed = false
    @Published var saveWasBusy = false

    /// A draft never changes account/workspace owner after its first binding.
    func bind(owner: UUID, group: UUID? = nil) {
        guard ownerIdentity == nil else { return }
        ownerIdentity = owner
        if let group { groupIdentity = group }
    }

    @discardableResult
    func begin(key: String, store: TripStore, readOnly: Bool = false, owner: UUID? = nil, group: UUID? = nil) -> Bool {
        bind(owner: owner ?? store.nativeEditorIdentity, group: group)
        guard ownerIdentity == store.nativeEditorIdentity, store.nativeEditing?.isInvalidated != true else { fail(busy: false); return false }
        if let existing = sessions[key], !existing.readOnly || readOnly { return true }
        let lease = store.beginNativeEditing(groupID: groupIdentity, readOnly: readOnly)
        guard store.nativeEditing == nil || lease != nil else { fail(busy: true); return false }
        let previous = sessions.updateValue(Session(lease: lease, readOnly: readOnly), forKey: key)
        previous?.lease?.close()
        return true
    }

    func end(key: String) { sessions.removeValue(forKey: key)?.lease?.close() }
    func dismissal(key: String, after: @escaping () -> Void = {}) -> () -> Void {
        let generation = sessions[key]?.id
        return { [weak self] in
            guard let self, let generation, self.sessions[key]?.id == generation else { return }
            self.end(key: key)
            after()
        }
    }
    func closeAll() {
        let closing = Array(sessions.values)
        sessions.removeAll()
        closing.forEach { $0.lease?.close() }
    }
    func fail(busy: Bool) { saveWasBusy = busy; saveFailed = true }

    @discardableResult
    func save(store: TripStore, _ operation: () -> Void) -> Bool {
        guard ownerIdentity == store.nativeEditorIdentity else { fail(busy: false); return false }
        let saved = store.performEditorSave(groupID: groupIdentity, operation)
        if !saved { fail(busy: store.lastEditorSaveWasBusy) }
        return saved
    }
}

extension View {
    func nativeEditorScope(_ presentations: CarryNativeEditorPresentations) -> some View {
        environment(\.nativeEditorOwner, presentations.ownerIdentity)
            .environment(\.nativeEditorGroup, presentations.groupIdentity)
    }
    func nativeEditorErrors(_ presentations: CarryNativeEditorPresentations, retry: (() -> Void)? = nil) -> some View {
        modifier(CarryNativeEditorErrorModifier(presentations: presentations, retry: retry))
    }
    func nativeEditorSheet<Content: View>(isPresented: Binding<Bool>, presentations: CarryNativeEditorPresentations,
                                         sessionKey: String? = nil, onDismiss: (() -> Void)? = nil,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(CarryNativeEditorBoolSheet(isPresented: isPresented, presentations: presentations,
            sessionKey: sessionKey, onDismiss: onDismiss, sheetContent: content))
    }
    func nativeEditorSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, presentations: CarryNativeEditorPresentations,
                                                             sessionKey: String? = nil, onDismiss: (() -> Void)? = nil,
                                                             @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        modifier(CarryNativeEditorItemSheet(item: item, presentations: presentations,
            sessionKey: sessionKey, onDismiss: onDismiss, sheetContent: content))
    }
}

/// SwiftUI can retain the first onDismiss closure while several sheets share a presenter.
/// Capture the lease only when its content actually appears, then use stable reference storage
/// for the callback. Keep the generation guard: an old dismissal must not close a new draft.
@MainActor
final class CarryNativeEditorSheetLifetime: ObservableObject {
    private var dismissal: (() -> Void)?

    func appeared(presentations: CarryNativeEditorPresentations, sessionKey: String?, after: (() -> Void)?) {
        guard dismissal == nil else { return }
        if let sessionKey {
            dismissal = presentations.dismissal(key: sessionKey, after: { after?() })
        } else {
            dismissal = { after?() }
        }
    }

    func dismissed() {
        let completed = dismissal
        dismissal = nil
        completed?()
    }
}

private struct CarryNativeEditorBoolSheet<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let presentations: CarryNativeEditorPresentations
    let sessionKey: String?
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent
    @StateObject private var lifetime = CarryNativeEditorSheetLifetime()

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: { lifetime.dismissed() }) {
            sheetContent().nativeEditorScope(presentations)
                .onAppear { lifetime.appeared(presentations: presentations, sessionKey: sessionKey, after: onDismiss) }
        }
    }
}

private struct CarryNativeEditorItemSheet<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let presentations: CarryNativeEditorPresentations
    let sessionKey: String?
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent
    @StateObject private var lifetime = CarryNativeEditorSheetLifetime()

    func body(content: Content) -> some View {
        content.sheet(item: $item, onDismiss: { lifetime.dismissed() }) { item in
            sheetContent(item).nativeEditorScope(presentations)
                .onAppear { lifetime.appeared(presentations: presentations, sessionKey: sessionKey, after: onDismiss) }
        }
    }
}

private struct CarryNativeEditorErrorModifier: ViewModifier {
    @EnvironmentObject private var store: TripStore
    @Environment(\.nativeEditorOwner) private var inheritedOwner
    @Environment(\.nativeEditorGroup) private var inheritedGroup
    @ObservedObject var presentations: CarryNativeEditorPresentations
    var retry: (() -> Void)?
    func body(content: Content) -> some View {
        content
            .environment(\.nativeEditorOwner, inheritedOwner ?? presentations.ownerIdentity ?? store.nativeEditorIdentity)
            .environment(\.nativeEditorGroup, inheritedGroup ?? presentations.groupIdentity)
            .onAppear { presentations.bind(owner: inheritedOwner ?? store.nativeEditorIdentity, group: inheritedGroup) }
            .alert("editor.save_failed.title", isPresented: $presentations.saveFailed) {
                if let retry { Button("Save", action: retry) }
                Button("common.done", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(presentations.saveWasBusy ? "editor.busy.message" : "editor.save_failed.message"))
            }
    }
}
