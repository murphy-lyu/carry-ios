import SwiftUI

struct AutomationConnectionView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var router: NavigationRouter
    @EnvironmentObject private var connection: CarryAutomationConnection
    @State private var code = ""
    @State private var selectedTrips: Set<UUID> = []
    @State private var shareLibrary = false
    @State private var preview: CarryAutomationConnection.PairPreview?
    @State private var checkingCode = false
    @State private var pairingError = false
    @State private var showDisconnect = false

    var body: some View {
        Form {
            Section {
                Text("automation.explanation")
                    .foregroundStyle(.secondary)
            }
            if let credential = connection.credentials {
                Section {
                    LabeledContent("automation.client", value: credential.clientName)
                    Text(credential.revocationPending ? "automation.revoking" : "automation.connected")
                    if credential.scope.contains("library:read") { Text("automation.library.enabled").foregroundStyle(.secondary) }
                    if let synced = connection.lastSynced {
                        LabeledContent("automation.last_sync") { Text(synced, style: .relative) }
                    }
                    Button("automation.sync") { Task { await connection.synchronize() } }
                        .disabled(connection.isBusy || credential.revocationPending)
                    Button("automation.disconnect", role: .destructive) { showDisconnect = true }
                }
                Section("automation.shared_trips") {
                    ForEach(store.trips.filter { credential.tripIds.contains($0.id) }) { trip in
                        Text(verbatim: trip.name.isEmpty ? trip.destinationCity : trip.name)
                    }
                }
                if !connection.operations.isEmpty {
                    Section("automation.requests") {
                        ForEach(connection.operations) { operation in
                            VStack(alignment: .leading, spacing: 6) {
                                if let name = operation.targetName, !name.isEmpty { Text(verbatim: name) }
                                else { Text("automation.request") }
                                HStack {
                                    Text(LocalizedStringKey(operation.statusKey))
                                    Spacer()
                                    Text(Date(timeIntervalSince1970: operation.createdAt / 1000), style: .time)
                                }
                                .font(.footnote).foregroundStyle(.secondary)
                                if operation.status == "queued" {
                                    Button("automation.cancel_request", role: .destructive) { Task { await connection.cancelOperation(operation.requestId) } }
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    TextField("automation.code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: code) { _, _ in preview = nil; pairingError = false; selectedTrips = []; shareLibrary = false }
                    if let preview {
                        LabeledContent("automation.client", value: preview.clientName)
                        if let host = preview.redirectHost { LabeledContent("automation.client_host", value: host) }
                        Text(preview.scope.contains("trips:write") ? "automation.scope.write" : "automation.scope.read")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("automation.check_code") { Task { await checkCode() } }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).count != 16 || checkingCode)
                    }
                } header: { Text("automation.pairing") }
                  footer: { Text("automation.pairing.help") }

                if preview != nil {
                    if preview?.scope.contains("library:") == true {
                        Section {
                            Toggle("automation.library", isOn: $shareLibrary)
                        } footer: { Text("automation.library.help") }
                    }
                    if preview?.scope.contains("trips:") == true {
                    Section {
                        ForEach(store.trips) { trip in
                            Toggle(isOn: Binding(get: { selectedTrips.contains(trip.id) }, set: { enabled in
                                if enabled { selectedTrips.insert(trip.id) } else { selectedTrips.remove(trip.id) }
                            })) { Text(verbatim: trip.name.isEmpty ? trip.destinationCity : trip.name) }
                        }
                    } header: { Text("automation.shared_trips") }
                      footer: { Text("automation.consent") }
                    }
                    Section {
                        Button("automation.approve") {
                            guard let preview else { return }
                            Task { await connection.connect(code: normalizedCode, tripIds: selectedTrips, shareLibrary: shareLibrary, expectedScope: preview.scope, store: store) }
                        }
                        .fontWeight(.semibold)
                        .disabled(connection.isBusy)
                    }
                }
            }
            if let error = connection.errorKey {
                Section { Text(LocalizedStringKey(error)).foregroundStyle(.secondary) }
            }
            if pairingError {
                Section { Text("automation.error.connection").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("automation.title")
        .confirmationDialog("automation.disconnect.confirm", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("automation.disconnect", role: .destructive) { Task { await connection.disconnect() } }
        } message: { Text("automation.disconnect.detail") }
    }

    private var normalizedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private func checkCode() async {
        checkingCode = true; pairingError = false
        defer { checkingCode = false }
        do { preview = try await connection.preview(code: normalizedCode) }
        catch { pairingError = true }
    }
}
