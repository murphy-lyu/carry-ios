import SwiftUI

struct CarryAccountConflictReviewView: View {
    @ObservedObject var workspace: CarryAccountWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var review: CarryGraphConflictReview?
    @State private var choices: [String: Bool] = [:]
    @State private var useLocalParent = true
    @State private var failed = false
    @State private var changed = false
    @State private var entities: [UUID: CarryGraphEntity] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let review {
                    Section {
                        Text(verbatim: CarryAccountConflictPresentation.title(review.local)).font(.headline)
                        Text("account.conflict.detail").foregroundStyle(.secondary)
                        if changed { Text("account.conflict.updated").foregroundStyle(.secondary) }
                    }
                    switch review.kind {
                    case .field:
                        ForEach(review.fields, id: \.self) { field in
                            Section(LocalizedStringKey(CarryAccountConflictPresentation.fieldKey(field))) {
                                valueRow("account.conflict.mine", value: review.local.fields[field], field: field)
                                valueRow("account.conflict.other", value: review.current.fields[field], field: field)
                                Picker("account.conflict.keep", selection: Binding(get: { choices[field] ?? true }, set: { choices[field] = $0 })) {
                                    Text("account.conflict.mine").tag(true)
                                    Text("account.conflict.other").tag(false)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        Section { Button("Save") { resolve(review) } }
                    case .move:
                        Section("account.conflict.field.location") {
                            LabeledContent("account.conflict.mine", value: parentTitle(review.local.parentID))
                            LabeledContent("account.conflict.other", value: parentTitle(review.current.parentID))
                            Picker("account.conflict.keep", selection: $useLocalParent) {
                                Text("account.conflict.mine").tag(true)
                                Text("account.conflict.other").tag(false)
                            }.pickerStyle(.segmented)
                        }
                        Section { Button("Save") { resolve(review) } }
                    case .subtree:
                        Section {
                            Text(review.action == "delete" ? "account.conflict.delete_changed" : "account.conflict.restore_changed")
                        }
                        Section("account.conflict.impact") {
                            ForEach(affectedEntities(review), id: \.id) { entity in
                                Text(verbatim: CarryAccountConflictPresentation.title(entity))
                            }
                        }
                        Section {
                            Button(review.action == "delete" ? "account.conflict.delete_reviewed" : "account.conflict.restore_reviewed",
                                   role: review.action == "delete" ? .destructive : nil) { resolve(review, keepTree: true) }
                            Button("account.conflict.cancel_action") { resolve(review, keepTree: false) }
                        }
                    }
                } else {
                    Text("account.conflict.none").foregroundStyle(.secondary)
                }
                if failed { Text("account.error.storage").foregroundStyle(.secondary) }
            }
            .navigationTitle("account.conflict.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("account.conflict.refresh") { load(markChanged: true) } }
            }
            .task { load(markChanged: false) }
            .onChange(of: workspace.state) { _, _ in load(markChanged: true) }
        }
        .tint(CarryAccent.color)
    }

    private func valueRow(_ key: LocalizedStringKey, value: CarryGraphValue?, field: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: CarryAccountConflictPresentation.value(value, field: field))
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
    private func parentTitle(_ id: UUID?) -> String {
        guard let id, let entity = entities[id] else { return NSLocalizedString("account.conflict.empty", comment: "") }
        return CarryAccountConflictPresentation.title(entity)
    }
    private func affectedEntities(_ review: CarryGraphConflictReview) -> [CarryGraphEntity] {
        if review.action == "restore" {
            return review.impact.filter { $0.deletedAt != nil && $0.deletionBatch == review.current.deletionBatch }
        }
        return review.impact.filter { $0.deletedAt == nil }
    }
    private func load(markChanged: Bool) {
        do {
            let latest = try workspace.replica.conflictReview()
            if latest != review {
                changed = markChanged && review != nil
                review = latest
                choices = [:]; useLocalParent = true
            }
            entities = Dictionary(uniqueKeysWithValues: try workspace.replica.localEntities().map { ($0.id, $0) })
            failed = false
        } catch { failed = true }
    }
    private func resolve(_ shown: CarryGraphConflictReview, keepTree: Bool? = nil) {
        do {
            var fields: [String: CarryGraphConflictChoice] = [:]
            for field in shown.fields { fields[field] = choices[field] ?? true ? .local : .remote }
            try workspace.replica.resolveReviewedConflict(shown, fields: fields,
                parent: shown.kind == .move ? (useLocalParent ? .local : .remote) : nil, tree: keepTree)
            Task {
                do { _ = try await workspace.synchronize() }
                catch { failed = true }
                load(markChanged: false)
                if review == nil && !failed { dismiss() }
            }
        } catch {
            // A changed draft or server revision refreshes the preview. No
            // stale button can silently rebind it to values the user never saw.
            load(markChanged: true); failed = true
        }
    }
}
