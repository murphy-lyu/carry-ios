//
//  AddStopView.swift
//  Carry
//
//  添加停靠点：地理搜索（MKLocalSearchCompleter 边输边补全）选 POI 入库，
//  或手动输名添加「无坐标停靠点」。spec: itinerary-route-planning.md。
//

import SwiftUI
import MapKit
import Combine

// MARK: - Search completer

/// 包装 MKLocalSearchCompleter，把补全结果发布给 SwiftUI。
@MainActor
final class StopSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { completer.queryFragment = query }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// 用行程目的地坐标做区域偏置，让搜索结果更贴近目的地。
    func biasRegion(toLatitude lat: Double, longitude lon: Double) {
        guard lat != 0 || lon != 0 else { return }
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5)
        )
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

// MARK: - AddStopView

struct AddStopView: View {
    let tripId: UUID
    let dayId: UUID
    /// 行程目的地坐标，用于搜索区域偏置（可为 0/0）。
    var biasLatitude: Double = 0
    var biasLongitude: Double = 0

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var completer = StopSearchCompleter()
    @State private var category: StopCategory = .other
    @State private var isResolving = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    categoryPicker
                }

                Section {
                    if completer.results.isEmpty && !completer.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 无补全结果时提供「手动添加无地点停靠点」入口。
                        Button {
                            addManualStop()
                        } label: {
                            Label {
                                Text(String(format: NSLocalizedString("itinerary.add_stop.manual", comment: ""), completer.query))
                            } icon: {
                                Image(systemName: "mappin.slash")
                            }
                        }
                    }
                    ForEach(completer.results, id: \.self) { result in
                        Button {
                            resolveAndAdd(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    if !completer.results.isEmpty {
                        Text("itinerary.add_stop.results")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 自定义常驻搜索框（替代 .searchable）：点击只弹键盘，不切换导航栏形态、不变背景。
            .safeAreaInset(edge: .top) { searchField }
            .disabled(isResolving)
            .overlay { if isResolving { ProgressView() } }
            .navigationTitle(Text("itinerary.add_stop.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .onAppear {
                completer.biasRegion(toLatitude: biasLatitude, longitude: biasLongitude)
                searchFocused = true   // 进入即聚焦，键盘就绪可直接输入
            }
        }
    }

    /// 常驻搜索框：放大镜 + 输入框 + 清除按钮，固定在导航栏下方。
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(text: $completer.query) {
                Text("itinerary.add_stop.search_placeholder")
            }
            .focused($searchFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            if !completer.query.isEmpty {
                Button {
                    completer.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 用与列表卡片一致的分组背景（浅色=白 / 深色=深灰），与外层 systemGroupedBackground
        // 形成对比，搜索框有清晰可见的边界——切勿用 secondarySystemBackground（浅色下与外层同灰、隐形）。
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var categoryPicker: some View {
        Picker(selection: $category) {
            ForEach(StopCategory.allCases, id: \.self) { cat in
                Label(cat.titleKey, systemImage: cat.symbolName).tag(cat)
            }
        } label: {
            Text("itinerary.add_stop.category")
        }
        .tint(CarryAccent.color)
    }

    /// 解析补全项的真实坐标后入库。解析失败则退回无坐标停靠点（仍保留名字）。
    private func resolveAndAdd(_ completion: MKLocalSearchCompletion) {
        isResolving = true
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            Task { @MainActor in
                isResolving = false
                let item = response?.mapItems.first
                let coord = item?.placemark.coordinate
                let address = item?.placemark.title ?? completion.subtitle
                store.addItineraryStop(
                    tripId: tripId,
                    dayId: dayId,
                    name: completion.title,
                    latitude: coord?.latitude ?? 0,
                    longitude: coord?.longitude ?? 0,
                    address: address,
                    category: category
                )
                dismiss()
            }
        }
    }

    private func addManualStop() {
        let name = completer.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addItineraryStop(tripId: tripId, dayId: dayId, name: name, category: category)
        dismiss()
    }
}
