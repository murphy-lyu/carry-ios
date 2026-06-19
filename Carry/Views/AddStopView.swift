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
    /// 非 nil = relocate 模式：选中结果更新该停靠点的坐标/地址/名称，而非新增。
    var relocateStopId: UUID? = nil
    /// relocate 成功后回传新名称（供调用方同步显示）。
    var onRelocated: ((String) -> Void)? = nil

    private var isRelocating: Bool { relocateStopId != nil }

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
            // 统一整屏底色：不依赖 List 在 sheet 里的隐式分组底（实测会渲染成白、与下方搜索框
            // band 的 systemGroupedBackground 割裂）。显式铺一层 grouped 底，让 band 与列表区
            // 共用同一表面，接缝从根上消除。
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            // 自定义常驻搜索框（替代 .searchable）：点击只弹键盘，不切换导航栏形态、不变背景。
            .safeAreaInset(edge: .top) { searchField }
            .disabled(isResolving)
            .overlay { if isResolving { ProgressView() } }
            .navigationTitle(Text(isRelocating ? "itinerary.stop.edit.relocate" : "itinerary.add_stop.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .onAppear {
                completer.biasRegion(toLatitude: biasLatitude, longitude: biasLongitude)
                // 聚焦推迟到下一帧：在 sheet 呈现的更新周期内同步设置 @FocusState 会触发
                // AttributeGraph「setting value during update」硬崩溃；且延后设置程序化聚焦更可靠。
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    /// 常驻搜索框：统一 CarrySearchField（.grouped 表面），尾部收进类别菜单，固定在导航栏下方。
    private var searchField: some View {
        CarrySearchField(
            text: $completer.query,
            placeholder: "itinerary.add_stop.search_placeholder",
            focus: $searchFocused
        ) {
            // relocate 模式只换位置、不改类别，故隐藏类别菜单。
            if !isRelocating {
                Divider()
                    .frame(height: 18)
                categoryMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    /// 类别收进搜索框尾部的紧凑 Menu：当前类别图标，一点切换。
    /// 加地点的主任务是搜索，类别是次要属性 → 退出结果上方、不挤占首屏（north-star §2）。
    private var categoryMenu: some View {
        Menu {
            Picker(selection: $category) {
                // 仅在地体验 + 住宿 + 兜底；交通类（航班/火车/租车/邮轮）走统一「+」交通入口。
                // spec: itinerary-car-rental.md。
                ForEach(StopCategory.placeSelectableCases, id: \.self) { cat in
                    Label(cat.titleKey, systemImage: cat.symbolName).tag(cat)
                }
            } label: {
                Text("itinerary.add_stop.category")
            }
        } label: {
            Image(systemName: category.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(CarryAccent.color)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .tint(CarryAccent.color)
        .accessibilityLabel(Text("itinerary.add_stop.category"))
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
                if let relocateStopId {
                    // relocate：更新本停靠点的坐标/地址/名称，类别保持不变。
                    store.updateItineraryStop(
                        tripId: tripId,
                        stopId: relocateStopId,
                        name: completion.title,
                        latitude: coord?.latitude ?? 0,
                        longitude: coord?.longitude ?? 0,
                        address: address
                    )
                    onRelocated?(completion.title)
                } else {
                    store.addItineraryStop(
                        tripId: tripId,
                        dayId: dayId,
                        name: completion.title,
                        latitude: coord?.latitude ?? 0,
                        longitude: coord?.longitude ?? 0,
                        address: address,
                        category: category
                    )
                }
                dismiss()
            }
        }
    }

    private func addManualStop() {
        let name = completer.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let relocateStopId {
            // relocate 到无坐标地点：改名并清空坐标/地址（变回「无定位停靠点」）。
            store.updateItineraryStop(
                tripId: tripId, stopId: relocateStopId,
                name: name, latitude: 0, longitude: 0, address: ""
            )
            onRelocated?(name)
        } else {
            store.addItineraryStop(tripId: tripId, dayId: dayId, name: name, category: category)
        }
        dismiss()
    }
}
