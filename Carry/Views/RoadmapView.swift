//
//  RoadmapView.swift
//  Carry
//

import SwiftUI

private enum RoadmapRemote {
    // Default remote URL. You can override this inside the app UI.
    static let urlString = "https://raw.githubusercontent.com/your-user/your-repo/main/roadmap.json"
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
        banner: "🚀 App Store 上线，2026年7月",
        sections: [
            RoadmapSection(
                id: "upcoming",
                title: "即将推出的更新",
                items: [
                    RoadmapItem(id: "ai-pack", title: "AI 打包建议", status: .inProgress, note: "部分功能需要 Luggage+"),
                    RoadmapItem(id: "collab", title: "协作旅行", status: .planned, note: nil),
                    RoadmapItem(id: "flight-hotel", title: "航班与酒店集成", status: .planned, note: nil),
                    RoadmapItem(id: "stats", title: "旅行统计", status: .planned, note: nil),
                ]
            ),
            RoadmapSection(
                id: "done",
                title: "已完成",
                items: [
                    RoadmapItem(id: "currency", title: "货币换算", status: .done, note: nil),
                    RoadmapItem(id: "todo", title: "旅行待办事项", status: .done, note: nil),
                    RoadmapItem(id: "notes", title: "旅行笔记", status: .done, note: nil),
                    RoadmapItem(id: "reminders", title: "旅行提醒", status: .done, note: nil),
                    RoadmapItem(id: "weather", title: "天气预报", status: .done, note: nil),
                    RoadmapItem(id: "plug", title: "插头类型信息", status: .done, note: nil),
                    RoadmapItem(id: "custom", title: "自定义打包清单", status: .done, note: nil),
                    RoadmapItem(id: "sorting", title: "物品与分类排序", status: .done, note: nil),
                ]
            ),
        ]
    )
}

@MainActor
private final class RoadmapViewModel: ObservableObject {
    @Published var payload: RoadmapPayload?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carry_roadmap_cache.json")
    }

    func load(from overrideURLString: String?) async {
        isLoading = true
        errorMessage = nil

        let remoteCandidates = [overrideURLString?.trimmingCharacters(in: .whitespacesAndNewlines), RoadmapRemote.urlString]
            .compactMap { $0 }
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

        // Always have a usable fallback so the page is never blank.
        payload = .embeddedDefault
        isLoading = false
        errorMessage = "Using built-in roadmap data."
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

struct RoadmapView: View {
    @StateObject private var vm = RoadmapViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("roadmap_remote_url") private var remoteURL = ""
    @State private var showSourceSheet = false
    @State private var draftURL = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("Roadmap")
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showSourceSheet) {
            NavigationStack {
                Form {
                    Section("Remote JSON URL") {
                        TextField("https://raw.githubusercontent.com/...", text: $draftURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("留空将使用内置默认数据；填入后会优先拉取远程。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Roadmap Source")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSourceSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            remoteURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            showSourceSheet = false
                            Task { await vm.load(from: remoteURL) }
                        }
                    }
                }
            }
        }
        .task { await vm.load(from: remoteURL) }
        .refreshable { await vm.load(from: remoteURL) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Product Roadmap")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            if let banner = vm.payload?.banner, !banner.isEmpty {
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
            if let updatedAt = vm.payload?.updatedAt, !updatedAt.isEmpty {
                Text("Updated: \(updatedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.payload == nil {
            ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
        } else if let payload = vm.payload {
            ForEach(payload.sections) { section in
                sectionBlock(section)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(vm.errorMessage ?? "Roadmap unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Tap top-right link icon to configure your GitHub raw JSON URL.")
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
}

#Preview {
    NavigationStack {
        RoadmapView()
    }
}
