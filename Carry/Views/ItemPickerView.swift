//
//  ItemPickerView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - Data

private struct ItemPickerCategory {
    let name: String
    let items: [String]
}

private struct PickerItemID: Hashable {
    let category: String
    let item: String
}

private let itemPickerCatalog: [ItemPickerCategory] = [
    ItemPickerCategory(name: "Documents", items: [
        // 证件核心 → 预订凭证 → 驾驶相关 → 地区通行证 → 健康证明
        "Passport", "ID card", "Visa",
        "Hotel booking", "Travel insurance", "Itinerary",
        "Driver's license", "International driving permit",
        "HK & Macao permit", "Taiwan permit",
        "Vaccination certificate",
    ]),
    ItemPickerCategory(name: "Clothing", items: [
        // 人人必带基础 → 日常上下装 → 中间层 → 女性专属 → 特定场景
        "Underwear", "Socks",
        "T-shirt", "Jeans", "Pajamas",
        "Shorts", "Sweater", "Hoodie", "Cardigan", "Shirt",
        "Dress", "Skirt", "Bra", "Sports bra", "Tights", "Leggings", "Nipple covers",
        "Disposable underwear", "Swimsuit", "Formal wear", "Rain jacket", "Hat", "Belt",
    ]),
    ItemPickerCategory(name: "Jewellery", items: [
        // 日常高频 → 叠搭配件
        "Earrings", "Necklace", "Ring", "Bracelet", "Watch", "Hair clip",
    ]),
    ItemPickerCategory(name: "Electronics", items: [
        // 充电/供电（全员必备）→ 音频 → 电脑/平板 → 摄影 → 配件
        "Phone charger", "Charging cable", "Portable charger", "Smart watch charger", "Travel adapter",
        "Earphones", "Noise-cancelling headphones",
        "Tablet", "Laptop", "Laptop charger", "E-reader",
        "Camera", "Camera charger", "Pocket camera", "Action camera", "Drone", "Memory card",
        "Selfie stick", "Tripod", "Power strip", "Portable WiFi device", "Bluetooth speaker",
    ]),
    ItemPickerCategory(name: "Travel Accessories", items: [
        // 钱/证件载体 → 日常随身 → 飞机/长途舒适 → 整理辅助
        "Wallet", "Cash", "Card holder",
        "Sunglasses", "Umbrella", "Water bottle",
        "Travel pillow", "Eye mask", "Earplugs",
        "Pen", "Packing cubes", "Laundry bag", "Travel towel",
    ]),
    ItemPickerCategory(name: "Toiletries", items: [
        // 按固定护肤顺序优先，其余放后
        "Makeup remover / cleansing oil", "Cotton pads", "Face wash", "Face mask", "Toner", "Serum", "Eye cream", "Facial oil", "Lotion", "Moisturiser",
        "Body lotion",
        "Lip balm", "Sunscreen",
        "Hair ties", "Comb", "Hair straightener", "Dry shampoo", "Perfume",
        "Dental floss", "Toothbrush", "Toothpaste", "Mouthwash",
        "Shampoo", "Conditioner", "Body wash",
        "Razor", "Nail clippers",
        "Acne patches", "Deodorant",
    ]),
    ItemPickerCategory(name: "Makeup", items: [
        // 功能性（隐形眼镜）→ 高频基础妆 → 眼妆 → 修容 → 定妆 → 工具
        "Contact lenses",
        "Concealer", "Foundation", "Mascara", "Eyebrow pencil", "Lipstick / Lip gloss",
        "Eyeliner", "Blush", "Highlighter",
        "Primer", "Setting powder", "Eyeshadow",
        "Eyelash curler", "False eyelashes",
        "Makeup brushes", "Makeup sponge",
        "Colored contacts",
    ]),
    ItemPickerCategory(name: "Health & Wellness", items: [
        // 处方药优先 → 常备OTC → 旅行高发症状 → 卫生防护 → 女性用品 → 保健品
        "Prescription medication",
        "Painkillers", "Cold & flu medicine", "Stomach medicine", "Anti-diarrhea",
        "Motion sickness tablets", "Antihistamines",
        "Hand sanitiser", "Disposable face masks", "First aid kit",
        "Eye drops", "Throat lozenges",
        "Feminine hygiene products", "Birth control pills", "Condoms",
        "Melatonin", "Multivitamins", "Vitamin C", "Vitamin D", "Probiotics",
    ]),
    ItemPickerCategory(name: "Leisure", items: [
        // 阅读 → 零食/即食 → 社交/娱乐
        "Book",
        "Gum", "Instant coffee", "Tea bags",
        "Travel board game",
    ]),
    ItemPickerCategory(name: "Winter Travel", items: [
        // 外层保暖 → 基础层 → 四肢保暖 → 辅助保暖
        "Wool coat", "Thermal underwear",
        "Gloves", "Beanie", "Scarf",
        "Snow boots",
        "Hand warmers", "Heat patches",
    ]),
    ItemPickerCategory(name: "Beach & Outdoor", items: [
        // 沙滩必带 → 水上活动 → 户外/徒步
        "Flip flops", "Beach towel", "Rash guard", "Swimming goggles", "Waterproof bag",
        "Insect repellent", "Hiking boots", "Trekking poles",
    ]),
]

// MARK: - ItemPickerView

struct ItemPickerView: View {

    private enum Mode {
        case create(TripInfo)
        case merge(tripId: UUID)
    }

    private let mode: Mode
    private let startInMyItems: Bool

    init(tripInfo: TripInfo, startInMyItems: Bool = false) {
        self.mode = .create(tripInfo)
        self.startInMyItems = startInMyItems
    }

    init(tripId: UUID) {
        self.mode = .merge(tripId: tripId)
        self.startInMyItems = false
    }

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var sourceMode: SourceMode = .preset
    @State private var selectedItems: Set<PickerItemID> = []
    @State private var selectedMyItemIDs: Set<UUID> = []
    @State private var expandedCategories: Set<String> = []
    @State private var showAutoPackSheet = false
    @State private var toastVisible = false
    @State private var toastText = ""
    @State private var didApplyInitialSource = false

    private var hasSelection: Bool {
        sourceMode == .preset ? !selectedItems.isEmpty : !selectedMyItemIDs.isEmpty
    }

    private var isCreateMode: Bool {
        if case .create = mode { return true }
        return false
    }

    private var tripInfoForAutoPack: TripInfo? {
        if case .create(let info) = mode { return info }
        return nil
    }

    private var myItemsCount: Int { store.myItems.count }

    private enum SourceMode: String, CaseIterable {
        case preset
        case myItems
    }

    private var tripDays: Int {
        switch mode {
        case .create(let info):
            return info.durationDays
        case .merge(let tripId):
            return store.bundle(for: tripId)?.days ?? 1
        }
    }

    private var filteredResults: [PickerItemID] {
        guard sourceMode == .preset else { return [] }
        guard !searchText.isEmpty else { return [] }
        let query = normalizedForSearch(searchText)
        return itemPickerCatalog.flatMap { cat in
            cat.items
                .filter { itemMatchesQuery($0, query: query) }
                .map { PickerItemID(category: cat.name, item: $0) }
        }
    }

    private func itemMatchesQuery(_ itemKey: String, query: String) -> Bool {
        let localized = NSLocalizedString(itemKey, comment: "")
        let raw = itemKey
        return normalizedForSearch(localized).contains(query) ||
               normalizedForSearch(raw).contains(query)
    }

    private func normalizedForSearch(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func myItemsSearchResults() -> [MyItem] {
        let query = normalizedForSearch(searchText)
        return store.myItems.filter {
            searchText.isEmpty
                || normalizedForSearch($0.name).contains(query)
                || normalizedForSearch($0.category).contains(query)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {

            // Large title — fixed, never collapses
            Text("Add items")
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Search bar — fixed, always accessible
            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            sourcePicker
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            if sourceMode == .myItems {
                myItemsHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            // Scrollable content
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                    if sourceMode == .preset {
                        if searchText.isEmpty {
                            ForEach(itemPickerCatalog, id: \.name) { category in
                                Section {
                                    if expandedCategories.contains(category.name) {
                                        categoryBody(category)
                                    }
                                } header: {
                                    categoryHeader(category)
                                }
                            }
                        } else {
                            if filteredResults.isEmpty {
                                Text("No results")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 48)
                            } else {
                                ForEach(filteredResults, id: \.self) { result in
                                    itemRow(result.item, category: result.category)
                                        .padding(.horizontal, 16)
                                }
                                .padding(.top, 4)
                            }
                        }
                    } else {
                        let myItems = myItemsSearchResults().sorted { lhs, rhs in
                            if lhs.sortOrder != rhs.sortOrder {
                                return lhs.sortOrder < rhs.sortOrder
                            }
                            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                        }
                        if myItems.isEmpty {
                            Text(searchText.isEmpty ? "myitems.empty.title" : "No results")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 48)
                        } else {
                            ForEach(myItems) { item in
                                myItemRow(item)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.bottom, isCreateMode ? 96 : 24)
            }
            .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        isSearchFocused = false
                        hideKeyboard()
                    }
                )
        }
        .contentShape(Rectangle())
        .background(Color.clear.contentShape(Rectangle()))
        .simultaneousGesture(
            TapGesture().onEnded {
                isSearchFocused = false
                hideKeyboard()
            }
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmSelection()
                } label: {
                    Label(sourceMode == .preset ? "Save" : "myitems.addToTrip", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .fontWeight(.semibold)
                .disabled(!hasSelection)
                .animation(.easeInOut(duration: 0.15), value: hasSelection)
            }
        }
        .overlay(alignment: .bottom) {
            if toastVisible {
                toastBanner
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isCreateMode {
                autoPackFAB
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showAutoPackSheet) {
            if let info = tripInfoForAutoPack {
                NavigationStack {
                    ScenePickerView(autoPackTripInfo: info, seedSections: buildSections())
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            guard !didApplyInitialSource else { return }
            didApplyInitialSource = true
            if startInMyItems {
                sourceMode = .myItems
            }
        }
    }

    private var sourcePicker: some View {
        HStack(spacing: 8) {
            ForEach(SourceMode.allCases, id: \.self) { mode in
                Button {
                    sourceMode = mode
                    searchText = ""
                    expandedCategories.removeAll()
                    selectedItems.removeAll()
                    isSearchFocused = false
                    hideKeyboard()
                } label: {
                    Text(mode == .preset ? LocalizedStringKey("myitems.source.preset") : LocalizedStringKey("myitems.source.mine"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(sourceMode == mode ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(sourceMode == mode ? Color(UIColor.secondarySystemBackground) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    private var myItemsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("myitems.title")
                    .font(.headline)
                Text("\(myItemsCount) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedMyItemIDs.isEmpty {
                Text("myitems.none_selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(String.localizedStringWithFormat(NSLocalizedString("myitems.selected_count", comment: ""), selectedMyItemIDs.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(UIColor.secondarySystemBackground)))
    }

    // MARK: - Auto Pack FAB

    private var autoPackGradient: AngularGradient {
        AngularGradient(
            colors: [
                Color(red: 1.0,   green: 0.42,  blue: 0.616), // #FF6B9D
                Color(red: 0.659, green: 0.333, blue: 0.969), // #A855F7
                Color(red: 0.231, green: 0.51,  blue: 0.965), // #3B82F6
                Color(red: 0.024, green: 0.714, blue: 0.831), // #06B6D4
                Color(red: 1.0,   green: 0.42,  blue: 0.616), // #FF6B9D
            ],
            center: .center
        )
    }

    private var autoPackFAB: some View {
        Button { showAutoPackSheet = true } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 20))
                .foregroundColor(.primary)
                .frame(width: 56, height: 56)
                .background {
                    ZStack {
                        Circle()
                            .fill(autoPackGradient)
                            .blur(radius: 8)
                            .opacity(0.5)
                        Circle()
                            .fill(Color(UIColor.systemBackground))
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(autoPackGradient, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
    }

    private func categoryHeaderText(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func myItemRow(_ item: MyItem) -> some View {
        let isSelected = selectedMyItemIDs.contains(item.id)
        return Button {
            if isSelected {
                selectedMyItemIDs.remove(item.id)
            } else {
                selectedMyItemIDs.insert(item.id)
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(isSelected ? Color.primary : Color.clear)
                    .overlay(
                        Circle().strokeBorder(isSelected ? Color.primary : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    )
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !item.category.isEmpty {
                        Text(item.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selectedMyItemIDs.contains(item.id) {
                    Text("✓")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text("\(item.defaultQuantity)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(UIColor.placeholderText))
                .font(.subheadline)
            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text("Search items...")
                        .font(.subheadline)
                        .foregroundColor(Color(UIColor.placeholderText))
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText)
                    .font(.subheadline)
                    .tint(.primary)
                    .focused($isSearchFocused)
            }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(UIColor.placeholderText))
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Category header (pinned)

    @ViewBuilder
    private func categoryHeader(_ category: ItemPickerCategory) -> some View {
        let isExpanded = expandedCategories.contains(category.name)
        let selectedCount = category.items.filter {
            selectedItems.contains(PickerItemID(category: category.name, item: $0))
        }.count

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedCategories.remove(category.name)
                } else {
                    expandedCategories.insert(category.name)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(LocalizedStringKey(category.name))
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(selectedCount)/\(category.items.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Category body (expanded items)

    @ViewBuilder
    private func categoryBody(_ category: ItemPickerCategory) -> some View {
        let selectedCount = category.items.filter {
            selectedItems.contains(PickerItemID(category: category.name, item: $0))
        }.count
        let allSelected = selectedCount == category.items.count

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if allSelected {
                    for item in category.items {
                        selectedItems.remove(PickerItemID(category: category.name, item: item))
                    }
                } else {
                    for item in category.items {
                        selectedItems.insert(PickerItemID(category: category.name, item: item))
                    }
                }
            }
        } label: {
            Text(allSelected ? "Deselect all" : "Select all")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)

        ForEach(category.items, id: \.self) { item in
            itemRow(item, category: category.name)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Item row

    private func itemRow(_ item: String, category: String) -> some View {
        let id = PickerItemID(category: category, item: item)
        let isSelected = selectedItems.contains(id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isSelected {
                    selectedItems.remove(id)
                } else {
                    selectedItems.insert(id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.primary : Color.clear)
                    Circle()
                        .strokeBorder(isSelected ? Color.primary : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(UIColor.systemBackground))
                    }
                }
                .frame(width: 24, height: 24)
                Text(LocalizedStringKey(item))
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toast

    private var toastBanner: some View {
        Text(toastText)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.black.opacity(0.88))
            .cornerRadius(20)
    }

    private func showToast(_ message: String) {
        toastText = message
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastVisible = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeIn(duration: 0.25)) {
                toastVisible = false
            }
        }
    }

    // MARK: - Actions

    private func confirmSelection() {
        let sections = sourceMode == .preset ? buildSections() : buildMyItemSections()
        guard !sections.isEmpty else { return }

        switch mode {
        case .create(let info):
            let bundle = TripBundle(
                name: info.name,
                destinationCity: info.destinationCity,
                days: info.durationDays,
                dateRange: info.dateRangeDisplay,
                departureDate: info.departureDate,
                selectedSceneKeys: [],
                sections: sections
            )
            store.addTrip(bundle)
            router.path.append(CreationRoute.packingList(bundle.id))

        case .merge(let tripId):
            store.mergeItems(tripId: tripId, sections: sections)
            router.path.removeLast()
        }
    }

    private func buildMyItemSections() -> [PackingSection] {
        let selected = store.myItems.filter { selectedMyItemIDs.contains($0.id) }
        var sectionsByTitle: [String: [MyItem]] = [:]
        for item in selected {
            let title = item.category.isEmpty ? "Essentials" : item.category
            sectionsByTitle[title, default: []].append(item)
        }

        var result: [PackingSection] = []
        for (index, title) in sectionsByTitle.keys.sorted().enumerated() {
            let items = sectionsByTitle[title, default: []].enumerated().map { idx, myItem in
                PackingItem(
                    name: myItem.name,
                    quantity: myItem.defaultQuantity,
                    isAlert: false,
                    sortOrder: idx
                )
            }
            result.append(PackingSection(title: title, items: items, sortOrder: index))
        }
        return result
    }

    private func selectedCurrentCount() -> Int {
        sourceMode == .preset ? selectedItems.count : selectedMyItemIDs.count
    }

    private func buildSections() -> [PackingSection] {
        var sectionIndex = 0
        var result: [PackingSection] = []
        for category in itemPickerCatalog {
            let items = category.items
                .filter { selectedItems.contains(PickerItemID(category: category.name, item: $0)) }
                .enumerated()
                .map { idx, name in
                    PackingItem(
                        name: name,
                        quantity: defaultQuantity(for: name, tripDays: tripDays),
                        isAlert: false,
                        sortOrder: idx
                    )
                }
            guard !items.isEmpty else { continue }
            result.append(PackingSection(title: category.name, items: items, sortOrder: sectionIndex))
            sectionIndex += 1
        }
        return result
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ItemPickerView(tripInfo: TripInfo())
    }
    .environmentObject(TripStore())
    .environmentObject(NavigationRouter())
}
