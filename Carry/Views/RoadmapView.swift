//
//  RoadmapView.swift
//  Carry
//

import SwiftUI
import Combine

private enum RoadmapRemote {
    // Default remote URL. You can override this inside the app UI.
    static let urlString = "https://raw.githubusercontent.com/your-user/your-repo/main/roadmap.json"
}

private enum RoadmapL10n {
    private static var languageCode: String {
        Locale.preferredLanguages.first?.lowercased() ?? "en"
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
        updatedAt: "2026-05-20",
        banner: RoadmapL10n.text(
            en: "🚀 App Store launch, July 2026",
            zhHans: "🚀 App Store 上线，2026年7月",
            zhHant: "🚀 App Store 上線，2026年7月"
        ),
        sections: [
            RoadmapSection(
                id: "upcoming",
                title: RoadmapL10n.text(
                    en: "Upcoming updates",
                    zhHans: "即将推出的更新",
                    zhHant: "即將推出的更新"
                ),
                items: [
                    RoadmapItem(
                        id: "ai-pack",
                        title: RoadmapL10n.text(en: "Trip duplication", zhHans: "复制行程", zhHant: "複製行程"),
                        status: .inProgress,
                        note: nil
                    ),
                    RoadmapItem(id: "plug-adapter", title: RoadmapL10n.text(en: "International plug & adapter guide", zhHans: "出国旅行充电插头及转换器", zhHant: "出國旅行充電插頭及轉換器"), status: .planned, note: nil),
                    RoadmapItem(id: "exchange-rate", title: RoadmapL10n.text(en: "Exchange rate info", zhHans: "汇率信息", zhHant: "匯率資訊"), status: .planned, note: nil),
                    RoadmapItem(id: "weather", title: RoadmapL10n.text(en: "Weather forecast", zhHans: "天气预报", zhHant: "天氣預報"), status: .planned, note: nil),
                    RoadmapItem(id: "trip-stats", title: RoadmapL10n.text(en: "Trip insights", zhHans: "行程统计", zhHant: "行程統計"), status: .planned, note: nil)
                ]
            ),
            RoadmapSection(
                id: "done",
                title: RoadmapL10n.text(en: "Completed", zhHans: "已完成", zhHant: "已完成"),
                items: [
                    RoadmapItem(id: "worth-considering", title: RoadmapL10n.text(en: "Worth considering", zhHans: "顺手考虑一下", zhHant: "順手考慮一下"), status: .done, note: nil),
                    RoadmapItem(id: "smart-suggestion", title: RoadmapL10n.text(en: "Smart suggestions", zhHans: "智能推荐清单", zhHant: "智能推薦清單"), status: .done, note: nil),
                    RoadmapItem(id: "custom-section", title: RoadmapL10n.text(en: "Custom sections", zhHans: "自定义分类", zhHant: "自定義分類"), status: .done, note: nil),
                    RoadmapItem(id: "custom", title: RoadmapL10n.text(en: "Custom packing list", zhHans: "自定义打包清单", zhHant: "自定義打包清單"), status: .done, note: nil),
                    RoadmapItem(id: "sorting", title: RoadmapL10n.text(en: "Item & section sorting", zhHans: "物品与分类排序", zhHant: "物品與分類排序"), status: .done, note: nil)
                ]
            )
        ]
    )
}

struct RoadmapView: View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle(RoadmapL10n.text(en: "Roadmap", zhHans: "路线图", zhHant: "路線圖"))
        .navigationBarTitleDisplayMode(.inline)
#if DEBUG
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draftURL = remoteURL
                    showSourceSheet = true
                } label: {
                    Image(systemName: "link")
                }
            }
        }
#endif
        .sheet(isPresented: $showSourceSheet) {
            NavigationStack {
                Form {
                    Section(RoadmapL10n.text(en: "Remote JSON URL", zhHans: "远程 JSON 地址", zhHant: "遠端 JSON 位址")) {
                        TextField("https://raw.githubusercontent.com/...", text: $draftURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text(RoadmapL10n.text(
                            en: "Leave empty to use built-in defaults; fill in URL to prioritize remote data.",
                            zhHans: "留空将使用内置默认数据；填入后会优先拉取远程。",
                            zhHant: "留空將使用內建預設資料；填入後會優先拉取遠端。"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(RoadmapL10n.text(en: "Roadmap Source", zhHans: "路线图数据源", zhHant: "路線圖資料來源"))
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(RoadmapL10n.text(en: "Product Roadmap", zhHans: "产品路线图", zhHant: "產品路線圖"))
                .font(.title2.bold())
                .foregroundStyle(.primary)
            if let banner = payload?.banner, !banner.isEmpty {
                Text(banner)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.7), Color.indigo.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            if let updatedAt = payload?.updatedAt, !updatedAt.isEmpty {
                Text(RoadmapL10n.text(en: "Updated: \(updatedAt)", zhHans: "更新于：\(updatedAt)", zhHant: "更新於：\(updatedAt)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && payload == nil {
            ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
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
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func sectionBlock(_ section: RoadmapSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    roadmapRow(item: item, isLast: index == section.items.count - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func roadmapRow(item: RoadmapItem, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor(item.status))
                    .frame(width: 16, height: 16)
                    .overlay {
                        if item.status == .done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2, height: 36)
                        .padding(.top, 2)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 8)
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
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white
    }

    private var background: Color {
        colorScheme == .dark ? Color.black : Color(.systemGroupedBackground)
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

#Preview {
    NavigationStack {
        RoadmapView()
    }
}
