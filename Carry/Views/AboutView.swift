//
//  AboutView.swift
//  Carry
//

import SwiftUI
import UIKit

struct AboutView: View {

    @EnvironmentObject private var store: TripStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var versionTapCount = 0
    @State private var versionTapTimer: Timer?

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("about.tagline")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.82) : Color.primary.opacity(0.7))
                    .lineSpacing(7)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)

                moduleCard {
                    HStack(spacing: 12) {
                        Image("Murphy")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("about.author.name")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Text("about.author.role")
                                .font(.caption)
                                .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.78) : .secondary)
                        }
                        Spacer()
                    }
                }

                moduleCard(title: "about.follow") {
                    VStack(spacing: 0) {
                        socialRow(label: "Twitter / X", handle: "@murphy_latte", url: "https://x.com/murphy_latte")
                    }
                }

                moduleCard(title: "about.app") {
                    VStack(spacing: 0) {
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
                }

                moduleCard(title: "about.legal") {
                    VStack(spacing: 0) {
                        legalRow(label: "settings.legal.terms") { TermsView() }
                        legalRow(label: "settings.legal.privacy") { PrivacyView() }
                    }
                }

                // 机场数据来源署名：OpenFlights 为 ODbL，要求标注来源。
                moduleCard(title: "about.data") {
                    VStack(spacing: 0) {
                        socialRow(label: "OurAirports", handle: "Public Domain", url: "https://ourairports.com/data/")
                        socialRow(label: "OpenFlights", handle: "ODbL", url: "https://openflights.org/data.html")
                        socialRow(label: "Wikidata", handle: "CC0", url: "https://www.wikidata.org")
                    }
                }

                // 海外地点检索服务商署名：Mapbox ToS 与 OpenStreetMap（Geoapify 数据源）ODbL 均要求标注。
                moduleCard(title: "about.providers") {
                    VStack(spacing: 0) {
                        socialRow(label: "Mapbox", handle: "© Mapbox", url: "https://www.mapbox.com/about/maps/")
                        socialRow(label: "OpenStreetMap", handle: "© OpenStreetMap", url: "https://www.openstreetmap.org/copyright")
                    }
                }

                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("about.madeWith")
                            .font(.footnote)
                            .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.7) : Color(UIColor.tertiaryLabel))
                        Text("❤️")
                            .font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 30)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("about.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Subviews

    private func moduleCard<Content: View>(
        title: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.65) : Color(UIColor.tertiaryLabel))
                    .kerning(1.5)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: colorScheme == .dark ? 8 : 10, x: 0, y: colorScheme == .dark ? 3 : 5)
    }

    private func legalRow<Destination: View>(
        label: LocalizedStringKey,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func socialRow(label: LocalizedStringKey, handle: String, url: String, fallbackURL: String? = nil) -> some View {
        Button {
            openSocialURL(url, fallbackURL: fallbackURL)
        } label: {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(handle)
                    .font(.subheadline)
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.88) : .secondary)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.55) : Color(UIColor.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    private func openSocialURL(_ urlString: String, fallbackURL: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            guard !success, let fallbackURL, let fallback = URL(string: fallbackURL) else { return }
            UIApplication.shared.open(fallback)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cardFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(Color(UIColor.secondarySystemBackground).opacity(0.76))
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(UIColor.systemBackground).opacity(0.94),
                        Color(UIColor.systemBackground).opacity(0.82)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.04)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.022)
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
        do {
            try logText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return   // 写失败就别分享空/旧文件
        }
        // About 处于 Settings sheet 的导航栈内，rootViewController 已有 presentation——
        // 必须从最顶层 presenter 呈现，否则 present 被静默吞掉。
        UIApplication.shared.presentActivitySheet(items: [url])
    }
}

#Preview {
    AboutView()
        .environmentObject(TripStore())
}
