//
//  RoadmapView.swift
//  Carry
//

import SwiftUI
import Combine

private enum RoadmapRemote {
    // Default remote URL. You can override this inside the app UI.
    static let urlString = "https://raw.githubusercontent.com/murphy-lyu/carry-ios/main/roadmap.json"
}

private enum RoadmapL10n {
    private static var languageCode: String {
        (Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en").lowercased()
    }

    static var isChinese: Bool {
        languageCode.hasPrefix("zh")
    }

    static func text(en: String, zhHans: String, zhHant: String? = nil) -> String {
        guard isChinese else { return en }
        if languageCode.contains("hant") {
            return zhHant ?? zhHans
        }
        return zhHans
    }
}

private enum RoadmapStatus: String, Codable {
    case planned
    case inProgress = "in_progress"
    case done
}

private struct RoadmapItem: Codable, Identifiable {
    var id: String
    var title: String
    var status: RoadmapStatus
    var note: String?
}

private struct RoadmapSection: Codable, Identifiable {
    var id: String
    var title: String
    var items: [RoadmapItem]
}

private struct RoadmapPayload: Codable {
    var updatedAt: String?
    var banner: String?
    var sections: [RoadmapSection]

    static let embeddedDefault = RoadmapPayload(
        updatedAt: "2026-05-27",
        banner: RoadmapL10n.text(
            en: "🎉 Now on the App Store · Actively shipping",
            zhHans: "🎉 已上线 App Store · 持续迭代中",
            zhHant: "🎉 已上線 App Store · 持續迭代中"
        ),
        sections: [
            RoadmapSection(
                id: "upcoming",
                title: RoadmapL10n.text(en: "Upcoming", zhHans: "即将推出", zhHant: "即將推出"),
                items: [
                    RoadmapItem(id: "destination-info", title: RoadmapL10n.text(en: "Destination info (plugs, voltage, currency)", zhHans: "目的地实用信息（充电插头、电压、货币）", zhHant: "目的地實用資訊（充電插頭、電壓、貨幣）"), status: .inProgress, note: nil),
                    RoadmapItem(id: "weather", title: RoadmapL10n.text(en: "Weather forecast", zhHans: "目的地天气预报", zhHant: "目的地天氣預報"), status: .planned, note: nil),
                    RoadmapItem(id: "import-itinerary", title: RoadmapL10n.text(en: "Import trips from email / bookings", zhHans: "邮件 / 订单导入行程", zhHant: "郵件 / 訂單匯入行程"), status: .planned, note: nil)
                ]
            ),
            RoadmapSection(
                id: "done",
                title: RoadmapL10n.text(en: "Shipped", zhHans: "已上线", zhHant: "已上線"),
                items: [
                    RoadmapItem(id: "smart-suggestions", title: RoadmapL10n.text(en: "Smart suggestions", zhHans: "智能推荐清单", zhHant: "智能推薦清單"), status: .done, note: nil),
                    RoadmapItem(id: "worth-considering", title: RoadmapL10n.text(en: "Worth considering", zhHans: "顺手考虑一下", zhHant: "順手考慮一下"), status: .done, note: nil),
                    RoadmapItem(id: "world-map", title: RoadmapL10n.text(en: "World map & visited countries", zhHans: "世界地图 & 到访国家", zhHant: "世界地圖 & 到訪國家"), status: .done, note: nil),
                    RoadmapItem(id: "packing-reminder", title: RoadmapL10n.text(en: "Packing reminders", zhHans: "打包提醒", zhHant: "打包提醒"), status: .done, note: nil),
                    RoadmapItem(id: "share-list", title: RoadmapL10n.text(en: "Share packing list", zhHans: "分享清单", zhHant: "分享清單"), status: .done, note: nil),
                    RoadmapItem(id: "custom-section", title: RoadmapL10n.text(en: "Custom sections", zhHans: "自定义分类", zhHant: "自定義分類"), status: .done, note: nil),
                    RoadmapItem(id: "sorting", title: RoadmapL10n.text(en: "Item & section sorting", zhHans: "物品与分类排序", zhHant: "物品與分類排序"), status: .done, note: nil),
                    RoadmapItem(id: "item-quantity", title: RoadmapL10n.text(en: "Item quantity", zhHans: "物品数量", zhHant: "物品數量"), status: .done, note: nil),
                    RoadmapItem(id: "trip-duplicate", title: RoadmapL10n.text(en: "Trip duplication", zhHans: "复制行程", zhHant: "複製行程"), status: .done, note: nil),
                    RoadmapItem(id: "backup-restore", title: RoadmapL10n.text(en: "Backup & restore", zhHans: "备份与还原", zhHant: "備份與還原"), status: .done, note: nil),
                    RoadmapItem(id: "app-icons", title: RoadmapL10n.text(en: "App icon themes", zhHans: "多套应用图标", zhHant: "多套應用圖示"), status: .done, note: nil),
                    RoadmapItem(id: "siri-shortcuts", title: RoadmapL10n.text(en: "Siri shortcuts", zhHans: "Siri 快捷指令", zhHant: "Siri 捷徑"), status: .done, note: nil)
                ]
            )
        ]
    )
}

struct RoadmapView: View {
    var onClose: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("roadmap_remote_url") private var remoteURL = ""
    @State private var showSourceSheet = false
    @State private var draftURL = ""

    @State private var payload: RoadmapPayload?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carry_roadmap_cache.json")
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    content
                    footerNote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(CarrySubtleBackground())
        .navigationBarHidden(true)
        .sheet(isPresented: $showSourceSheet) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(RoadmapL10n.text(en: "Remote JSON URL", zhHans: "远程 JSON 地址", zhHant: "遠端 JSON 位址"))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text(RoadmapL10n.text(
                                en: "Leave empty to use built-in defaults; fill in URL to prioritize remote data.",
                                zhHans: "留空将使用内置默认数据；填入后会优先拉取远程。",
                                zhHant: "留空將使用內建預設資料；填入後會優先拉取遠端。"
                            ))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        TextField("https://raw.githubusercontent.com/...", text: $draftURL)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color(UIColor.systemBackground).opacity(0.62))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        HStack(spacing: 10) {
                            Button(RoadmapL10n.text(en: "Cancel", zhHans: "取消", zhHant: "取消")) {
                                showSourceSheet = false
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(UIColor.systemBackground).opacity(0.60))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
                            )

                            Button(RoadmapL10n.text(en: "Save", zhHans: "保存", zhHant: "儲存")) {
                                remoteURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                showSourceSheet = false
                                Task { await load() }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundStyle(Color(UIColor.systemBackground))
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.primary.opacity(0.92))
                            )
                        }
                    }
                    .padding(16)
                }
                .background(CarrySubtleBackground())
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(RoadmapL10n.text(en: "Cancel", zhHans: "取消", zhHant: "取消")) { showSourceSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(RoadmapL10n.text(en: "Save", zhHans: "保存", zhHant: "儲存")) {
                            remoteURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            showSourceSheet = false
                            Task { await load() }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(RoadmapL10n.text(en: "Roadmap", zhHans: "路线图", zhHant: "路線圖"))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
#if DEBUG
                Button {
                    draftURL = remoteURL
                    showSourceSheet = true
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .glassCircleButton()
                }
                .buttonStyle(.plain)
#endif

                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .glassCircleButton()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner = payload?.banner, !banner.isEmpty {
                Text(banner)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let updatedAt = payload?.updatedAt, !updatedAt.isEmpty {
                Text(RoadmapL10n.text(en: "Updated: \(updatedAt)", zhHans: "更新于：\(updatedAt)", zhHant: "更新於：\(updatedAt)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && payload == nil {
            ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 32)
        } else if let payload {
            ForEach(payload.sections) { section in
                sectionBlock(section)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(errorMessage ?? RoadmapL10n.text(en: "Roadmap unavailable", zhHans: "路线图暂不可用", zhHant: "路線圖暫不可用"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(RoadmapL10n.text(
                    en: "Tap the top-right link icon to configure your GitHub raw JSON URL.",
                    zhHans: "点击右上角链接图标，配置你的 GitHub Raw JSON 地址。",
                    zhHant: "點擊右上角連結圖示，設定你的 GitHub Raw JSON 位址。"
                ))
                    .font(.caption)
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.68) : Color(UIColor.tertiaryLabel))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func sectionBlock(_ section: RoadmapSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.68) : Color(UIColor.tertiaryLabel))
                .kerning(1.4)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    roadmapRow(
                        item: item,
                        isLast: index == section.items.count - 1,
                        showLatestBadge: section.id == "done" && index == 0
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.035), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footerNote: some View {
        HStack {
            Spacer()
            Text("about.madeWith")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("❤️")
                .font(.footnote)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func roadmapRow(item: RoadmapItem, isLast: Bool, showLatestBadge: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                statusDot(for: item.status)

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2, height: 36)
                        .padding(.top, 2)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    if showLatestBadge {
                        Text(RoadmapL10n.text(en: "Latest", zhHans: "最新", zhHant: "最新"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                            )
                    }
                }
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 6)
        }
    }

    @ViewBuilder
    private func statusDot(for status: RoadmapStatus) -> some View {
        if status == .inProgress {
            RippleDot(color: dotColor(status))
        } else {
            Circle()
                .fill(dotColor(status))
                .frame(width: 16, height: 16)
                .overlay {
                    if status == .done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
    }

    private func dotColor(_ status: RoadmapStatus) -> Color {
        switch status {
        case .done: return .orange
        case .inProgress: return .blue
        case .planned: return .gray
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.74)
            : Color(UIColor.systemBackground).opacity(0.82)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil

        let remoteCandidates = [remoteURL.trimmingCharacters(in: .whitespacesAndNewlines), RoadmapRemote.urlString]
            .filter { !$0.isEmpty && !$0.contains("your-user/your-repo") }

        for candidate in remoteCandidates {
            if let remote = URL(string: candidate),
               let fetched = await fetch(remote: remote) {
                payload = fetched
                saveCache(fetched)
                isLoading = false
                return
            }
        }

        if let cached = loadCache() {
            payload = cached
            isLoading = false
            return
        }

        payload = .embeddedDefault
        isLoading = false
        errorMessage = RoadmapL10n.text(
            en: "Using built-in roadmap data.",
            zhHans: "当前使用内置路线图数据。",
            zhHant: "目前使用內建路線圖資料。"
        )
    }

    private func fetch(remote: URL) async -> RoadmapPayload? {
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(RoadmapPayload.self, from: data)
        } catch {
            return nil
        }
    }

    private func saveCache(_ payload: RoadmapPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadCache() -> RoadmapPayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(RoadmapPayload.self, from: data)
    }
}

private struct RippleDot: View {
    let color: Color
    @State private var pulse1 = false
    @State private var pulse2 = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(pulse1 ? 0.0 : 0.42), lineWidth: 1.8)
                .frame(width: 16, height: 16)
                .scaleEffect(pulse1 ? 1.9 : 1.0)

            Circle()
                .stroke(color.opacity(pulse2 ? 0.0 : 0.28), lineWidth: 1.6)
                .frame(width: 16, height: 16)
                .scaleEffect(pulse2 ? 2.3 : 1.0)

            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulse1 = true
            }
            withAnimation(.easeOut(duration: 1.5).delay(0.55).repeatForever(autoreverses: false)) {
                pulse2 = true
            }
        }
    }
}

#Preview {
    RoadmapView()
}
