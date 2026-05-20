//
//  AboutView.swift
//  Carry
//

import SwiftUI
import UIKit

struct AboutView: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: TripStore
    @State private var versionTapCount = 0
    @State private var versionTapTimer: Timer?

    private var isChineseLanguage: Bool {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var dividerColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)
            : Color.black.opacity(0.10)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // — Tagline
                Text("about.tagline")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(7)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 28)

                // — Author card
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 0.67)
                    .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Image("murphy")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.author.name")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("about.author.role")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 0.67)
                    .padding(.horizontal, 16)

                // — Follow us
                VStack(alignment: .leading, spacing: 0) {
                    Text("about.follow")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .kerning(1.5)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    socialRow(label: "Twitter / X", handle: "@murphy_lyu", url: "https://twitter.com/murphy_lyu")
                    if isChineseLanguage {
                        socialRow(label: "about.social.xiaohongshu", handle: "@murphy_lyu", url: "https://xiaohongshu.com")
                    }
                }

                // — App info
                VStack(alignment: .leading, spacing: 0) {
                    Text("about.app")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .kerning(1.5)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    infoRow(
                        label: "settings.about.appName",
                        value: "Carry"
                    )
                    infoRow(
                        label: "settings.about.version",
                        value: appVersion,
                        onTap: handleVersionTap
                    )
                }

                // — Footer: made with + (dedication hidden for now)
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("about.madeWith")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Text("❤️")
                            .font(.footnote)
                    }

                    // Hidden by request — keep this block ready for when we want
                    // to bring the dedication back. Translation strings remain
                    // in the catalog under `about.dedication`.
                    //
                    // Text("about.dedication")
                    //     .font(.footnote)
                    //     .italic()
                    //     .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 80)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 32)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("about.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Subviews

    private func socialRow(label: LocalizedStringKey, handle: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(dividerColor)
                .frame(height: 0.67)
                .padding(.leading, 16)
        }
    }

    private func infoRow(
        label: LocalizedStringKey,
        value: String,
        valueColor: Color = .secondary,
        onTap: (() -> Void)? = nil
    ) -> some View {
        Button {
            onTap?()
        } label: {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(valueColor)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 0.67)
                    .padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func handleVersionTap() {
        versionTapCount += 1
        versionTapTimer?.invalidate()
        if versionTapCount >= 5 {
            versionTapCount = 0
            exportDebugLog()
        } else {
            versionTapTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                versionTapCount = 0
            }
        }
    }

    private func exportDebugLog() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let totalItems = store.trips.reduce(0) { $0 + $1.totalCount }
        let logText = CarryLogger.shared.exportLog(
            tripCount: store.trips.count,
            totalItemCount: totalItems
        )
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "carry-log-\(fmt.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? logText.write(to: url, atomically: true, encoding: .utf8)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
