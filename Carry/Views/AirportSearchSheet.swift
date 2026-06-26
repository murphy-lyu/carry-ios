//
//  AirportSearchSheet.swift
//  Carry
//
//  航班出发/到达机场选点：检索内置机场数据库（AirportDatabase），选中后回传
//  机场名 / IATA / 坐标 / IANA 时区。全球可搜，不受地图供应商或设备区域限制。
//  spec: itinerary-airport-search.md。
//
//  与通用地点搜索（ItineraryPlaceSearchSheet，走 MapKit）分离——机场是封闭集合，
//  强约束到数据库内，保证 IATA / 时区完整。
//

import SwiftUI
import Combine

/// 驱动机场检索：query 变化 → 防抖 → 调 AirportDatabase（actor，后台执行）→ 回到主线程发布结果。
@MainActor
private final class AirportSearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Airport] = []

    private var task: Task<Void, Never>?

    func runSearch() {
        task?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000) // 防抖
            guard !Task.isCancelled else { return }
            let found = await AirportDatabase.shared.search(q)
            guard !Task.isCancelled else { return }
            self?.results = found
        }
    }
}

struct AirportSearchSheet: View {
    var titleKey: LocalizedStringKey
    var onSelect: (_ airport: Airport) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AirportSearchModel()
    @State private var searchFocused: Bool = false   // 普通 Bool：CarrySearchField 内部走 UITextField，焦点不能用 @FocusState（见 IMESafeTextField）

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.results) { airport in
                    Button {
                        onSelect(airport)
                        dismiss()
                    } label: {
                        row(airport)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .overlay { emptyState }
            .safeAreaInset(edge: .top) {
                CarrySearchField(
                    text: $model.query,
                    placeholder: "airport.search.placeholder",
                    focus: $searchFocused
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle(Text(titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .onChange(of: model.query) { _, _ in model.runSearch() }
            .onAppear {
                // 聚焦推迟到下一帧：sheet 呈现更新周期内同步设 @FocusState 会触发 AttributeGraph 崩溃。
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    /// 行：IATA 角标（圆体短标签）+ 机场名 + 「城市, 国家」副标题。
    private func row(_ airport: Airport) -> some View {
        HStack(spacing: 12) {
            Text(airport.iata)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(airport.displayName)
                    .foregroundStyle(.primary)
                if !airport.city.isEmpty {
                    Text(verbatim: "\(airport.city), \(airport.country)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = model.query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            ContentUnavailableView {
                Label("airport.search.hint.title", systemImage: "airplane.departure")
            } description: {
                Text("airport.search.hint.subtitle")
            }
        } else if model.results.isEmpty {
            ContentUnavailableView {
                Label("airport.search.empty.title", systemImage: "magnifyingglass")
            } description: {
                Text("airport.search.empty.subtitle")
            }
        }
    }
}
