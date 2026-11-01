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
                                         onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().nativeEditorScope(presentations) }
    }
    func nativeEditorSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, presentations: CarryNativeEditorPresentations,
                                                             onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in content(item).nativeEditorScope(presentations) }
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
