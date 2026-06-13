//
//  ItemPickerView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - Data

private struct PickerItemID: Hashable {
    let category: String
    let item: String
}

private enum SearchResultSource {
    case base
    case custom
}

private struct SearchResultItem: Identifiable, Hashable {
    let id = UUID()
    let source: SearchResultSource
    let title: String
    let category: String?
    let itemID: PickerItemID?
    let myItem: MyItem?
    let isAlreadyAdded: Bool
}

private let smartSceneSymbols: [String: String] = [
    "🚗 Road trip":            "car.fill",
    "✈️ Long-haul flight":     "airplane",
    "🚢 Cruise":               "ferry.fill",
    "☀️ Tropical / beach":     "sun.max.fill",
    "🌧 Rainy city":           "cloud.rain.fill",
    "⛰ High altitude":        "mountain.2.fill",
    "❄️ Winter / cold":        "snowflake",
    "💼 Business":             "briefcase.fill",
    "💻 Remote work":          "laptopcomputer",
    "👶 Travelling with kids": "figure.and.child.holdinghands",
    "🥾 Hiking / camping":     "tent.fill",
    "💍 Honeymoon":            "heart.fill",
    "🎒 Backpacking":          "backpack.fill",
    "🏨 City break":           "building.2.fill",
    "🌸 On / near period":     "leaf.fill",
    "💊 Daily medication":     "pill.fill",
]

// MARK: - ItemPickerView

struct ItemPickerView: View {

    private enum Mode {
        case create(TripInfo)
        case merge(tripId: UUID)
        case autoPackReview(TripInfo, sceneKeys: [String])
    }

    private let mode: Mode
    private let startInMyItems: Bool
    private let cachedSceneRecommendedNames: Set<String>
    @State private var appliedSceneRecommendedNames: Set<String> = []
    @State private var lastAppliedSceneLabels: Set<String> = []

    init(tripInfo: TripInfo, startInMyItems: Bool = false) {
        self.mode = .create(tripInfo)
        self.startInMyItems = startInMyItems
        self.cachedSceneRecommendedNames = []
    }

    init(tripId: UUID) {
        self.mode = .merge(tripId: tripId)
        self.startInMyItems = false
        self.cachedSceneRecommendedNames = []
    }

    init(autoPackTripInfo: TripInfo, sceneKeys: [String], isInternational: Bool? = nil, destinationCodes: [String] = []) {
        self.mode = .autoPackReview(autoPackTripInfo, sceneKeys: sceneKeys)
        self.startInMyItems = false

        // Pre-select items generated from scenes, matched back to catalog raw keys
        let generated = generatePackingSections(selectedScenes: sceneKeys, tripDays: autoPackTripInfo.durationDays, isInternational: isInternational, destinationCodes: destinationCodes)
        let generatedByCategory: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: generated.map { section in
                (section.title, Set(section.sortedItems.map { $0.name }))
            }
        )
        // Cache recommended names once — sceneKeys never change during this view's lifetime
        self.cachedSceneRecommendedNames = Set(generated.flatMap { $0.sortedItems.map { canonicalItemName($0.name) } })

        var preselected = Set<PickerItemID>()
        for category in itemPickerCatalog {
            let generatedNames = generatedByCategory[category.name] ?? []
            for rawKey in category.items {
                if generatedNames.contains(canonicalItemName(rawKey)) {
                    preselected.insert(PickerItemID(category: category.name, item: rawKey))
                }
            }
        }
        self._selectedItems = State(initialValue: preselected)

        // Auto-expand categories that have pre-selected items so user can see recommendations
        let expandedCats = Set(itemPickerCatalog
            .filter { category in
                category.items.contains { rawKey in
                    preselected.contains(PickerItemID(category: category.name, item: rawKey))
                }
            }
            .map { $0.name }
        )
        self._expandedCategories = State(initialValue: expandedCats)
    }

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var sourceMode: SourceMode = .preset
    @State private var selectedItems: Set<PickerItemID> = []
    @State private var selectedMyItemIDs: Set<UUID> = []
    @State private var expandedCategories: Set<String> = []
    @State private var selectedSmartSceneLabels: Set<String> = []
    @State private var toastVisible = false
    @State private var toastText = ""
    @State private var didApplyInitialSource = false
    @State private var showMyItemAddSheet = false
    @State private var selectedMyItemCollection: String = "Default"
    @State private var didLogSearch = false
    @State private var isConfirmingSelection = false
    @AppStorage("itempicker.last_source_mode") private var lastSourceModeRawValue: String = SourceMode.smart.rawValue
    /// 「经期打包提醒」总开关（设置内，默认关）。关闭时不跑预测、不触碰 HealthKit。
    @AppStorage("cycleNudgeFeatureEnabled") private var cycleNudgeFeatureEnabled = false
    @State private var cycleNudgeActive = false
    @State private var didRunCyclePrediction = false

    private var existingItemNames: Set<String> {
        guard case .merge(let tripId) = mode,
              let bundle = store.bundle(for: tripId) else { return [] }

        return Set(bundle.safeSections.flatMap { $0.items ?? [] }.map { normalizedItemName($0.name) })
    }

    private var hasSelection: Bool {
        !selectedItems.isEmpty || !selectedMyItemIDs.isEmpty
    }

    private var canConfirm: Bool {
        hasSelection || (sourceMode == .smart && !selectedSmartSceneLabels.isEmpty)
    }

    private var isCreateMode: Bool {
        switch mode {
        case .create, .autoPackReview: return true
        case .merge: return false
        }
    }

    private var isAutoPackReview: Bool {
        if case .autoPackReview = mode { return true }
        return false
    }

    private var currentSceneKeys: [String] {
        if case .autoPackReview(_, let keys) = mode { return keys }
        return []
    }

    private var sceneRecommendedNames: Set<String> {
        cachedSceneRecommendedNames.isEmpty ? appliedSceneRecommendedNames : cachedSceneRecommendedNames
    }

    private var myItemsCount: Int { store.myItems.count }

    private var savedMyItemNames: Set<String> {
        Set(store.myItems.map { normalizedItemName($0.name) })
    }

    private func savedMyItemID(for name: String) -> UUID? {
        store.myItems.first {
            normalizedItemName($0.name) == normalizedItemName(name)
        }?.id
    }

    private static let presetCategoryOrder: [String: Int] =
        Dictionary(uniqueKeysWithValues: itemPickerCatalog.enumerated().map { ($1.name, $0) })

    private static let presetItemOrderByCategory: [String: [String: Int]] =
        Dictionary(uniqueKeysWithValues: itemPickerCatalog.map { category in
            let itemOrder = Dictionary(uniqueKeysWithValues: category.items.enumerated().map { ($1, $0) })
            return (category.name, itemOrder)
        })

    private enum SourceMode: String, CaseIterable {
        case preset
        case myItems
        case smart
    }

    private static let periodSceneKey = "personal_period"

    /// 经期场景 chip 的展示标签（"🌸 On / near period"），从 key 反查，避免硬编码。
    private var periodSceneLabel: String? {
        sceneLabelToKey.first(where: { $0.value == Self.periodSceneKey })?.key
    }

    /// 二次添加（merge）时，行程创建阶段已应用过的场景 key。这些不再重复推荐。
    /// 创建 / autoPack 模式下为空（尚无已应用场景）。
    private var alreadyAppliedSceneKeys: Set<String> {
        guard case .merge(let tripId) = mode, let bundle = store.bundle(for: tripId) else { return [] }
        return Set(bundle.selectedSceneKeys)
    }

    /// 基于目的地（+ 出发日期）推断的气候场景标签。
    /// 与 ScenePickerView 的气候推荐同源；新建流程的目的地码同步推断即可，无需等待异步回填。
    /// 注意：不按"是否已选"过滤——推荐项被上移到顶部唯一展示，选中后仍留在顶部（显示选中态）。
    /// 但 merge 模式会排除创建时已应用过的场景，避免二次添加时重复推荐。
    private var climateSuggestedLabels: [String] {
        guard let primaryCode = tripDestinationCodes.first(where: { !$0.isEmpty }),
              let range = tripDateRange else { return [] }
        let inferred = ClimateInference.inferredSceneKeys(countryCode: primaryCode, departureDate: range.start)
        let applied = alreadyAppliedSceneKeys
        return inferred
            .filter { !applied.contains($0) }
            .compactMap { key in sceneLabelToKey.first(where: { $0.value == key })?.key }
    }

    /// 是否推荐经期场景：预测命中，且（merge 模式下）该场景未在创建时被应用过。
    private var shouldNudgePeriod: Bool {
        cycleNudgeActive && !alreadyAppliedSceneKeys.contains(Self.periodSceneKey)
    }

    /// 被上移到顶部「Suggested」区的场景标签集合（气候 + 经期）。
    /// 这些标签需从下方固定分组中排除，保证"一个场景一个位置"，不重复展示。
    private var promotedSceneLabels: Set<String> {
        var set = Set(climateSuggestedLabels)
        if shouldNudgePeriod, let period = periodSceneLabel { set.insert(period) }
        return set
    }

    /// 跨 mode 提取行程日期区间，供经期/气候推荐使用。
    /// 无日期「规划中」行程返回 nil → 经期预测与气候推荐（都依赖此区间）一并自动跳过。
    private var tripDateRange: (start: Date, end: Date)? {
        let cal = Calendar.current
        switch mode {
        case .create(let info), .autoPackReview(let info, _):
            guard !info.isDateless else { return nil }
            return (cal.startOfDay(for: info.departureDate), cal.startOfDay(for: info.returnDate))
        case .merge(let tripId):
            guard let bundle = store.bundle(for: tripId), !bundle.isDateless else { return nil }
            let start = cal.startOfDay(for: bundle.departureDate)
            guard let end = cal.date(byAdding: .day, value: max(0, bundle.days), to: start) else { return nil }
            return (start, end)
        }
    }

    private var tripDays: Int {
        switch mode {
        case .create(let info):
            return info.durationDays
        case .autoPackReview(let info, _):
            return info.durationDays
        case .merge(let tripId):
            return store.bundle(for: tripId)?.days ?? 1
        }
    }

    private var tripIsInternational: Bool? {
        switch mode {
        case .create(let info):
            return store.inferIsInternational(for: info.destinationCity)
        case .autoPackReview(let info, _):
            return store.inferIsInternational(for: info.destinationCity)
        case .merge(let tripId):
            guard let bundle = store.bundle(for: tripId) else { return nil }
            return bundle.isInternational ?? store.inferIsInternational(for: bundle.destinationCity)
        }
    }

    private var tripDestinationCodes: [String] {
        switch mode {
        case .create(let info):
            return store.inferCountryCodes(for: info.destinationCity)
        case .autoPackReview(let info, _):
            return store.inferCountryCodes(for: info.destinationCity)
        case .merge(let tripId):
            guard let bundle = store.bundle(for: tripId) else { return [] }
            let stored = ([bundle.countryCode] + bundle.additionalDestinations.map(\.countryCode)).filter { !$0.isEmpty }
            return stored.isEmpty ? store.inferCountryCodes(for: bundle.destinationCity) : stored
        }
    }

    private var baseSearchResults: [SearchResultItem] {
        guard !searchText.isEmpty else { return [] }
        let query = normalizedForSearch(searchText)
        return itemPickerCatalog.flatMap { cat in
            cat.items
                .filter { itemMatchesQuery($0, query: query) }
                .map {
                    SearchResultItem(
                        source: .base,
                        title: canonicalItemName($0),
                        category: cat.name,
                        itemID: PickerItemID(category: cat.name, item: canonicalItemName($0)),
                        myItem: nil,
                        isAlreadyAdded: existingItemNames.contains(normalizedItemName($0))
                    )
                }
        }
        .sorted { lhs, rhs in
            searchRank(for: lhs, query: query) < searchRank(for: rhs, query: query)
        }
    }

    private func itemMatchesQuery(_ itemKey: String, query: String) -> Bool {
        searchableTerms(for: itemKey).contains {
            normalizedForSearch($0).contains(query)
        }
    }

    private func normalizedForSearch(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchableTerms(for itemKey: String) -> [String] {
        let canonical = canonicalItemName(itemKey)
        let currentLanguageValue = NSLocalizedString(canonical, comment: "")
        return ItemPickerView.localizedSearchTermsByItem[canonical] ?? [
            canonical,
            itemKey,
            currentLanguageValue
        ]
    }

    private static let localizedSearchTermsByItem: [String: [String]] = {
        var lookup: [String: Set<String>] = [:]
        let bundle = Bundle.main
        let localizationFolders = Set(bundle.localizations + ["Base"])

        for category in itemPickerCatalog {
            for item in category.items {
                let canonical = canonicalItemName(item)
                var terms: Set<String> = [canonical, item, NSLocalizedString(canonical, comment: "")]

                for localization in localizationFolders {
                    guard let path = bundle.path(forResource: localization, ofType: "lproj"),
                          let localizedBundle = Bundle(path: path) else { continue }
                    let translated = localizedBundle.localizedString(forKey: canonical, value: nil, table: nil)
                    terms.insert(translated)
                }

                lookup[canonical, default: []].formUnion(terms)
            }
        }

        return lookup.mapValues { Array($0) }
    }()

    private var customSearchResults: [SearchResultItem] {
        let query = normalizedForSearch(searchText)
        return store.myItems().filter {
            searchText.isEmpty
                || normalizedForSearch($0.name).contains(query)
                || normalizedForSearch($0.category).contains(query)
        }
        .map {
            SearchResultItem(
                source: .custom,
                title: $0.name,
                category: $0.category,
                itemID: nil,
                myItem: $0,
                isAlreadyAdded: existingItemNames.contains(normalizedItemName($0.name))
            )
        }
        .sorted { lhs, rhs in
            searchRank(for: lhs, query: query) < searchRank(for: rhs, query: query)
        }
    }

    private var orderedSearchResults: [SearchResultItem] {
        guard !searchText.isEmpty else { return [] }
        let results: [SearchResultItem]
        switch sourceMode {
        case .preset:
            results = baseSearchResults
        case .myItems:
            results = customSearchResults
        case .smart:
            results = []
        }
        return results.sorted { lhs, rhs in
            let query = normalizedForSearch(searchText)
            let lhsRank = searchRank(for: lhs, query: query)
            let rhsRank = searchRank(for: rhs, query: query)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func searchRank(for result: SearchResultItem, query: String) -> Int {
        let terms: [String]
        switch result.source {
        case .base:
            terms = searchableTerms(for: result.itemID?.item ?? result.title)
        case .custom:
            terms = [result.title, result.category ?? ""]
        }

        let normalizedTerms = terms.map(normalizedForSearch)
        if normalizedTerms.contains(where: { $0 == query }) { return 0 }
        if normalizedTerms.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if normalizedTerms.contains(where: { $0.contains(query) }) { return 2 }
        return 3
    }

    private func normalizedItemName(_ name: String) -> String {
        normalizedForSearch(canonicalItemName(name))
    }

    private var searchPlaceholderText: String {
        sourceMode == .smart
            ? NSLocalizedString("itempicker.search.placeholder.scenes", comment: "")
            : NSLocalizedString("itempicker.search.placeholder.items", comment: "")
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
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection

                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                    sourcePicker
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                Group {
                    if sourceMode == .smart {
                        smartRecommendationView
                    } else if sourceMode == .myItems {
                        if searchText.isEmpty {
                            let myItems = store.myItems(in: selectedMyItemCollection).sorted(by: compareMyItems(_:_:))
                            if myItems.isEmpty {
                                VStack(spacing: 0) {
                                    myItemsHeader(isCompact: true)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 6)
                                    Spacer(minLength: 0)
                                    VStack(spacing: 8) {
                                        Image(systemName: "shippingbox")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(LocalizedStringKey("myitems.empty.title"))
                                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.center)
                                        Text(LocalizedStringKey("myitems.empty.subtitle"))
                                            .font(.system(.caption, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(1.5)
                                    }
                                    .padding(.horizontal, 24)
                                    .offset(y: -2)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .padding(.bottom, isCreateMode ? 96 : 24)
                            } else {
                                List {
                                    myItemsHeader(isCompact: false)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                                    ForEach(myItems) { item in
                                        myItemRow(item)
                                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button {
                                                    store.removeMyItem(id: item.id)
                                                } label: {
                                                    Image(systemName: "trash")
                                                        .foregroundStyle(.white)
                                                }
                                                .tint(.red)
                                            }
                                    }
                                }
                                .listStyle(.plain)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .padding(.bottom, 0)
                            }
                        } else {
                            let searchResults = orderedSearchResults
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    if searchResults.isEmpty {
                                        searchEmptyState
                                    } else {
                                        searchResultsCard {
                                            ForEach(searchResults) { result in
                                                searchResultRow(result)

                                                if result.id != searchResults.last?.id {
                                                    Rectangle()
                                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
                                                        .frame(height: 1)
                                                        .padding(.leading, 56)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.bottom, isCreateMode ? 96 : 24)
                            }
                            .scrollDismissesKeyboard(.interactively)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if searchText.isEmpty {
                                    ForEach(itemPickerCatalog, id: \.name) { category in
                                        categoryCard(category)
                                    }
                                } else {
                                    let searchResults = orderedSearchResults
                                    if searchResults.isEmpty {
                                        searchEmptyState
                                    } else {
                                        searchResultsCard {
                                            ForEach(searchResults) { result in
                                                searchResultRow(result)

                                                if result.id != searchResults.last?.id {
                                                    Rectangle()
                                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
                                                        .frame(height: 1)
                                                        .padding(.leading, 56)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, isCreateMode ? 96 : 24)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                .sheet(isPresented: $showMyItemAddSheet) {
                    NavigationStack {
                        ItemPickerMyItemEditorView(titleKey: "myitems.add.title") { name, category in
                            let normalizedCategory = category.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "Custom" : category
                            let item = store.addMyItem(name: name, category: normalizedCategory, collectionName: selectedMyItemCollection)
                            selectedMyItemIDs.insert(item.id)
                            showToast(NSLocalizedString("myitems.toast.saved", comment: ""))
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .background(Color.clear.contentShape(Rectangle()))
        .simultaneousGesture(
            TapGesture().onEnded {
                isSearchFocused = false
                hideKeyboard()
            }
        )
        .overlay(alignment: .bottom) {
            if toastVisible {
                toastBanner
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            smartPreviewStickyBar
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmSelection()
                } label: {
                    Label(sourceMode == .myItems ? "myitems.addToTrip" : "Save", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .fontWeight(.semibold)
                // 创建流程：始终可点（允许空清单，稍后在清单页添加）。
                // 追加流程（.merge）：无选择即置灰，避免"加 0 个"的死点击。
                .disabled(!isCreateMode && !canConfirm)
            }
        }
        .onAppear {
            // Warm up the search index so the first keystroke is instant.
            _ = ItemPickerView.localizedSearchTermsByItem
            guard !didApplyInitialSource else { return }
            didApplyInitialSource = true
            if startInMyItems {
                sourceMode = .myItems
            } else if let lastMode = SourceMode(rawValue: lastSourceModeRawValue) {
                sourceMode = lastMode
            }
            if selectedSmartSceneLabels.isEmpty {
                let labels = sceneLabelToKey.compactMap { label, key -> String? in
                    currentSceneKeys.contains(key) ? label : nil
                }
                selectedSmartSceneLabels = Set(labels)
            }
            let collections = store.myItemCollections()
            if !collections.contains(selectedMyItemCollection) {
                selectedMyItemCollection = collections.first ?? "Default"
            }
            let modeLabel: String
            switch mode {
            case .create: modeLabel = "create"
            case .autoPackReview: modeLabel = "autopack"
            case .merge: modeLabel = "merge"
            }
            CarryLogger.shared.log(.pickerOpened, context: "mode=\(modeLabel)")
        }
        .onChange(of: searchText) { _, newValue in
            guard !newValue.isEmpty, !didLogSearch else { return }
            didLogSearch = true
            CarryLogger.shared.log(.pickerSearchUsed, context: "source=\(sourceMode.rawValue)")
        }
        .onChange(of: sourceMode) { oldValue, newValue in
            lastSourceModeRawValue = newValue.rawValue
            if oldValue == .smart && newValue != .smart
                && !selectedSmartSceneLabels.isEmpty
                && selectedSmartSceneLabels != lastAppliedSceneLabels {
                applySmartRecommendations(shouldSwitchToPreset: false, shouldShowToast: false)
            }
        }
    }

    private func categoryCard(_ category: ItemPickerCategory) -> some View {
        let isExpanded = expandedCategories.contains(category.name)
        let isDarkMode = colorScheme == .dark
        let fill = isDarkMode
            ? Color(UIColor.secondarySystemBackground).opacity(isExpanded ? 0.62 : 0.50)
            : Color(UIColor.systemBackground).opacity(isExpanded ? 0.82 : 0.88)

        return VStack(spacing: 0) {
            categoryHeader(category)

            if isExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(isDarkMode ? 0.06 : 0.03))
                    .frame(height: 1)

                categoryBody(category)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fill)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDarkMode ? 0.05 : 0.03), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func searchResultsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let isDarkMode = colorScheme == .dark

        return VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.systemBackground).opacity(isDarkMode ? 0.82 : 0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDarkMode ? 0.05 : 0.03), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func searchResultRow(_ result: SearchResultItem) -> some View {
        Button {
            guard !result.isAlreadyAdded else { return }
            switch result.source {
            case .base:
                if let id = result.itemID {
                    if selectedItems.contains(id) {
                        selectedItems.remove(id)
                    } else {
                        selectedItems.insert(id)
                    }
                }
            case .custom:
                if let myItem = result.myItem {
                    if selectedMyItemIDs.contains(myItem.id) {
                        selectedMyItemIDs.remove(myItem.id)
                    } else {
                        selectedMyItemIDs.insert(myItem.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSearchResultSelected(result) ? CarryAccent.color : Color.clear)
                    Circle()
                        .strokeBorder(isSearchResultSelected(result) ? CarryAccent.color : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if isSearchResultSelected(result) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(UIColor.systemBackground))
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(result.title))
                            .font(.body)
                            .foregroundStyle(.primary)
                        if result.isAlreadyAdded {
                            Text(LocalizedStringKey("itempicker.already_added"))
                                .font(.system(.caption2, design: .rounded).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(UIColor.tertiarySystemFill))
                                )
                        }
                        Spacer()
                    }
                    if result.source == .custom, let category = result.category, !category.isEmpty {
                        Text(LocalizedStringKey(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 44)
            .opacity(result.isAlreadyAdded ? 0.72 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                    .frame(width: 56, height: 56)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Text(LocalizedStringKey("itempicker.search.empty.title"))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey("itempicker.search.empty.subtitle"))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.bottom, 12)
        .padding(.horizontal, 24)
    }

    private func isSearchResultSelected(_ result: SearchResultItem) -> Bool {
        if result.isAlreadyAdded { return true }
        switch result.source {
        case .base:
            return result.itemID.map { selectedItems.contains($0) } ?? false
        case .custom:
            return result.myItem.map { selectedMyItemIDs.contains($0.id) } ?? false
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(isAutoPackReview ? "autopick.review.title" : "itempicker.hero.title"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(LocalizedStringKey(isAutoPackReview ? "autopick.review.subtitle" : "myitems.add.subtitle"))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var sourcePicker: some View {
        HStack(spacing: 4) {
            sourceSegment(
                title: "myitems.source.base",
                isSelected: sourceMode == .preset
            ) {
                sourceMode = .preset
                expandedCategories.removeAll()
                isSearchFocused = false
                hideKeyboard()
                CarryLogger.shared.log(.pickerSourceSwitched, context: "to=preset")
            }

            sourceSegment(
                title: "myitems.source.custom",
                isSelected: sourceMode == .myItems
            ) {
                sourceMode = .myItems
                expandedCategories.removeAll()
                isSearchFocused = false
                hideKeyboard()
                CarryLogger.shared.log(.pickerSourceSwitched, context: "to=myitems")
            }

            Button {
                sourceMode = .smart
                isSearchFocused = false
                hideKeyboard()
                CarryLogger.shared.log(.pickerSourceSwitched, context: "to=smart_recommend")
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                        Text(LocalizedStringKey("myitems.source.smart"))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                }
                .foregroundStyle(sourceMode == .smart ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            sourceMode == .smart
                                ? LinearGradient(
                                    colors: [
                                        CarryAccent.color,
                                        CarryAccent.color.opacity(0.86)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [
                                        colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.80) : Color(UIColor.systemBackground).opacity(0.78),
                                        colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.72) : Color(UIColor.systemBackground).opacity(0.68)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(
                                sourceMode == .smart
                                    ? (colorScheme == .dark ? 0.065 : 0.04)
                                    : (colorScheme == .dark ? 0.05 : 0.08)
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: sourceMode == .smart
                        ? Color.black.opacity(colorScheme == .dark ? 0.10 : 0.12)
                        : Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03),
                    radius: sourceMode == .smart ? 6 : 3,
                    x: 0,
                    y: 1
                )
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(UIColor.systemBackground).opacity(0.96),
                            Color(UIColor.systemBackground).opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.072), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
        .frame(height: 52)
        .padding(.top, 1)
    }

    private var groupedSmartScenesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(defaultSceneGroups) { group in
                // 排除已上移到顶部「Suggested」区的场景，避免同一场景重复展示。
                let groupLabels = group.items.filter { sceneLabelToKey[$0] != nil && !promotedSceneLabels.contains($0) }
                if !groupLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(group.title))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                            .kerning(1.5)
                            .textCase(.uppercase)
                        sceneChipGrid(labels: groupLabels)
                    }
                }
            }
        }
    }

    private var smartRecommendationView: some View {
        let labels = filteredSmartSceneLabels

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                searchResultsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LocalizedStringKey("Pick travel scenes to generate a better list"))
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.92))
                            .padding(.bottom, 2)

                        if searchText.isEmpty {
                            let climateLabels = climateSuggestedLabels
                            if !climateLabels.isEmpty {
                                nudgeSection(titleKey: "scenepicker.nudge.title", labels: climateLabels)
                            }
                            if shouldNudgePeriod, let label = periodSceneLabel {
                                nudgeSection(titleKey: "scenepicker.nudge.cycle.title", labels: [label])
                            }
                            groupedSmartScenesView
                        } else if labels.isEmpty {
                            smartSearchEmptyState
                        } else {
                            sceneChipGrid(labels: labels)
                        }

                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .padding(.bottom, isCreateMode ? 120 : 36)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await runCyclePredictionIfNeeded() }
    }

    /// 轻推区块：在场景列表顶部高亮推荐的场景（气候 / 经期），点击即选入。
    private func nudgeSection(titleKey: String, labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                .kerning(1.5)
                .textCase(.uppercase)
            sceneChipGrid(labels: labels)
        }
    }

    /// 经期预测：总闸开启（或 DEBUG 强制）时跑一次，命中则激活顶部轻推。读不到/不重叠静默降级。
    private func runCyclePredictionIfNeeded() async {
        guard !didRunCyclePrediction else { return }
        didRunCyclePrediction = true

#if DEBUG
        // 调试强制开关也尊重 dateless：无日期行程没有可用日期区间，强制态同样不显示。
        if UserDefaults.standard.bool(forKey: "debugForceCycleNudge"), tripDateRange != nil {
            cycleNudgeActive = true
            CarryLogger.shared.log(.cycleNudgeShown)
            return
        }
#endif

        guard cycleNudgeFeatureEnabled, let range = tripDateRange else { return }
        let overlaps = await CycleInference.tripOverlapsPredictedPeriod(start: range.start, end: range.end)
        guard overlaps else { return }

        cycleNudgeActive = true
        CarryLogger.shared.log(.cycleNudgeShown)
    }

    private var sceneChipGrid: some View {
        sceneChipGrid(labels: filteredSmartSceneLabels)
    }

    private var filteredSmartSceneLabels: [String] {
        let allLabels = sceneLabelToKey.keys.sorted()
        let query = normalizedForSearch(searchText)
        guard !query.isEmpty else { return allLabels }
        return allLabels.filter { normalizedForSearch(NSLocalizedString($0, comment: "")).contains(query) }
    }

    private var smartPreviewItemNames: [String] {
        let keys = selectedSmartSceneLabels.compactMap { sceneLabelToKey[$0] }
        guard !keys.isEmpty else { return [] }
        let sections = generatePackingSections(selectedScenes: keys, tripDays: tripDays, isInternational: tripIsInternational, destinationCodes: tripDestinationCodes)
        let names = sections.flatMap { $0.sortedItems.map { canonicalItemName($0.name) } }
        let unique = Array(Set(names)).sorted()
        return unique.filter { name in
            !existingItemNames.contains(normalizedItemName(name))
        }
    }

    @ViewBuilder
    private var smartPreviewStickyBar: some View {
        if sourceMode == .smart && !selectedSmartSceneLabels.isEmpty {
            let preview = smartPreviewItemNames
            Button {
                sourceMode = .preset
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                    if preview.isEmpty {
                        Text(LocalizedStringKey("itempicker.smart.preview.none"))
                    } else {
                        let localizedNames = preview.prefix(3).map { NSLocalizedString($0, comment: "") }
                        let names = localizedNames.joined(separator: "、")
                        let suffix = preview.count > 3 ? "…" : ""
                        Text(
                            String(
                                format: NSLocalizedString("itempicker.smart.preview.adding", comment: ""),
                                preview.count,
                                names,
                                suffix
                            )
                        )
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.45))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colorScheme == .dark ? Color.secondary : Color.secondary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.86 : 0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07), lineWidth: 1)
                )
            }
            .buttonStyle(PressableScaleButtonStyle(scale: 0.985, pressedBrightness: -0.01, pressedOpacity: 0.95))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func sceneChipGrid(labels: [String]) -> some View {
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 6) {
            ForEach(labels, id: \.self) { label in
                let isSelected = selectedSmartSceneLabels.contains(label)
                Button {
                    if isSelected {
                        selectedSmartSceneLabels.remove(label)
                    } else {
                        selectedSmartSceneLabels.insert(label)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = smartSceneSymbols[label] {
                            Image(systemName: symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 16, height: 16)
                                .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .primary)
                        }
                        Text(LocalizedStringKey(label))
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                isSelected
                                    ? CarryAccent.color
                                    : Color.clear
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                Color.secondary.opacity(isSelected ? 0 : (colorScheme == .dark ? 0.5 : 0.44)),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var smartSearchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey("itempicker.search.smart.empty.title"))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text(LocalizedStringKey("itempicker.search.smart.empty.subtitle"))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func applySmartRecommendations(shouldSwitchToPreset: Bool, shouldShowToast: Bool) {
        let keys = selectedSmartSceneLabels.compactMap { sceneLabelToKey[$0] }
        guard !keys.isEmpty else { return }

        let generated = generatePackingSections(selectedScenes: keys, tripDays: tripDays, isInternational: tripIsInternational, destinationCodes: tripDestinationCodes)
        let generatedByCategory: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: generated.map { section in
                (section.title, Set(section.sortedItems.map { $0.name }))
            }
        )

        var preselected = Set<PickerItemID>()
        for category in itemPickerCatalog {
            let generatedNames = generatedByCategory[category.name] ?? []
            for rawKey in category.items {
                if generatedNames.contains(canonicalItemName(rawKey)) {
                    preselected.insert(PickerItemID(category: category.name, item: rawKey))
                }
            }
        }

        selectedItems = preselected
        appliedSceneRecommendedNames = Set(generated.flatMap { $0.sortedItems.map { canonicalItemName($0.name) } })
        lastAppliedSceneLabels = selectedSmartSceneLabels
        expandedCategories = Set(itemPickerCatalog
            .filter { category in
                category.items.contains { rawKey in
                    preselected.contains(PickerItemID(category: category.name, item: rawKey))
                }
            }
            .map { $0.name }
        )
        if shouldSwitchToPreset {
            sourceMode = .preset
        }
        if shouldShowToast {
            let newNames = preselected
                .map(\.item)
                .map(canonicalItemName)
                .filter { !existingItemNames.contains(normalizedItemName($0)) }
                .sorted()
            if newNames.isEmpty {
                showToast(NSLocalizedString("itempicker.smart.toast.none", comment: ""))
            } else {
                let preview = newNames.prefix(3).joined(separator: "、")
                let suffix = newNames.count > 3 ? "…" : ""
                showToast(
                    String(
                        format: NSLocalizedString("itempicker.smart.toast.added", comment: ""),
                        newNames.count,
                        preview,
                        suffix
                    )
                )
            }
        }
    }

    private func sourceSegment(title: String, subtitle: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isDarkMode = colorScheme == .dark
        return Button(action: action) {
            VStack(spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(.subheadline, design: .rounded).weight(isSelected ? .semibold : .medium))
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.80) : Color.secondary.opacity(0.78))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(
                                colors: [
                                    CarryAccent.color,
                                    CarryAccent.color.opacity(0.86)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    isDarkMode ? Color(UIColor.secondarySystemBackground).opacity(0.80) : Color(UIColor.systemBackground).opacity(0.78),
                                    isDarkMode ? Color(UIColor.secondarySystemBackground).opacity(0.72) : Color(UIColor.systemBackground).opacity(0.68)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? (isDarkMode ? 0.06 : 0.02) : (isDarkMode ? 0.06 : 0.08)), lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.black.opacity(isDarkMode ? 0.10 : 0.10) : Color.black.opacity(isDarkMode ? 0.08 : 0.03), radius: isSelected ? 7 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func myItemsHeader(isCompact: Bool) -> some View {
        let isDarkMode = colorScheme == .dark
        let fill = isDarkMode
            ? Color(UIColor.secondarySystemBackground).opacity(0.50)
            : Color(UIColor.systemBackground).opacity(0.88)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey("myitems.panel.subtitle"))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(LocalizedStringKey("myitems.panel.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                showMyItemAddSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(LocalizedStringKey("myitems.custom.new"))
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(UIColor.systemBackground).opacity(isCompact ? 0.86 : 0.90))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(isDarkMode ? 0.07 : 0.05), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDarkMode ? 0.05 : 0.03), lineWidth: 1)
        )
    }

    private func categoryHeaderText(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(UIColor.systemBackground).opacity(0.86))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.025))
                .frame(height: 1)
        }
    }

    private func myItemRow(_ item: MyItem) -> some View {
        let isAlreadyAdded = existingItemNames.contains(normalizedItemName(item.name))
        let isSelected = selectedMyItemIDs.contains(item.id)
        return Button {
            guard !isAlreadyAdded else { return }
            if isSelected {
                selectedMyItemIDs.remove(item.id)
            } else {
                selectedMyItemIDs.insert(item.id)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((isSelected || isAlreadyAdded) ? CarryAccent.color : Color.clear)
                    Circle()
                        .strokeBorder((isSelected || isAlreadyAdded) ? CarryAccent.color : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if isSelected || isAlreadyAdded {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(UIColor.systemBackground))
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(item.name))
                            .font(.body)
                            .foregroundStyle(.primary)
                        if isAlreadyAdded {
                            Text(LocalizedStringKey("itempicker.already_added"))
                                .font(.system(.caption2, design: .rounded).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(UIColor.tertiarySystemFill))
                                )
                        }
                        Spacer()
                    }
                    if !item.category.isEmpty {
                        Text(LocalizedStringKey(item.category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 48)
            .opacity(isAlreadyAdded ? 0.72 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compareMyItems(_ lhs: MyItem, _ rhs: MyItem) -> Bool {
        let lhsCategoryRank = Self.presetCategoryOrder[lhs.category] ?? Int.max
        let rhsCategoryRank = Self.presetCategoryOrder[rhs.category] ?? Int.max
        if lhsCategoryRank != rhsCategoryRank {
            return lhsCategoryRank < rhsCategoryRank
        }

        if lhs.category.localizedCaseInsensitiveCompare(rhs.category) != .orderedSame {
            return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
        }

        let lhsItemRank = Self.presetItemOrderByCategory[lhs.category]?[lhs.name] ?? Int.max
        let rhsItemRank = Self.presetItemOrderByCategory[rhs.category]?[rhs.name] ?? Int.max
        if lhsItemRank != rhsItemRank {
            return lhsItemRank < rhsItemRank
        }

        if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return lhs.sortOrder < rhs.sortOrder
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(UIColor.placeholderText))
                .font(.subheadline)
            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text(searchPlaceholderText)
                        .font(.subheadline)
                        .foregroundColor(Color(UIColor.placeholderText))
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText)
                    .font(.subheadline)
                    .tint(.primary)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
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
        .background(Color(UIColor.systemBackground).opacity(0.84))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Category header (pinned)

    @ViewBuilder
    private func categoryHeader(_ category: ItemPickerCategory) -> some View {
        let isExpanded = expandedCategories.contains(category.name)
        let selectedCount = category.items.filter { item in
            selectedItems.contains(PickerItemID(category: category.name, item: item))
                || existingItemNames.contains(normalizedItemName(item))
        }.count

        Button {
            if isExpanded {
                expandedCategories.remove(category.name)
            } else {
                expandedCategories.insert(category.name)
                CarryLogger.shared.log(.pickerCategoryExpanded, context: "category=\(category.name)")
            }
        } label: {
            HStack(spacing: 12) {
                Text(LocalizedStringKey(category.name))
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(selectedCount)/\(category.items.count)")
                    .font(.system(.caption2, design: .rounded).weight(.medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(UIColor.tertiarySystemFill))
                    )
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Category body (expanded items)

    @ViewBuilder
    private func categoryBody(_ category: ItemPickerCategory) -> some View {
        let orderedItems = category.items
        let totalCount = orderedItems.count
        let resolvedSelectedCount = orderedItems.filter { item in
            selectedItems.contains(PickerItemID(category: category.name, item: item))
                || existingItemNames.contains(normalizedItemName(item))
        }.count
        let selectableItems = orderedItems.filter {
            !existingItemNames.contains(normalizedItemName($0))
        }
        let allSelected = totalCount > 0 && resolvedSelectedCount == totalCount
        let isDarkMode = colorScheme == .dark

        VStack(spacing: 0) {
            Button {
                if allSelected {
                    for item in selectableItems {
                        selectedItems.remove(PickerItemID(category: category.name, item: item))
                    }
                    CarryLogger.shared.log(.pickerSelectAllTapped, context: "category=\(category.name) action=deselect")
                } else {
                    for item in selectableItems {
                        selectedItems.insert(PickerItemID(category: category.name, item: item))
                    }
                    CarryLogger.shared.log(.pickerSelectAllTapped, context: "category=\(category.name) action=select")
                }
            } label: {
                HStack {
                    Text(allSelected ? "Deselect all" : "Select all")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ForEach(orderedItems, id: \.self) { item in
                itemRow(item, category: category.name)
                if item != orderedItems.last {
                    Rectangle()
                        .fill(Color.primary.opacity(isDarkMode ? 0.05 : 0.03))
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Item row

    private func itemRow(_ item: String, category: String) -> some View {
        let id = PickerItemID(category: category, item: item)
        let isAlreadyAdded = existingItemNames.contains(normalizedItemName(item))
        let isSelected = selectedItems.contains(id)
        let isScenePick = sceneRecommendedNames.contains(canonicalItemName(item))
        let canonicalName = canonicalItemName(item)
        let isSaved = savedMyItemNames.contains(normalizedItemName(canonicalName))

        return HStack(spacing: 0) {
            Button {
                guard !isAlreadyAdded else { return }
                if isSelected {
                    selectedItems.remove(id)
                } else {
                    selectedItems.insert(id)
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((isSelected || isAlreadyAdded) ? CarryAccent.color : Color.clear)
                        Circle()
                            .strokeBorder((isSelected || isAlreadyAdded) ? CarryAccent.color : Color.secondary.opacity(0.4), lineWidth: 1.5)
                        if isSelected || isAlreadyAdded {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(UIColor.systemBackground))
                        }
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey(item))
                                .font(.body)
                                .foregroundColor(.primary)
                            if isScenePick && !sceneRecommendedNames.isEmpty {
                                Text("Scene pick")
                                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color(UIColor.tertiarySystemFill))
                                    )
                            }
                            if isAlreadyAdded {
                                Text(LocalizedStringKey("itempicker.already_added"))
                                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color(UIColor.tertiarySystemFill))
                                    )
                            }
                            Spacer()
                        }
                    }
                    Spacer()
                }
                .frame(height: 44)
                .opacity(isAlreadyAdded ? 0.72 : 1.0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Button {
                if isSaved {
                    if let id = savedMyItemID(for: canonicalName) {
                        store.removeMyItem(id: id)
                    }
                } else {
                    store.addMyItem(name: canonicalName, category: category, defaultQuantity: 1, collectionName: selectedMyItemCollection)
                    showToast(NSLocalizedString("itempicker.preset.saved_to_myitems", comment: ""))
                }
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSaved ? Color.secondary.opacity(0.55) : Color.secondary.opacity(0.28))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
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
        if sourceMode == .smart && !selectedSmartSceneLabels.isEmpty {
            // Safety net: user may tap top-right done without pressing smart CTA.
            applySmartRecommendations(shouldSwitchToPreset: false, shouldShowToast: false)
        }

        let sections = combinedSelectedSections()
        // 追加模式无选择则无可合并，直接返回（按钮此时也已禁用，仅作兜底）。
        // 创建模式允许空清单：行程照常创建，用户可稍后在清单页添加。
        if !isCreateMode, sections.isEmpty { return }
        let presetCount = selectedItems.count
        let myItemCount = selectedMyItemIDs.count
        let sourceLabel = presetCount > 0 && myItemCount > 0 ? "mixed"
            : presetCount > 0 ? "preset" : "myitems"
        CarryLogger.shared.log(.pickerConfirmed,
            context: "items=\(presetCount + myItemCount) source=\(sourceLabel)")

        let totalAdded = presetCount + myItemCount

        switch mode {
        case .create(let info):
            let pickedSceneKeys = selectedSmartSceneLabels.compactMap { sceneLabelToKey[$0] }
            let bundle = TripBundle(
                name: info.name,
                destinationCity: info.destinationCity,
                days: info.isDateless ? 1 : info.durationDays,
                dateRange: info.isDateless ? "" : info.dateRangeDisplay,
                departureDate: info.departureDate,
                isDateless: info.isDateless,
                selectedSceneKeys: pickedSceneKeys,
                sections: sections
            )
            // 新建行程：把设置里的默认提醒档位快照进该行程（非实时联动）。
            bundle.reminderConfigs = ReminderPreferences.defaultConfigs
            store.setDraftTrip(bundle)
            if sections.isEmpty {
                finalizeEmptyTrip(bundle: bundle, city: info.destinationCity)
            } else {
                router.pushCreation(.packingList(bundle.id))
            }

        case .autoPackReview(let info, let sceneKeys):
            let bundle = TripBundle(
                name: info.name,
                destinationCity: info.destinationCity,
                days: info.isDateless ? 1 : info.durationDays,
                dateRange: info.isDateless ? "" : info.dateRangeDisplay,
                departureDate: info.departureDate,
                isDateless: info.isDateless,
                selectedSceneKeys: sceneKeys,
                sections: sections
            )
            // 新建行程：把设置里的默认提醒档位快照进该行程（非实时联动）。
            bundle.reminderConfigs = ReminderPreferences.defaultConfigs
            store.setDraftTrip(bundle)
            if sections.isEmpty {
                finalizeEmptyTrip(bundle: bundle, city: info.destinationCity)
            } else {
                router.pushCreation(.packingList(bundle.id))
            }

        case .merge(let tripId):
            // 记录本次应用的场景 key 到行程，闭环 selectedSceneKeys——下次二次添加时
            // 这些场景就会被 alreadyAppliedSceneKeys 识别，不再重复推荐。
            let mergedSceneKeys = selectedSmartSceneLabels.compactMap { sceneLabelToKey[$0] }
            store.addScenesAndMerge(tripId: tripId, keys: mergedSceneKeys, sections: sections)
            guard !isConfirmingSelection else { return }
            isConfirmingSelection = true
            if totalAdded > 0 {
                showToast(String(format: NSLocalizedString("itempicker.toast.added_count", comment: ""), totalAdded))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                router.path.removeLast()
                isConfirmingSelection = false
            }
        }
    }

    /// 空清单创建：跳过新建预览（那一步无内容可看、且会形成 Add item ↔ Add items 的空跳转循环），
    /// 直接提交行程并进入正式清单页（isNewTrip:false，带 ⋯ 菜单），与预览页 "Save list" 行为一致。
    private func finalizeEmptyTrip(bundle: TripBundle, city: String) {
        store.commitDraftTrip()
        if !city.isEmpty {
            store.updateCountryCode(for: bundle.id, city: city)
        }
        router.finishCreation(landingTripId: bundle.id)
        Task { await NotificationManager.requestAuthorizationIfNeeded() }
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
                    quantity: myItem.resolvedDefaultQuantity(tripDays: tripDays),
                    isAlert: false,
                    sortOrder: idx
                )
            }
            result.append(PackingSection(title: title, items: items, sortOrder: index))
        }
        return result
    }

    private func combinedSelectedSections() -> [PackingSection] {
        mergeSectionsByTitle(buildSections() + buildMyItemSections())
    }

    private func mergeSectionsByTitle(_ sections: [PackingSection]) -> [PackingSection] {
        var result: [PackingSection] = []
        var indexByTitle: [String: Int] = [:]

        for section in sections {
            if let existingIndex = indexByTitle[section.title] {
                let existing = result[existingIndex]
                let nextStartOrder = (existing.items?.map(\.sortOrder).max() ?? -1) + 1
                let items = (section.items ?? []).enumerated().map { offset, item in
                    item.sortOrder = nextStartOrder + offset
                    return item
                }
                existing.items = (existing.items ?? []) + items
            } else {
                section.sortOrder = result.count
                indexByTitle[section.title] = result.count
                result.append(section)
            }
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
                .filter { selectedItems.contains(PickerItemID(category: category.name, item: canonicalItemName($0))) }
                .enumerated()
                .map { idx, name -> PackingItem in
                    let canonical = canonicalItemName(name)
                    return PackingItem(
                        name: canonical,
                        quantity: defaultQuantity(for: canonical, tripDays: tripDays),
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

private struct AutoPackFABButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ItemPickerMyItemEditorView: View {
    let titleKey: LocalizedStringKey
    var initialName: String = ""
    var initialCategory: String = ""
    var onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedCategoryKey: String
    @State private var customCategoryText: String

    private static let catalogCategoryKeys = itemPickerCatalog.map { $0.name }
    private static let customSentinel = "__custom__"

    private var effectiveCategory: String {
        selectedCategoryKey == Self.customSentinel ? customCategoryText : selectedCategoryKey
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if selectedCategoryKey == Self.customSentinel {
            return !customCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    init(
        titleKey: LocalizedStringKey,
        initialName: String = "",
        initialCategory: String = "",
        onSave: @escaping (String, String) -> Void
    ) {
        self.titleKey = titleKey
        self.initialName = initialName
        self.initialCategory = initialCategory
        self.onSave = onSave
        _name = State(initialValue: initialName)

        if itemPickerCatalog.contains(where: { $0.name == initialCategory }) {
            _selectedCategoryKey = State(initialValue: initialCategory)
            _customCategoryText = State(initialValue: "")
        } else if !initialCategory.isEmpty {
            _selectedCategoryKey = State(initialValue: Self.customSentinel)
            _customCategoryText = State(initialValue: initialCategory)
        } else {
            _selectedCategoryKey = State(initialValue: "")
            _customCategoryText = State(initialValue: "")
        }
    }

    var body: some View {
        Form {
            Section {
                TextField(LocalizedStringKey("myitems.name"), text: $name)

                Picker(selection: $selectedCategoryKey) {
                    Text(LocalizedStringKey("myitems.category.none"))
                        .foregroundStyle(.secondary)
                        .tag("")
                    ForEach(Self.catalogCategoryKeys, id: \.self) { key in
                        Text(LocalizedStringKey(key)).tag(key)
                    }
                    Text(LocalizedStringKey("myitems.category.custom")).tag(Self.customSentinel)
                } label: {
                    Text(LocalizedStringKey("myitems.category"))
                }
                .pickerStyle(.navigationLink)

                if selectedCategoryKey == Self.customSentinel {
                    TextField(LocalizedStringKey("myitems.category.custom.placeholder"), text: $customCategoryText)
                }
            }
        }
        .navigationTitle(titleKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(LocalizedStringKey("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(LocalizedStringKey("common.done")) {
                    onSave(name, effectiveCategory)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ItemPickerView(tripInfo: TripInfo(name: "Tokyo", destinationCity: "Tokyo"))
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
}
