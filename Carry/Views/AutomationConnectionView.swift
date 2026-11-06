import SwiftUI

struct CarryAccountAIConnectionView: View {
    let configuration: CarryAccountAIConfiguration
    @EnvironmentObject private var connection: CarryAutomationConnection
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "link")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(CarryAccent.color)
                        .accessibilityHidden(true)
                    Text("account.ai.hero")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("account.ai.intro")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    step(1, "account.ai.setup", "account.ai.setup.detail")
                    Text(verbatim: configuration.mcpURL.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = configuration.mcpURL.absoluteString
                        copied = true
                        AccessibilityNotification.Announcement(String(localized: "account.ai.copy.next")).post()
                    } label: {
                        Label(
                            LocalizedStringKey(copied ? "account.ai.copied" : "account.ai.copy"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Color(uiColor: .label), in: RoundedRectangle(cornerRadius: CarryRadius.card))
                    }
                    .buttonStyle(.plain)
                    if copied {
                        Text("account.ai.copy.next")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    step(2, "account.ai.authorize", "account.ai.authorize.detail")
                    Divider()
                    step(3, "account.ai.try", "account.ai.try.detail")
                }
                .padding(18)
                .carryCard()

                Link(destination: configuration.connectionsURL) {
                    Label("account.ai.manage", systemImage: "arrow.up.right.square")
                        .frame(minHeight: 44)
                }
                if connection.credentials != nil {
                    NavigationLink { AutomationConnectionView() } label: { Text("automation.title") }
                        .frame(minHeight: 44)
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("account.ai.title")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.carryCanvas)
        .tint(CarryAccent.color)
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number, format: .number)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(CarryAccent.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

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
                    Text(credential.revocationPending ? "automation.revoking" : credential.pendingPair != nil ? "automation.status.queued" : "automation.connected")
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
                            Task { await connection.connect(code: normalizedCode, tripIds: selectedTrips, shareLibrary: shareLibrary, expectedScope: preview.scope, clientName: preview.clientName, store: store) }
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
