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
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("about.tagline")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.82) : Color.primary.opacity(0.7))
                            .lineSpacing(7)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)

                        AboutModuleCard {
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

                        AboutModuleCard(title: "about.follow") {
                            AboutLinkRow(label: "Twitter / X", handle: "@murphy_latte", url: "https://x.com/murphy_latte")
                        }

                        AboutModuleCard(title: "about.app") {
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

                        AboutModuleCard(title: "about.legal") {
                            VStack(spacing: 0) {
                                legalRow(label: "settings.legal.terms") { TermsView() }
                                legalRow(label: "settings.legal.privacy") { PrivacyView() }
                                // 第三方数据/检索服务署名收进子页，主页不再平铺；详见 AcknowledgementsView。
                                legalRow(label: "about.acknowledgements") { AcknowledgementsView() }
                            }
                        }
                    }

                    Spacer(minLength: 16)

                    madeWithFooter
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(minHeight: max(0, proxy.size.height - 32), alignment: .top)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("about.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Subviews

    private var madeWithFooter: some View {
        HStack(spacing: 6) {
            Text("about.madeWith")
                .font(.footnote)
                .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.7) : Color(UIColor.tertiaryLabel))
            Text("❤️")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 8)
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

/// 第三方数据来源与地点检索服务商署名。
///
/// 合规说明：OpenFlights（ODbL）、Mapbox（ToS）、OpenStreetMap（ODbL，Geoapify 数据源）均要求
/// 标注来源；OurAirports 为 Public Domain、Wikidata 为 CC0，本身无强制要求，一并致谢。这些署名
/// 不要求出现在首屏，从「关于 → 数据来源与署名」一跳可达、保留许可与原始链接即满足各许可条款。
struct AcknowledgementsView: View {

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AboutModuleCard(title: "about.data") {
                    VStack(spacing: 0) {
                        AboutLinkRow(label: "OurAirports", handle: "Public Domain", url: "https://ourairports.com/data/")
                        AboutLinkRow(label: "OpenFlights", handle: "ODbL", url: "https://openflights.org/data.html")
                        AboutLinkRow(label: "Wikidata", handle: "CC0", url: "https://www.wikidata.org")
                    }
                }

                AboutModuleCard(title: "about.providers") {
                    VStack(spacing: 0) {
                        // 海外地点检索服务商云控可切换（Mapbox / Geoapify，含 auto），同一会话两家都可能命中——
                        // 两家服务都须按各自 ToS 署名；底层数据均归 OpenStreetMap，单列一行覆盖。
                        AboutLinkRow(label: "Mapbox", handle: "© Mapbox", url: "https://www.mapbox.com/about/maps/")
                        AboutLinkRow(label: "Geoapify", handle: "© Geoapify", url: "https://www.geoapify.com/")
                        AboutLinkRow(label: "OpenStreetMap", handle: "© OpenStreetMap", url: "https://www.openstreetmap.org/copyright")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("about.acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared About components

/// 关于页统一的卡片容器（可选区段标题 + 内容）。About 与 Acknowledgements 共用，避免样式漂移。
private struct AboutModuleCard<Content: View>: View {

    let title: LocalizedStringKey?
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
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
}

/// 关于页的「标签 + 取值 + 外链」行（社交、数据来源、服务商署名共用）。
private struct AboutLinkRow: View {

    let label: LocalizedStringKey
    let handle: String
    let url: String
    var fallbackURL: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            openAboutLink(url, fallback: fallbackURL)
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
}

private func openAboutLink(_ urlString: String, fallback: String? = nil) {
    guard let url = URL(string: urlString) else { return }
    UIApplication.shared.open(url, options: [:]) { success in
        guard !success, let fallback, let fb = URL(string: fallback) else { return }
        UIApplication.shared.open(fb)
    }
}

#Preview {
    AboutView()
        .environmentObject(TripStore())
}

#Preview("Acknowledgements") {
    NavigationStack { AcknowledgementsView() }
}
