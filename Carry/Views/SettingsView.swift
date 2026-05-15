//
//  SettingsView.swift
//  Carry
//

import SwiftUI
import UserNotifications

struct SettingsView: View {

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var currentLanguageDisplay: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let locale = Locale.current
        return locale.localizedString(forIdentifier: preferred)?.capitalized
            ?? preferred
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
                Section("settings.section.about") {
                    LabeledContent(
                        "settings.about.appName",
                        value: String(localized: "settings.appName.value")
                    )
                    LabeledContent("settings.about.version", value: appVersion)
                    LabeledContent(
                        "settings.about.developer",
                        value: String(localized: "settings.about.developerName")
                    )
                }

                Section("settings.section.general") {
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

                Section("settings.section.connect") {
                    Button {
                        // placeholder
                    } label: {
                        HStack {
                            Text("settings.connect.twitter")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)

                    Button {
                        // placeholder
                    } label: {
                        HStack {
                            Text("settings.connect.instagram")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)
                }

                Section("settings.section.legal") {
                    Button {
                        // placeholder
                    } label: {
                        HStack {
                            Text("settings.legal.privacy")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await refreshNotificationStatus() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            Task { await refreshNotificationStatus() }
        }
    }
}

#Preview {
    SettingsView()
}
