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
    var titleEn: String?
    var titleZhHant: String?
    var status: RoadmapStatus
    var note: String?

    var localizedTitle: String {
        RoadmapL10n.text(en: titleEn ?? title, zhHans: title, zhHant: titleZhHant)
    }
}

private struct RoadmapSection: Codable, Identifiable {
    var id: String
    var title: String
    var titleEn: String?
    var titleZhHant: String?
    var items: [RoadmapItem]

    var localizedTitle: String {
        RoadmapL10n.text(en: titleEn ?? title, zhHans: title, zhHant: titleZhHant)
    }
}

private struct RoadmapPayload: Codable {
    var updatedAt: String?
    var banner: String?
    var sections: [RoadmapSection]

    static let embeddedDefault = RoadmapPayload(
        updatedAt: "2026-05-29",
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
                    RoadmapItem(id: "trip-planning", title: RoadmapL10n.text(en: "Trip planning", zhHans: "行程规划", zhHant: "行程規劃"), status: .inProgress, note: nil),
                    RoadmapItem(id: "calendar-import", title: RoadmapL10n.text(en: "Import trips from Calendar", zhHans: "从日历导入行程", zhHant: "從行事曆匯入行程"), status: .planned, note: nil),
                    RoadmapItem(id: "apple-watch", title: RoadmapL10n.text(en: "Apple Watch app", zhHans: "Apple Watch 支持", zhHant: "Apple Watch 支援"), status: .planned, note: nil)
                ]
            ),
            RoadmapSection(
                id: "done",
                title: RoadmapL10n.text(en: "Shipped", zhHans: "已上线", zhHant: "已上線"),
                items: [
                    RoadmapItem(id: "icloud-sync", title: RoadmapL10n.text(en: "iCloud sync", zhHans: "iCloud 同步", zhHant: "iCloud 同步"), status: .done, note: nil),
                    RoadmapItem(id: "destination-info", title: RoadmapL10n.text(en: "Destination info (plugs, voltage, currency)", zhHans: "目的地实用信息（充电插头、电压、货币）", zhHant: "目的地實用資訊（充電插頭、電壓、貨幣）"), status: .done, note: nil),
                    RoadmapItem(id: "weather", title: RoadmapL10n.text(en: "Weather forecast", zhHans: "目的地天气预报", zhHant: "目的地天氣預報"), status: .done, note: nil),
                    RoadmapItem(id: "live-activity", title: RoadmapL10n.text(en: "Live Activity (Dynamic Island & Lock Screen)", zhHans: "灵动岛 & 锁屏打包进度", zhHant: "靈動島 & 鎖定畫面打包進度"), status: .done, note: nil),
                    RoadmapItem(id: "home-widget", title: RoadmapL10n.text(en: "Home Screen widget", zhHans: "桌面小组件", zhHant: "主畫面小工具"), status: .done, note: nil),
                    RoadmapItem(id: "period-reminder", title: RoadmapL10n.text(en: "Period-aware packing", zhHans: "经期打包提醒", zhHant: "生理期打包提醒"), status: .done, note: nil),
                    RoadmapItem(id: "quick-actions", title: RoadmapL10n.text(en: "Home Screen quick actions", zhHans: "主屏快捷操作", zhHant: "主畫面快速操作"), status: .done, note: nil),
                    RoadmapItem(id: "calendar-sync", title: RoadmapL10n.text(en: "Calendar sync", zhHans: "日历同步", zhHant: "行事曆同步"), status: .done, note: nil),
                    RoadmapItem(id: "smart-suggestions", title: RoadmapL10n.text(en: "Smart suggestions", zhHans: "智能推荐清单", zhHant: "智能推薦清單"), status: .done, note: nil),
                    RoadmapItem(id: "worth-considering", title: RoadmapL10n.text(en: "Little Joys", zhHans: "小确幸", zhHant: "小確幸"), status: .done, note: nil),
                    RoadmapItem(id: "trip-background", title: RoadmapL10n.text(en: "Trip background photo", zhHans: "行程背景图", zhHant: "行程背景圖"), status: .done, note: nil),
                    RoadmapItem(id: "world-map", title: RoadmapL10n.text(en: "World map & visited countries", zhHans: "世界地图 & 到访国家", zhHant: "世界地圖 & 到訪國家"), status: .done, note: nil),
                    RoadmapItem(id: "packing-reminder", title: RoadmapL10n.text(en: "Packing reminders", zhHans: "打包提醒", zhHant: "打包提醒"), status: .done, note: nil),
                    RoadmapItem(id: "share-list", title: RoadmapL10n.text(en: "Share packing list", zhHans: "分享清单", zhHant: "分享清單"), status: .done, note: nil),
                    RoadmapItem(id: "custom-section", title: RoadmapL10n.text(en: "Custom sections", zhHans: "自定义分类", zhHant: "自定義分類"), status: .done, note: nil),
                    RoadmapItem(id: "sorting", title: RoadmapL10n.text(en: "Item & section sorting", zhHans: "物品与分类排序", zhHant: "物品與分類排序"), status: .done, note: nil),
                    RoadmapItem(id: "item-quantity", title: RoadmapL10n.text(en: "Item quantity", zhHans: "物品数量", zhHant: "物品數量"), status: .done, note: nil),
                    RoadmapItem(id: "trip-duplicate", title: RoadmapL10n.text(en: "Trip duplication", zhHans: "复制行程", zhHant: "複製行程"), status: .done, note: nil),
                    RoadmapItem(id: "backup-restore", title: RoadmapL10n.text(en: "Backup & restore", zhHans: "备份与还原", zhHant: "備份與還原"), status: .done, note: nil),
                    RoadmapItem(id: "app-icons", title: RoadmapL10n.text(en: "Themes", zhHans: "主题", zhHant: "主題"), status: .done, note: nil),
                    RoadmapItem(id: "siri-shortcuts", title: RoadmapL10n.text(en: "Siri shortcuts", zhHans: "Siri 快捷指令", zhHant: "Siri 捷徑"), status: .done, note: nil)
                ]
            )
        ]
    )
}

struct RoadmapView: View {
    // 现在只以 push 进入设置栈，用系统返回；不再需要 onClose（原 sheet 关闭回调，已退役）。
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("roadmap_remote_url") private var remoteURL = ""
    @State private var showSourceSheet = false
    @State private var draftURL = ""

    @State private var payload: RoadmapPayload? = .embeddedDefault
    @State private var isLoading = false

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carry_roadmap_cache.json")
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // push 进入设置栈：显示系统导航栏（返回按钮），标题留空，让内容里的大标题继续做表达性页头。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
#if DEBUG
        // 调试入口（远程 JSON 源）放进导航栏 trailing，与返回按钮同排；release 不含。
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
                                .font(.system(.subheadline, design: .rounded))
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(RoadmapL10n.text(en: "Roadmap", zhHans: "路线图", zhHant: "路線圖"))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.65)
                            .tint(.secondary)
                            .transition(.opacity)
                    }
                }
                if let updatedAt = payload?.updatedAt, !updatedAt.isEmpty {
                    Text(RoadmapL10n.text(en: "Updated: \(updatedAt)", zhHans: "更新于：\(updatedAt)", zhHant: "更新於：\(updatedAt)"))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // DEBUG「远程 JSON 源」入口在系统导航栏 trailing（见 body .toolbar）；此处不再有关闭按钮。
        }
    }

    @ViewBuilder
    private var content: some View {
        if let payload {
            ForEach(payload.sections) { section in
                sectionBlock(section)
            }
        }
    }

    private func sectionBlock(_ section: RoadmapSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.localizedTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
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
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.04), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    Text(item.localizedTitle)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)

                    if showLatestBadge {
                        Text(RoadmapL10n.text(en: "Latest", zhHans: "最新", zhHant: "最新"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
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
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(statusAccessibilityText(item.status)))
    }

    /// VoiceOver 用的状态描述（已上线 / 开发中 / 计划中）；与路线图内容一致，只覆盖 en/zh。
    private func statusAccessibilityText(_ status: RoadmapStatus) -> String {
        switch status {
        case .done: return RoadmapL10n.text(en: "Shipped", zhHans: "已上线", zhHant: "已上線")
        case .inProgress: return RoadmapL10n.text(en: "In progress", zhHans: "开发中", zhHant: "開發中")
        case .planned: return RoadmapL10n.text(en: "Planned", zhHans: "计划中", zhHant: "計劃中")
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
            : Color(UIColor.systemBackground).opacity(0.88)
    }

    private func load() async {
        withAnimation(.easeInOut(duration: 0.2)) { isLoading = true }

        let remoteCandidates = [remoteURL.trimmingCharacters(in: .whitespacesAndNewlines), RoadmapRemote.urlString]
            .filter { !$0.isEmpty && !$0.contains("your-user/your-repo") }

        for candidate in remoteCandidates {
            if let remote = URL(string: candidate),
               let fetched = await fetch(remote: remote) {
                withAnimation(.easeInOut(duration: 0.35)) { payload = fetched }
                saveCache(fetched)
                withAnimation(.easeInOut(duration: 0.2)) { isLoading = false }
                return
            }
        }

        if let cached = loadCache() {
            withAnimation(.easeInOut(duration: 0.35)) { payload = cached }
            withAnimation(.easeInOut(duration: 0.2)) { isLoading = false }
            return
        }

        // embeddedDefault already showing — nothing to update
        withAnimation(.easeInOut(duration: 0.2)) { isLoading = false }
    }

    private func fetch(remote: URL) async -> RoadmapPayload? {
        // 安全加固：① 仅允许 https；② 15s 超时；③ 256KB 上限——服务器声明超限即拒、流式下载超限即中断，
        // 防异常/恶意超大响应撑爆内存（DEBUG 下远程 URL 用户可改，且默认源走第三方 CDN）。
        guard remote.scheme?.lowercased() == "https" else { return nil }
        let maxBytes = 256 * 1024
        var request = URLRequest(url: remote)
        request.timeoutInterval = 15
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.expectedContentLength <= maxBytes else {   // -1（未知）放行，靠流式上限兜底
                return nil
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
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
