//
//  SettingsView.swift
//  Carry
//

import SwiftUI
import UIKit
import UserNotifications
import UniformTypeIdentifiers
import EventKit

struct SettingsView: View {

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showAppearancePicker = false
    @State private var showRoadmapSheet = false
    @State private var showCoffeeSheet = false
    @State private var didApplyLaunchSheetReset = false
    @State private var showImporter = false
    @State private var showImportConfirmation = false
    @State private var pendingImportData: Data?
    @State private var restoreToastMessage: String?
    // 备份信息缓存：onAppear 时读取一次，避免每次 body 求值触发磁盘 I/O
    @State private var cachedBackupDate: Date? = nil
    // 当前 App Icon 显示名：onAppear / 前台激活时刷新（图标切换后同步）
    @State private var currentIconName: String = currentAppIconDisplayName()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: TripStore
    @AppStorage("appearance_mode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage("calendar_sync_enabled") private var calendarSyncEnabled = false
    @AppStorage("liveActivityPackingEnabled") private var liveActivityPackingEnabled = false

    private var currentAppearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    // 语言标识符在 App 生命周期内不会改变，用 let 缓存，避免每次 body 求值都调用系统 API
    private let currentLanguageDisplay: String = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return Locale.current.localizedString(forIdentifier: preferred)?.capitalized ?? preferred
    }()

    private let roadmapTitle: String = {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if lang.hasPrefix("zh") {
            return lang.contains("hant") ? "路線圖" : "路线图"
        }
        return "Roadmap"
    }()

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

    // 静态缓存 DateFormatter，避免重复创建（DateFormatter 创建开销大）
    private static let autoSaveDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    /// 从磁盘刷新备份日期缓存（onAppear / 前台激活时调用一次）
    private func refreshBackupCache() {
        cachedBackupDate = DataBackupManager.shared.latestBackupDate()
    }

    /// Value text shown on the Auto-Save navigation row — uses cached date, no disk I/O.
    private var autoSaveValueText: String {
        guard let date = cachedBackupDate else {
            return NSLocalizedString("settings.data.restore.no_backup", comment: "")
        }
        return Self.autoSaveDateFormatter.string(from: date)
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
        CarryLogger.shared.log(.backupExported)
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
                LazyVStack(alignment: .leading, spacing: 0) {

                        Section {
                            settingsCard {
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
                                settingsNavigationRow(
                                    title: "settings.appicon.entry",
                                    valueText: currentIconName
                                ) {
                                    AppIconView()
                                        .toolbar(.hidden, for: .tabBar)
                                }
                                settingsNavigationRow(
                                    title: "settings.calendar.entry",
                                    valueText: calendarSyncEnabled ? NSLocalizedString("settings.calendar.status.on", comment: "") : NSLocalizedString("settings.calendar.status.off", comment: "")
                                ) {
                                    CalendarSettingsView()
                                        .toolbar(.hidden, for: .tabBar)
                                }
#if !targetEnvironment(macCatalyst)
                                settingsNavigationRow(title: "settings.liveactivity.packing") {
                                    LiveActivitySettingsView()
                                        .toolbar(.hidden, for: .tabBar)
                                }
#endif
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 18)
                        } header: {
                            sectionHeader("settings.section.general")
                        }

                        Section {
                            settingsCard {
                                settingsRow(
                                    title: "settings.data.export",
                                    valueText: cachedBackupDate != nil ? nil : NSLocalizedString("settings.data.restore.no_backup", comment: "")
                                ) {
                                    shareBackupFile()
                                }
                                settingsRow(title: "settings.data.import") {
                                    showImporter = true
                                }
                                settingsNavigationRow(
                                    title: "settings.data.local_backup"
                                ) {
                                    DataRecoveryView()
                                        .toolbar(.hidden, for: .tabBar)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 18)
                            .alert(
                                Text("settings.data.import.confirm.title"),
                                isPresented: $showImportConfirmation
                            ) {
                                Button(role: .destructive) {
                                    guard let data = pendingImportData else { return }
                                    do {
                                        let result = try store.restoreFromData(data)
                                        showToast(restoreSuccessMessage(count: result.trips))
                                        CarryLogger.shared.log(.backupRestored,
                                            context: "trips=\(result.trips) myItems=\(result.myItems)")
                                    } catch {
                                        showToast(error.localizedDescription)
                                        CarryLogger.shared.log(.backupRestoreFailed,
                                            context: "error=\(error.localizedDescription)")
                                    }
                                    pendingImportData = nil
                                } label: {
                                    Text("settings.data.import.action")
                                }
                                Button(role: .cancel) {
                                    pendingImportData = nil
                                } label: {
                                    Text("Cancel")
                                }
                            } message: {
                                Text("settings.data.import.confirm.message")
                            }
                        } header: {
                            sectionHeader("settings.data.title")
                        }

                        Section {
                            settingsCard {
                                settingsNavigationRow(title: "settings.about.entry") {
                                    AboutView()
                                        .toolbar(.hidden, for: .tabBar)
                                }
                                settingsRow(title: "settings.section.support", valueText: "☕️") {
                                    showCoffeeSheet = true
                                }
                                settingsRow(titleText: roadmapTitle) {
                                    showRoadmapSheet = true
                                }
                                settingsRow(title: "settings.feedback") {
                                    openFeedbackMail()
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 18)
                        } header: {
                            sectionHeader("settings.section.about")
                        }

#if DEBUG
                        Section {
                            settingsCard {
                                settingsNavigationRow(title: "settings.developer.entry") {
                                    DeveloperModeView()
                                        .toolbar(.hidden, for: .tabBar)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 18)
                        } header: {
                            sectionHeader("settings.developer.title")
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
                    CarryLogger.shared.log(.backupRestoreFailed, context: "reason=file_unreadable")
                    return
                }
                pendingImportData = data
                showImportConfirmation = true
            case .failure(let error):
                showToast(error.localizedDescription)
                CarryLogger.shared.log(.backupRestoreFailed,
                    context: "reason=picker_failed error=\(error.localizedDescription)")
            }
        }
        .navigationTitle(Text("settings.title"))
        .navigationBarTitleDisplayMode(.large)
        .task { await refreshNotificationStatus() }
        .onAppear {
            refreshBackupCache()
            currentIconName = currentAppIconDisplayName()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshBackupCache()
                currentIconName = currentAppIconDisplayName()
                if !didApplyLaunchSheetReset {
                    showRoadmapSheet = false
                    didApplyLaunchSheetReset = true
                }
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

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(settingsTitleColor)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Card-only container (no title). Used with Section headers for sticky behaviour.
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
    }

    private func settingsGroup<Content: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(settingsTitleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(settingsTitleColor.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

    @ViewBuilder
    private func settingsNavigationRow<Destination: View>(
        title: LocalizedStringKey,
        valueText: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(valueText)
                    .font(.body)
                    .foregroundStyle(settingsValueColor)
                    .lineLimit(1)
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

// MARK: - DataRecoveryView

private struct DataRecoveryView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var showConfirmation = false
    @State private var toastMessage: String?

    // 磁盘读取缓存：onAppear 时加载一次，避免每次 body 求值触发 I/O
    @State private var backupDate: Date? = nil
    @State private var backupTripCount: Int? = nil

    // 静态缓存 DateFormatter，避免重复创建
    private static let recoveryDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .short
        return fmt
    }()

    private var formattedDate: String {
        guard let date = backupDate else { return "" }
        return Self.recoveryDateFormatter.string(from: date)
    }

    private func loadBackupInfo() {
        backupDate = DataBackupManager.shared.latestBackupDate()
        backupTripCount = DataBackupManager.shared.latestBackupTripCount()
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Explanation
                    Text("settings.data.recovery.explanation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)

                    if backupDate != nil {
                        // Backup snapshot info
                        VStack(spacing: 0) {
                            infoRow(
                                label: Text("settings.data.recovery.last_saved"),
                                value: formattedDate
                            )
                            if let count = backupTripCount {
                                Divider().padding(.leading, 18)
                                infoRow(
                                    label: Text("settings.data.recovery.trips_count"),
                                    value: "\(count)"
                                )
                            }
                        }
                        .background(cardBackground)
                        .shadow(color: cardShadow, radius: colorScheme == .dark ? 10 : 12, x: 0, y: colorScheme == .dark ? 3 : 4)

                        // Restore button
                        Button {
                            showConfirmation = true
                        } label: {
                            Text("settings.data.restore.action")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(cardBackground)
                                .shadow(color: cardShadow, radius: colorScheme == .dark ? 10 : 12, x: 0, y: colorScheme == .dark ? 3 : 4)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // No backup yet
                        Text("settings.data.recovery.no_backup")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(cardBackground)
                            .shadow(color: cardShadow, radius: colorScheme == .dark ? 10 : 12, x: 0, y: colorScheme == .dark ? 3 : 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(Text("settings.data.local_backup"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            Text("settings.data.restore.confirm.title"),
            isPresented: $showConfirmation
        ) {
            Button(role: .destructive) {
                do {
                    let result = try store.restoreFromBackup()
                    loadBackupInfo()
                    showRecoveryToast(count: result.trips)
                } catch {
                    showRecoveryToast(message: error.localizedDescription)
                }
            } label: {
                Text("settings.data.restore.action")
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.data.restore.confirm.message")
        }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
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
        .animation(.easeInOut(duration: 0.2), value: toastMessage != nil)
        .onAppear { loadBackupInfo() }
    }

    private func infoRow(label: Text, value: String) -> some View {
        HStack {
            label.font(.body).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.72)
                    : Color(UIColor.secondarySystemGroupedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.04),
                        lineWidth: 1
                    )
            )
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.16) : Color.black.opacity(0.03)
    }

    private func showRecoveryToast(count: Int) {
        let msg = count == 1
            ? NSLocalizedString("settings.data.restore.success.one", comment: "")
            : String(format: NSLocalizedString("settings.data.restore.success", comment: ""), count)
        showRecoveryToast(message: msg)
    }

    private func showRecoveryToast(message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toastMessage = message }
        Task {
            try? await Task.sleep(for: .milliseconds(2000))
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }
}

// MARK: - CalendarSettingsView

private struct CalendarSettingsView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("calendar_sync_enabled")         private var calendarSyncEnabled        = false
    @AppStorage("calendar_pack_reminder_enabled") private var calendarPackReminderEnabled = true
    @AppStorage("calendar_pack_hour")             private var calendarPackHour            = 20
    @AppStorage("calendar_pack_minute")           private var calendarPackMinute          = 0

    @State private var showPermissionAlert = false
    @State private var showBulkAlert       = false
    @State private var pendingCount        = 0
    @State private var toastMessage: String?

    private var groupFill: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.72)
            : Color(UIColor.secondarySystemGroupedBackground)
    }

    private var groupStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.primary.opacity(0.05)
    }

    private var groupShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.16)
            : Color.black.opacity(0.03)
    }

    private var packTimeBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour   = calendarPackHour
                comps.minute = calendarPackMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newDate in
                let comps    = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                calendarPackHour   = comps.hour   ?? 20
                calendarPackMinute = comps.minute  ?? 0
            }
        )
    }

    private func handleToggleOn() async {
        let granted = await CalendarManager.shared.requestAccess()
        if granted {
            calendarSyncEnabled = true
            let count = CalendarManager.shared.pendingCount(from: store.trips)
            if count > 0 {
                pendingCount = count
                showBulkAlert = true
            }
        } else {
            calendarSyncEnabled = false
            showPermissionAlert = true
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toastMessage = message }
        Task {
            try? await Task.sleep(for: .milliseconds(2000))
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("settings.calendar.toggle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.9) : Color.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("settings.calendar.add_trips")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { calendarSyncEnabled },
                            set: { newValue in
                                if newValue { Task { await handleToggleOn() } }
                                else { calendarSyncEnabled = false }
                            }
                        ))
                        .labelsHidden()
                        .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 58)

                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03))
                        .frame(height: 1)

                    // 打包提醒子开关
                    HStack(spacing: 12) {
                        Text("settings.calendar.pack_reminder")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Toggle("", isOn: $calendarPackReminderEnabled)
                            .labelsHidden()
                            .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .opacity(calendarSyncEnabled ? 1 : (colorScheme == .dark ? 0.45 : 0.5))
                    .allowsHitTesting(calendarSyncEnabled)

                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03))
                        .frame(height: 1)

                    DatePicker(
                        LocalizedStringKey("settings.calendar.packtime"),
                        selection: packTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .overlay(alignment: .leading) {
                        Text("settings.calendar.packtime")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .padding(.leading, 18)
                    }
                    .opacity(calendarSyncEnabled && calendarPackReminderEnabled ? 1 : (colorScheme == .dark ? 0.45 : 0.5))
                    .allowsHitTesting(calendarSyncEnabled && calendarPackReminderEnabled)
                }
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(groupFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(groupStroke, lineWidth: 1)
                        )
                )
                .shadow(color: groupShadow, radius: colorScheme == .dark ? 10 : 12, x: 0, y: colorScheme == .dark ? 3 : 4)
                .padding(.horizontal, 16)


            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(Text("settings.calendar.entry"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
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
        .animation(.easeInOut(duration: 0.2), value: toastMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: calendarSyncEnabled)
        .alert(LocalizedStringKey("settings.calendar.permission.denied.title"), isPresented: $showPermissionAlert) {
            Button("settings.calendar.permission.open_settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("settings.calendar.permission.denied.message")
        }
        .alert(LocalizedStringKey("settings.calendar.bulk.title"), isPresented: $showBulkAlert) {
            Button("settings.calendar.bulk.confirm") {
                let written = CalendarManager.shared.addAllUpcoming(
                    store.trips,
                    packHour: calendarPackHour,
                    packMinute: calendarPackMinute,
                    includePackReminder: calendarPackReminderEnabled
                )
                if written > 0 {
                    showToast(String(format: NSLocalizedString("settings.calendar.bulk.added_toast", comment: ""), written))
                } else {
                    showToast(NSLocalizedString("settings.calendar.bulk.failed_toast", comment: ""))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(format: NSLocalizedString("settings.calendar.bulk.message", comment: ""), pendingCount))
        }
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
    @State private var showResetAllConfirm = false
    @AppStorage("debug_mock_weather_enabled") private var debugMockWeatherEnabled = false

    var body: some View {
        List {
            Section("settings.developer.sheet_group") {
                Toggle(isOn: Binding(
                    get: { (UserDefaults.standard.string(forKey: sheetVariantDefaultsKey).flatMap(SheetVariant.init) ?? .fallback) == .ultimate },
                    set: { useScaling in
                        UserDefaults.standard.set(
                            (useScaling ? SheetVariant.ultimate : SheetVariant.fallback).rawValue,
                            forKey: sheetVariantDefaultsKey
                        )
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showToast(useScaling ? "settings.developer.sheet_fallback_toast_on" : "settings.developer.sheet_fallback_toast_off")
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.developer.sheet_fallback_toggle")
                        Text("settings.developer.sheet_fallback_toggle.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                .listRowSeparator(.hidden)
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
                .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                .listRowSeparator(.hidden)

                Toggle(isOn: Binding(
                    get: { debugMockWeatherEnabled },
                    set: { newValue in
                        debugMockWeatherEnabled = newValue
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showToast(newValue ? String(localized: "settings.mock.weather_preview.enabled") : String(localized: "settings.mock.weather_preview.disabled"))
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mock.weather_preview")
                        Text("settings.mock.weather_preview.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                .listRowSeparator(.hidden)
            }

            Section("CN Storefront") {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "debugChinaStorefront") },
                    set: { newValue in
                        UserDefaults.standard.set(newValue, forKey: "debugChinaStorefront")
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulate CN Storefront")
                        Text("HK/MO → 港澳通行证，TW → 台湾通行证")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                .listRowSeparator(.hidden)
            }

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

#if !targetEnvironment(macCatalyst)
            Section("Live Activity") {
                DisclosureGroup {
                    // 诊断：显示当前各项条件状态
                    VStack(alignment: .leading, spacing: 4) {
                        let enabled = UserDefaults.standard.bool(forKey: LiveActivityManager.enabledKey)
                        let authOK = LiveActivityManager.shared.diagnosticAuthEnabled
                        let nearestTrip = store.trips
                            .filter { $0.departureDate > Date() }
                            .sorted { $0.departureDate < $1.departureDate }
                            .first
                        let itemCount = nearestTrip?.safeSections.flatMap { $0.items ?? [] }.filter { !$0.name.isEmpty }.count ?? 0
                        Text("开关：\(enabled ? "✅ 已开启" : "❌ 未开启")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("系统授权：\(authOK ? "✅ 允许" : "❌ 未授权")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("最近行程：\(nearestTrip?.name ?? "无（或已出发）")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("物品数：\(itemCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)
                    .padding(.top, 4)

                    actionRow(title: "强制启动（最近行程）") {
                        let today = Calendar.current.startOfDay(for: Date())
                        guard let trip = store.trips
                            .filter({ $0.departureDate >= today })
                            .sorted(by: { $0.departureDate < $1.departureDate })
                            .first else {
                            showToast("无可用行程（需有今天或之后出发的行程）")
                            return
                        }
                        let result = LiveActivityManager.shared.forceStart(for: trip)
                        showToast(result)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }

                    actionRow(title: "查看当前 Activity 状态") {
                        let info = LiveActivityManager.shared.diagnosticActivityState
                        showToast(info)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }

                    actionRow(title: "结束所有 Live Activity", tint: .red) {
                        Task { @MainActor in LiveActivityManager.shared.endAll() }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showToast("已结束")
                    }
                } label: {
                    Text("Live Activity")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
#endif

            Section("settings.developer.calendar_group") {
                actionRow(title: "settings.developer.clear_calendar_ids") {
                    CalendarManager.shared.clearAddedIds()
                    UserDefaults.standard.set(false, forKey: "calendar_sync_enabled")
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showToast("settings.developer.clear_calendar_ids.success")
                }
            }

            Section("settings.developer.danger_group") {
                actionRow(title: "settings.developer.reset_all_data", tint: .red) {
                    showResetAllConfirm = true
                }
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
        .alert(
            "settings.developer.reset_all_data.confirm.title",
            isPresented: $showResetAllConfirm
        ) {
            Button("settings.developer.reset_all_data.confirm.action", role: .destructive) {
                store.resetAllData()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    exit(0)
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.developer.reset_all_data.confirm.message")
        }
    }

    private func actionRow(title: LocalizedStringKey, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(tint)
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
