//
//  SettingsView.swift
//  Carry
//

import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showAppearancePicker = false
    @State private var showRoadmapSheet = false
    @State private var showCoffeeSheet = false
    @State private var didApplyLaunchSheetReset = false
    @Environment(\.scenePhase) private var scenePhase
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

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("settings.title")
                            .font(.system(size: 40, weight: .bold, design: .default))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

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

                    settingsGroup(title: "settings.section.support") {
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
                    .padding(.bottom, 10)
                }
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.03), radius: 12, x: 0, y: 4)
            .padding(.horizontal, 20)
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
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)
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
