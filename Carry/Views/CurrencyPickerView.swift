//
//  CurrencyPickerView.swift
//  Carry
//
//  本位币选择器（spec: itinerary-cost-tracking.md）。
//  全屏可搜索 + 顶部「建议」分区（本位币 + 行程目的地币种），收掉百项列表的认知负担。
//  币种名走 Locale，不进 xcstrings。
//

import SwiftUI

struct CurrencyPickerView: View {
    /// 纯选择回调；nil = 本位币模式（写 AppStorage + 重算快照）。非 nil = 选择模式（回传 code、无副作用），
    /// 给「费用记录」每笔选币种用。
    var onPick: ((String) -> Void)? = nil
    /// 选择模式下的当前选中 code（用于打勾）；本位币模式忽略，用 AppStorage。
    var selectedCode: String? = nil

    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExchangeRateManager.preferredCurrencyDefaultsKey) private var preferredCurrencyRaw = ""
    @State private var searchText = ""

    /// 本位币（设备默认 / 用户选定）。
    private var homeCode: String {
        preferredCurrencyRaw.isEmpty ? CurrencyCatalog.deviceDefaultCode : preferredCurrencyRaw.uppercased()
    }

    /// 当前打勾项：选择模式用 selectedCode，本位币模式用 homeCode。
    private var currentCode: String {
        if onPick != nil { return (selectedCode ?? "").uppercased() }
        return homeCode
    }

    private var navTitleKey: LocalizedStringKey {
        onPick != nil ? "cost.currency.title" : "settings.currency.title"
    }

    /// 建议分区：本位币 + 用户所有行程目的地国家对应的币种（去重，保序）。
    private var suggestedCodes: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ code: String) {
            let c = code.uppercased()
            guard !c.isEmpty, seen.insert(c).inserted else { return }
            result.append(c)
        }
        add(homeCode)
        for trip in store.trips {
            if let info = CurrencyCatalog.info(for: trip.countryCode) { add(info.code) }
        }
        return result
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private func matches(_ code: String, _ query: String) -> Bool {
        let lc = query.lowercased()
        return code.lowercased().contains(lc)
            || CurrencyCatalog.localizedName(for: code).lowercased().contains(lc)
    }

    private var filteredAll: [String] {
        let q = trimmedQuery
        guard !q.isEmpty else { return CurrencyCatalog.allCodes }
        return CurrencyCatalog.allCodes.filter { matches($0, q) }
    }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                Section(header: Text("settings.currency.suggested")) {
                    ForEach(suggestedCodes, id: \.self) { row($0) }
                }
                Section(header: Text("settings.currency.all")) {
                    ForEach(CurrencyCatalog.allCodes, id: \.self) { row($0) }
                }
            } else if filteredAll.isEmpty {
                Text("settings.currency.no_results")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredAll, id: \.self) { row($0) }
            }
        }
        .searchable(text: $searchText, prompt: Text("settings.currency.search"))
        .navigationTitle(Text(navTitleKey))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 选择模式（费用录入弹出的 sheet）才补「取消」——它没有返回箭头，原本只能下拉关闭、
            // 与全 app sheet 约定不一致。本位币模式是 push（有系统返回箭头），不加以免双重冗余。
            if onPick != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ code: String) -> some View {
        Button {
            select(code)
        } label: {
            HStack(spacing: 14) {
                Text(CurrencyCatalog.symbol(for: code))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CurrencyCatalog.localizedName(for: code))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(code)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if code == currentCode {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(CarryAccent.color)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 选定币种。选择模式：回传 code、无副作用。本位币模式：写存储 → 切 base → 拉汇率 → 重算快照。
    private func select(_ code: String) {
        let upper = code.uppercased()
        if let onPick {
            onPick(upper)
            dismiss()
            return
        }
        guard upper != currentCode else { dismiss(); return }
        preferredCurrencyRaw = upper
        if ExchangeRateManager.shared.refreshBaseCurrency() {
            CarryLogger.shared.log(.preferredCurrencyChanged, context: "code=\(upper)")
            Task {
                await ExchangeRateManager.shared.fetchNow()
                store.recomputeCostSnapshots()
            }
        }
        dismiss()
    }
}
