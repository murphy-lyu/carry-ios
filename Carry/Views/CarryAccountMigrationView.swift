import SwiftUI

/// Migration is an explicit content selection. Opening the view performs no
/// upload and leaves every checkbox off, including the personal item library.
struct CarryAccountMigrationView: View {
    @EnvironmentObject private var controller: CarryAccountWorkspaceController
    @EnvironmentObject private var sourceStore: TripStore
    @State private var selection: Set<UUID> = []
    @State private var includeLibrary = false
    @State private var showDetails = false
    @State private var showConfirmation = false
    @State private var batches: [CarryAccountMigrationBatch] = []
    @State private var forks: [CarryMigrationSourceDifference] = []
    @State private var failed = false
    @State private var showForks = false
    @State private var selectedForkBatch: UUID?
    @State private var forkReview: CarryMigrationForkReview?
    @State private var adoptionReview: CarryLocalAdoptionReview?

    var body: some View {
        List {
            Section {
                Text("account.migration.explanation").font(.subheadline).foregroundStyle(.secondary)
                DisclosureGroup("account.migration.details", isExpanded: $showDetails) {
                    Text("account.migration.backup_detail").font(.footnote).foregroundStyle(.secondary)
                    Text("account.migration.limit").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !controller.localAccountCollisions.isEmpty {
                Section("account.adoption.title") {
                    Text("account.adoption.summary").foregroundStyle(.secondary)
                    ForEach(controller.localAccountCollisions) { collision in
                        Button {
                            run { adoptionReview = try await controller.reviewLocalAccountCollision(rootID: collision.rootID, kind: collision.kind) }
                        } label: { Label(collision.title, systemImage: "doc.on.doc") }
                        .disabled(controller.migrationBusy)
                    }
                }
            }
            Section("account.migration.select") {
                ForEach(controller.migrationCandidates, id: \.id) { trip in
                    Button { if selection.contains(trip.id) { selection.remove(trip.id) } else { selection.insert(trip.id) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: trip.name).foregroundStyle(.primary).lineLimit(2)
                                if sourceStore.migrationWriteGuard.isProtected(trip.id) {
                                    Text("account.migration.source_readonly").font(.caption).foregroundStyle(.secondary)
                                } else if !trip.destinationCity.isEmpty && trip.destinationCity != trip.name {
                                    Text(verbatim: trip.destinationCity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: selection.contains(trip.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(trip.id) ? CarryAccent.color : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.migrationBusy || sourceStore.migrationWriteGuard.isProtected(trip.id))
                    .accessibilityLabel(Text(verbatim: trip.name))
                    .accessibilityAddTraits(selection.contains(trip.id) ? .isSelected : [])
                }
                if controller.migrationCandidates.isEmpty { Text("account.migration.empty").foregroundStyle(.secondary) }
                if controller.localLibraryCount > 0 {
                    Toggle("account.migration.include_library", isOn: $includeLibrary).disabled(controller.migrationBusy)
                }
            }
            if controller.migrationBusy || controller.migrationFinished || controller.migrationFailureKey != nil || failed {
              Section {
                if controller.migrationBusy {
                    HStack { ProgressView(); Text("account.migration.running") }
                }
                if controller.migrationFinished { Text("account.migration.complete").foregroundStyle(.secondary) }
                if let key = controller.migrationFailureKey { Text(LocalizedStringKey(key)).foregroundStyle(.secondary) }
                if failed { Text("account.migration.error.retry").foregroundStyle(.secondary) }
              }
            }
            if !batches.isEmpty {
                Section("account.migration.previous") {
                    ForEach(batches, id: \.id) { batch in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(batch.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.subheadline)
                            Text(LocalizedStringKey("account.migration.phase." + (batch.phase == "activated" && !controller.isMigrationMaterialized(batchID: batch.id) ? "awaitingDevice" : batch.phase))).font(.footnote).foregroundStyle(.secondary)
                            if batch.phase != "cancelled" && (batch.phase != "activated" || !controller.isMigrationMaterialized(batchID: batch.id)) {
                                Button("account.migration.resume") { run { try await controller.resumeMigration(batchID: batch.id) } }
                                if !batch.publicationStarted {
                                    Button("account.migration.cancel", role: .cancel) { run { try await controller.cancelPreparedMigration(batchID: batch.id) } }
                                }
                                if batch.phase == "sourceChanged" && batch.publicationStarted {
                                    Button("account.migration.review_fork") {
                                        do { forkReview = try controller.migrationForkReview(batchID: batch.id); selectedForkBatch = batch.id; showForks = true }
                                        catch { failed = true }
                                    }
                                }
                            }
                        }
                        .disabled(controller.migrationBusy)
                    }
                }
            }
            if !forks.isEmpty {
                Section {
                    Button("account.migration.review_fork") { selectedForkBatch = nil; forkReview = nil; showForks = true }
                }
            }
        }
        .navigationTitle("account.migration.title")
        .navigationBarTitleDisplayMode(.inline)
        .tint(CarryAccent.color)
        .safeAreaInset(edge: .bottom) {
            Button { showConfirmation = true } label: {
                HStack {
                    Text("account.migration.start").fontWeight(.semibold)
                    if !selection.isEmpty {
                        Spacer(minLength: 12)
                        Text(selection.count, format: .number).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(controller.migrationBusy || (selection.isEmpty && !includeLibrary))
            .padding(.horizontal, 20).padding(.bottom, 12)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .bottomBarScrim(Color.carryCanvas)
        }
        .task { reload() }
        .onChange(of: controller.migrationBusy) { _, busy in if !busy { reload() } }
        .alert("account.migration.confirm", isPresented: $showConfirmation) {
            Button("account.migration.start") { run { try await controller.migrate(tripIDs: selection, includeLibrary: includeLibrary) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("account.migration.confirm_detail") }
        .sheet(isPresented: $showForks) { forkReviewContent }
        .sheet(item: $adoptionReview) { review in
            NavigationStack {
                List {
                    Section { Text("account.adoption.detail").foregroundStyle(.secondary) }
                    ForEach(CarryAccountMigrationOwnership.differences(baseline: review.account, current: review.source)) { difference in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: difference.title)
                            Text(LocalizedStringKey("account.migration.change." + difference.change)).font(.caption).foregroundStyle(.secondary)
                            ForEach(difference.fields, id: \.self) { field in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey(field == "files" || field == "parent" ? "account.migration.field." + field : CarryAccountConflictPresentation.fieldKey(field))).font(.caption).foregroundStyle(.secondary)
                                    LabeledContent("account.adoption.account", value: CarryAccountConflictPresentation.value(difference.before[field], field: field))
                                    LabeledContent("account.adoption.local", value: CarryAccountConflictPresentation.value(difference.after[field], field: field))
                                }.font(.footnote)
                            }
                        }
                    }
                    Section {
                        Button("account.adoption.confirm") {
                            run { try await controller.adoptLocalAccountCollision(review); adoptionReview = nil }
                        }.disabled(controller.migrationBusy)
                    } footer: { Text("account.adoption.confirm_detail") }
                    if controller.isLocalAdoptionStaged(rootID: review.source.rootID) {
                        Section {
                            Button("account.adoption.cancel", role: .cancel) {
                                run { try controller.cancelLocalAdoption(rootID: review.source.rootID); adoptionReview = nil }
                            }.disabled(controller.migrationBusy)
                        } footer: { Text("account.adoption.cancel_detail") }
                    }
                    if failed || controller.migrationFailureKey != nil { Text("account.migration.error.retry").foregroundStyle(.secondary) }
                    if controller.migrationBusy { ProgressView() }
                }
                .navigationTitle("account.adoption.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { adoptionReview = nil }.disabled(controller.migrationBusy) } }
            }.tint(CarryAccent.color)
        }
    }

    private var forkReviewContent: some View {
        NavigationStack {
            List {
                Section { Text("account.migration.fork_detail").foregroundStyle(.secondary) }
                ForEach(forkReview?.differences ?? forks, id: \.id) { difference in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: difference.title)
                        Text(LocalizedStringKey("account.migration.change." + difference.change)).font(.caption).foregroundStyle(.secondary)
                        ForEach(difference.fields, id: \.self) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(field == "files" || field == "parent" ? "account.migration.field." + field : CarryAccountConflictPresentation.fieldKey(field))).font(.caption).foregroundStyle(.secondary)
                                LabeledContent("account.migration.before", value: CarryAccountConflictPresentation.value(difference.before[field], field: field))
                                LabeledContent("account.migration.after", value: CarryAccountConflictPresentation.value(difference.after[field], field: field))
                            }
                            .font(.footnote)
                        }
                    }
                }
                if (forkReview?.differences ?? forks).isEmpty { Text("account.migration.fork_unchanged").foregroundStyle(.secondary) }
                if selectedForkBatch != nil, let forkReview {
                    Section {
                        Button("account.migration.keep_both") {
                            run { try await controller.keepBothMigrationVersions(forkReview); showForks = false }
                        }
                        .disabled(controller.migrationBusy)
                    } footer: { Text("account.migration.keep_both_detail") }
                }
            }
            .navigationTitle("account.migration.review_fork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showForks = false } } }
        }
        .tint(CarryAccent.color)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        failed = false
        Task {
            do { try await operation(); selection = []; includeLibrary = false }
            catch { failed = true }
            reload()
        }
    }
    private func reload() {
        do { batches = try controller.migrationBatches(); forks = try controller.sourceForks() }
        catch { failed = true }
    }
}
