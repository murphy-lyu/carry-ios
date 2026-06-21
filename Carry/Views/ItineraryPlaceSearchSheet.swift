//
//  ItineraryPlaceSearchSheet.swift
//  Carry
//
//  行程内通用「地点搜索」sheet：交通起降站、住宿地址共用。
//  复用 StopSearchCompleter（定义在 AddStopView.swift）边输边补全，选中后回传
//  名称 + 坐标 + 地址。spec: itinerary-transport-lodging.md。
//

import SwiftUI
import MapKit

struct ItineraryPlaceSearchSheet: View {
    var titleKey: LocalizedStringKey
    var placeholderKey: LocalizedStringKey
    /// 行程目的地坐标，用于搜索区域偏置（可为 0/0）。
    var biasLatitude: Double = 0
    var biasLongitude: Double = 0
    var onSelect: (_ name: String, _ latitude: Double, _ longitude: Double, _ address: String, _ phone: String, _ timeZoneId: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = StopSearchCompleter()
    @State private var isResolving = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(completer.results) { result in
                    Button {
                        resolve(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                CarrySearchField(
                    text: $completer.query,
                    placeholder: placeholderKey,
                    focus: $searchFocused
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
            }
            .disabled(isResolving)
            .overlay { if isResolving { ProgressView() } }
            .navigationTitle(Text(titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .onAppear {
                completer.biasRegion(toLatitude: biasLatitude, longitude: biasLongitude)
                // 聚焦推迟到下一帧：sheet 呈现更新周期内同步设 @FocusState 会触发 AttributeGraph 崩溃。
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    private func resolve(_ suggestion: PlaceSuggestion) {
        isResolving = true
        Task {
            let r = await completer.resolve(suggestion)   // 国内走 MapKit、海外走 Worker;两源同构
            isResolving = false
            guard let r else { dismiss(); return }
            onSelect(r.name, r.latitude, r.longitude, r.address, r.phone, r.timeZoneId)
            dismiss()
        }
    }
}
