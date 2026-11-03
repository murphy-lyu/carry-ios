import SwiftUI

struct CarryAccountSyncStatusView: View {
    @ObservedObject var workspace: CarryAccountWorkspace
    let retry: () -> Void
    @State private var conflicts: [CarryGraphDeletionConflict] = []
    @State private var review: CarryGraphDeletionConflict?
    @State private var failed = false
    @State private var showRejectedReview = false

    private var statusKey: String {
        switch workspace.state {
        case .paused: return "account.sync.paused"
        case .pending: return "account.sync.pending"
        case .synchronizing: return "account.sync.running"
        case .synchronized: return "account.sync.saved"
        case .conflict: return "account.sync.conflict"
        case .failed: return "account.error.service"
        }
    }
    var body: some View {
        Text(LocalizedStringKey(statusKey)).foregroundStyle(.secondary)
            .task { do { try loadConflicts() } catch { failed = true } }
            .onChange(of: workspace.state) { _, _ in do { try loadConflicts() } catch { failed = true } }
            .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
                if let review { reviewSheet(review) }
            }
        Button("account.sync.retry") {
            retry()
        }
        .disabled(workspace.state == .synchronizing || workspace.state == .paused)
        if workspace.state == .conflict {
            Button("account.conflict.title") { showRejectedReview = true }
                .sheet(isPresented: $showRejectedReview) { CarryAccountConflictReviewView(workspace: workspace) }
        }
        ForEach(conflicts, id: \.local.id) { conflict in
            Button { review = conflict } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title(conflict.local))
                    Text("account.sync.deleted_draft").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if failed { Text("account.error.storage").foregroundStyle(.secondary) }
    }
    private func loadConflicts() throws { conflicts = try workspace.replica.deletionConflicts(); failed = false }
    private func title(_ entity: CarryGraphEntity) -> String {
        for key in ["name", "title", "displayName"] {
            if case .string(let name) = entity.fields[key], !name.isEmpty { return name }
        }
        return NSLocalizedString("account.sync.deleted_draft", comment: "")
    }
    private func resolve(_ conflict: CarryGraphDeletionConflict, restore: Bool) {
        do {
            try workspace.replica.resolveDeletion(conflict, restore: restore)
            try loadConflicts(); review = nil
            // The reviewed resolution creates durable pending work. Resume the
            // normal controller pipeline without requiring another Sync tap.
            retry()
        } catch { failed = true; review = nil }
    }
    private func reviewSheet(_ conflict: CarryGraphDeletionConflict) -> some View {
        NavigationStack {
            List {
                Section {
                    Text("account.sync.deletion_review.detail")
                    Text(verbatim: title(conflict.local)).font(.headline)
                }
                Section("account.sync.deletion_review.impact") {
                    ForEach(conflict.restoreImpact, id: \.id) { entity in Text(verbatim: title(entity)) }
                }
                Section {
                    Button("account.sync.restore_draft") { resolve(conflict, restore: true) }
                    Button("account.sync.discard_draft", role: .destructive) { resolve(conflict, restore: false) }
                }
            }
            .navigationTitle("account.sync.deletion_review.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { review = nil } } }
        }
        .tint(CarryAccent.color)
    }
}
