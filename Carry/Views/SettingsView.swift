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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("settings.title")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            List {
                Section("settings.section.general") {
                    Button {
                        showAppearancePicker = true
                    } label: {
                        HStack {
                            Text("Appearance")
                            Spacer()
                            Text(currentAppearance.titleKey)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)
                    .confirmationDialog("Appearance", isPresented: $showAppearancePicker, titleVisibility: .visible) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Button(mode.titleKey) {
                                appearanceModeRaw = mode.rawValue
                            }
                        }
                    }

                    Button {
                        openSystemSettings()
                    } label: {
                        HStack {
                            Text("settings.about.language")
                            Spacer()
                            Text(currentLanguageDisplay)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)

                    Button {
                        openSystemSettings()
                    } label: {
                        HStack {
                            Text("settings.notifications")
                            Spacer()
                            Text(notificationStatusText)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)
                }

                Section("Support") {
                    Button {
                        showCoffeeSheet = true
                    } label: {
                        HStack {
                            Text("settings.section.support")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("☕️")
                            Image(systemName: "chevron.right")
                                .foregroundColor(Color(.tertiaryLabel))
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        FeedbackView()
                    } label: {
                        Text("settings.feedback")
                    }
                    .foregroundColor(.primary)
                }

                Section("settings.section.about") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Text("settings.about.entry")
                    }
                    .foregroundColor(.primary)

                    Button {
                        showRoadmapSheet = true
                    } label: {
                        HStack {
                            Text(roadmapTitle)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)

                    NavigationLink {
                        TermsView()
                    } label: {
                        Text("settings.legal.terms")
                    }
                    .foregroundColor(.primary)

                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Text("settings.legal.privacy")
                    }
                    .foregroundColor(.primary)

                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await refreshNotificationStatus() }
        .onAppear {
            // Guard against stale state restoration reopening this sheet on fresh launches.
            if !didApplyLaunchSheetReset {
                showRoadmapSheet = false
                didApplyLaunchSheetReset = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // If iOS restores transient sheet state when app re-enters foreground, close it.
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
}

// MARK: - Feedback View

struct FeedbackView: View {

    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .navigationTitle("settings.feedback")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { openMail() }
    }

    private func openMail() {
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
        if let url = components?.url {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(TripStore())
}
