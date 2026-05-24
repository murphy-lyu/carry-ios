//
//  SettingsView.swift
//  Carry
//

import SwiftUI
import UIKit
import UserNotifications
import UniformTypeIdentifiers

struct SettingsView: View {

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showAppearancePicker = false
    @State private var showRoadmapSheet = false
    @State private var showCoffeeSheet = false
    @State private var didApplyLaunchSheetReset = false
    @State private var showRestoreConfirmation = false
    @State private var showImporter = false
    @State private var showImportConfirmation = false
    @State private var pendingImportData: Data?
    @State private var restoreToastMessage: String?
    @State private var backupDate: Date? = DataBackupManager.shared.latestBackupDate()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: TripStore
    @AppStorage("appearance_mode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    private var currentAppearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var currentLanguageDisplay: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let locale = Locale.current
        return locale.localizedString(forIdentifier: preferred)?.capitalized
            ?? preferred
    }

    private var roadmapTitle: String {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if lang.hasPrefix("zh") {
            return lang.contains("hant") ? "路線圖" : "路线图"
        }
        return "Roadmap"
    }

    private var notificationStatusText: LocalizedStringKey {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return "settings.notifications.on"
        case .denied:
            return "settings.notifications.off"
        case .notDetermined:
            return "settings.notifications.notSet"
        @unknown default:
            return "settings.notifications.notSet"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await NotificationManager.authorizationStatus()
    }

    private func openFeedbackMail() {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        let device = UIDevice.current.model
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"

        let to = "murphy.lyu@icloud.com"
        let subject = "Carry Feedback"
        let body = """


        ---
        Carry \(version) (\(build))
        \(device) · \(system)
        """

        var components = URLComponents(string: "mailto:\(to)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]

        guard let url = components?.url else { return }
        UIApplication.shared.open(url)
    }

    private var backupDateDisplay: String {
        guard let date = backupDate else {
            return NSLocalizedString("settings.data.restore.no_backup", comment: "")
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            restoreToastMessage = message
        }
        Task {
            try? await Task.sleep(for: .milliseconds(2000))
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    restoreToastMessage = nil
                }
            }
        }
    }

    private func restoreSuccessMessage(count: Int) -> String {
        String(
            format: NSLocalizedString(
                count == 1 ? "settings.data.restore.success.one" : "settings.data.restore.success",
                comment: ""
            ),
            count
        )
    }

    private func shareBackupFile() {
        guard let sourceURL = DataBackupManager.shared.backupFileURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            showToast(NSLocalizedString("settings.data.restore.error.not_found", comment: ""))
            return
        }
        // Copy to a temp file with a timestamped name so the share sheet
        // shows something like "carry_backup_2026-05-24_15-41.json".
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let exportName = "carry_backup_\(fmt.string(from: Date())).json"
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent(exportName)
        do {
            if FileManager.default.fileExists(atPath: exportURL.path) {
                try FileManager.default.removeItem(at: exportURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: exportURL)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        let activityVC = UIActivityViewController(activityItems: [exportURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            activityVC.popoverPresentationController?.sourceView = rootVC.view
            rootVC.present(activityVC, animated: true)
        }
    }

    private var settingsGroupFill: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.72)
            : Color(UIColor.secondarySystemGroupedBackground)
    }

    private var settingsGroupStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.primary.opacity(0.05)
    }

    private var settingsGroupShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.16)
            : Color.black.opacity(0.03)
    }

    private var settingsTitleColor: Color {
        colorScheme == .dark ? Color.secondary.opacity(0.9) : Color.secondary
    }

    private var settingsValueColor: Color {
        colorScheme == .dark ? Color.secondary.opacity(0.92) : Color.secondary
    }

    private var settingsChevronColor: Color {
        colorScheme == .dark ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.45)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("settings.title")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    settingsGroup(title: "settings.section.general") {
                        Button {
                            showAppearancePicker = true
                        } label: {
                            HStack(spacing: 14) {
                                Text("Appearance")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(currentAppearance.titleKey)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 18)
                            .frame(height: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .confirmationDialog("Appearance", isPresented: $showAppearancePicker, titleVisibility: .visible) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Button(mode.titleKey) {
                                    appearanceModeRaw = mode.rawValue
                                }
                            }
                        }
                        settingsRow(title: "settings.about.language", valueText: currentLanguageDisplay) {
                            openSystemSettings()
                        }
                        settingsRow(title: "settings.notifications", valueKey: notificationStatusText) {
                            openSystemSettings()
                        }
                    }

                    settingsGroup(title: "settings.group.support") {
                        settingsRow(title: "settings.section.support", valueText: "☕️") {
                            showCoffeeSheet = true
                        }
                        settingsRow(title: "settings.feedback") {
                            openFeedbackMail()
                        }
                    }

                    settingsGroup(title: "settings.section.about") {
                        settingsNavigationRow(title: "settings.about.entry") {
                            AboutView()
                        }

                        settingsRow(titleText: roadmapTitle) {
                            showRoadmapSheet = true
                        }

                        settingsNavigationRow(title: "settings.legal.terms") {
                            TermsView()
                        }

                        settingsNavigationRow(title: "settings.legal.privacy") {
                            PrivacyView()
                        }
                    }

                    settingsGroup(title: "settings.data.title") {
                        // Export — share the JSON file via AirDrop, Files, Mail, etc.
                        settingsRow(
                            title: "settings.data.export",
                            valueText: DataBackupManager.shared.hasBackup() ? nil : NSLocalizedString("settings.data.restore.no_backup", comment: "")
                        ) {
                            shareBackupFile()
                        }
                        // Import — pick a previously exported JSON and restore from it
                        settingsRow(title: "settings.data.import") {
                            showImporter = true
                        }
                        // Restore — use the automatic on-device backup
                        settingsRow(title: "settings.data.restore", valueText: backupDateDisplay) {
                            showRestoreConfirmation = true
                        }
                    }
                    .padding(.bottom, 10)
                    // Restore (device backup) confirmation
                    .confirmationDialog(
                        Text("settings.data.restore.confirm.title"),
                        isPresented: $showRestoreConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) {
                            do {
                                let result = try store.restoreFromBackup()
                                backupDate = DataBackupManager.shared.latestBackupDate()
                                showToast(restoreSuccessMessage(count: result.trips))
                            } catch {
                                showToast(error.localizedDescription)
                            }
                        } label: {
                            Text("settings.data.restore.action")
                        }
                    } message: {
                        Text("settings.data.restore.confirm.message")
                    }
                    // Import (file) confirmation
                    .confirmationDialog(
                        Text("settings.data.import.confirm.title"),
                        isPresented: $showImportConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) {
                            guard let data = pendingImportData else { return }
                            do {
                                let result = try store.restoreFromData(data)
                                backupDate = DataBackupManager.shared.latestBackupDate()
                                showToast(restoreSuccessMessage(count: result.trips))
                            } catch {
                                showToast(error.localizedDescription)
                            }
                            pendingImportData = nil
                        } label: {
                            Text("settings.data.import.action")
                        }
                    } message: {
                        Text("settings.data.import.confirm.message")
                    }

#if DEBUG
                    settingsGroup(title: "settings.developer.title") {
                        settingsNavigationRow(title: "settings.developer.entry") {
                            DeveloperModeView()
                        }
                    }
#endif
                }
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .overlay(alignment: .bottom) {
            if let msg = restoreToastMessage {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.88))
                    .clipShape(Capsule())
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: restoreToastMessage != nil)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Read within the security scope before it expires
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    showToast(NSLocalizedString("settings.data.restore.error.corrupt", comment: ""))
                    return
                }
                pendingImportData = data
                showImportConfirmation = true
            case .failure(let error):
                showToast(error.localizedDescription)
            }
        }
        .navigationBarHidden(true)
        .task { await refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !didApplyLaunchSheetReset {
                showRoadmapSheet = false
                didApplyLaunchSheetReset = true
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            Task { await refreshNotificationStatus() }
        }
        .sheet(isPresented: $showRoadmapSheet) {
            NavigationStack {
                RoadmapView {
                    showRoadmapSheet = false
                }
            }
        }
        .sheet(isPresented: $showCoffeeSheet) {
            CoffeeSheetView()
        }
    }

    private func settingsGroup<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(settingsTitleColor)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(settingsGroupFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(settingsGroupStroke, lineWidth: 1)
                    )
            )
            .shadow(color: settingsGroupShadow, radius: colorScheme == .dark ? 10 : 12, x: 0, y: colorScheme == .dark ? 3 : 4)
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func settingsRow(title: LocalizedStringKey, valueText: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if let valueText {
                    Text(valueText)
                        .font(.body)
                        .foregroundStyle(settingsValueColor)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settingsChevronColor)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsRow(title: LocalizedStringKey, valueKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(valueKey)
                    .font(.body)
                    .foregroundStyle(settingsValueColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settingsChevronColor)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsRow(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settingsChevronColor)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsRow(titleText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(titleText)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settingsChevronColor)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsNavigationRow<Destination: View>(
        title: LocalizedStringKey,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(settingsChevronColor)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView()
        .environmentObject(TripStore())
}

#if DEBUG
private struct DeveloperModeView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var coffeeStore = CoffeeStore()
    @State private var toastMessage: String?

    var body: some View {
        List {
            Section("settings.developer.reset_group") {
                actionRow(title: "settings.debug.reset_support_tone") {
                    coffeeStore.debugResetSupportCount()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showToast("settings.debug.reset_support_tone.success")
                }
                actionRow(title: "settings.debug.reset_recommendation_entry") {
                    store.debugResetSceneCardDismissState()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showToast("settings.debug.reset_recommendation_entry.success")
                }
            }

            Section("settings.developer.notifications_group") {
                actionRow(title: "settings.developer.test_notifications") {
                    NotificationManager.scheduleTestNotifications()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showToast("settings.developer.test_notifications.success")
                }
            }

            Section("settings.developer.mock_group") {
                Toggle(isOn: Binding(
                    get: { store.isHomeEmptyStateMockEnabled },
                    set: { newValue in
                        store.setHomeEmptyStateMockEnabled(newValue)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showToast(newValue ? String(localized: "settings.mock.home_empty_state.enabled") : String(localized: "settings.mock.home_empty_state.disabled"))
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mock.home_empty_state")
                        Text("settings.mock.home_empty_state.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(colorScheme == .dark ? Color.accentColor.opacity(0.86) : Color.accentColor)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("settings.developer.entry")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(LocalizedStringKey(toastMessage))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.88))
                    .clipShape(Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage != nil)
    }

    private func actionRow(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}
#endif
