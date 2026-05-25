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
    @Environment(\.colorScheme) private var colorScheme

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
    @State private var showMyItemAddSheet = false
    @State private var selectedMyItemCollection: String = "Default"
    @State private var didLogSearch = false
    @State private var isConfirmingSelection = false

    private var existingItemNames: Set<String> {
        guard case .merge(let tripId) = mode,
              let bundle = store.bundle(for: tripId) else { return [] }

        return Set(bundle.safeSections.flatMap { $0.items ?? [] }.map { normalizedItemName($0.name) })
    }

    private var hasSelection: Bool {
        !selectedItems.isEmpty || !selectedMyItemIDs.isEmpty
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
    }

    private var tripDays: Int {
        switch mode {
        case .create(let info):
            return info.durationDays
        case .merge(let tripId):
            return store.bundle(for: tripId)?.days ?? 1
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
        let query = normalizedForSearch(searchText)
        return (customSearchResults + baseSearchResults).sorted { lhs, rhs in
            let lhsRank = searchRank(for: lhs, query: query)
            let rhsRank = searchRank(for: rhs, query: query)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.source != rhs.source {
                return lhs.source == .custom
            }
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
            CarrySubtleBackground()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection

                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    sourcePicker
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                Group {
                    if sourceMode == .myItems {
                        if searchText.isEmpty {
                            let myItems = store.myItems(in: selectedMyItemCollection).sorted(by: compareMyItems(_:_:))
                            List {
                                myItemsHeader(isCompact: myItems.isEmpty)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))

                                if myItems.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "shippingbox")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(LocalizedStringKey("myitems.empty.title"))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.center)
                                        Text(LocalizedStringKey("myitems.empty.subtitle"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(1.5)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 16)
                                    .padding(.horizontal, 24)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                } else {
                                    ForEach(myItems) { item in
                                        myItemRow(item)
                                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button {
                                                    store.removeMyItem(id: item.id)
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                                .tint(Color(UIColor.label))
                                            }
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(.bottom, 0)
                        } else {
                            let searchResults = orderedSearchResults
                            List {
                                if searchResults.isEmpty {
                                    searchEmptyState
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                } else {
                                    ForEach(searchResults) { result in
                                        searchResultRow(result)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(.bottom, 0)
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
                                        VStack(spacing: 0) {
                                            ForEach(searchResults) { result in
                                                searchResultRow(result)
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
                        ItemPickerMyItemEditorView(titleKey: "myitems.add.title") { name, category, quantity in
                            let normalizedCategory = category.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "Custom" : category
                            let item = store.addMyItem(name: name, category: normalizedCategory, defaultQuantity: quantity, collectionName: selectedMyItemCollection)
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
        // TODO: Re-enable Auto Pack FAB when feature is ready for public release
//        .overlay(alignment: .bottomTrailing) {
//            if isCreateMode {
//                autoPackFAB
//                    .padding(.trailing, 20)
//                    .padding(.bottom, 20)
//            }
//        }
//        .sheet(isPresented: $showAutoPackSheet) {
//            if let info = tripInfoForAutoPack {
//                NavigationStack {
//                    ScenePickerView(autoPackTripInfo: info, seedSections: buildSections())
//                }
//                .presentationDetents([.large])
//                .presentationDragIndicator(.visible)
//            }
//        }
        .onAppear {
            guard !didApplyInitialSource else { return }
            didApplyInitialSource = true
            if startInMyItems {
                sourceMode = .myItems
            }
            let collections = store.myItemCollections()
            if !collections.contains(selectedMyItemCollection) {
                selectedMyItemCollection = collections.first ?? "Default"
            }
            let modeLabel: String
            if case .create = mode { modeLabel = "create" } else { modeLabel = "merge" }
            CarryLogger.shared.log(.pickerOpened, context: "mode=\(modeLabel)")
        }
        .onChange(of: searchText) { _, newValue in
            guard !newValue.isEmpty, !didLogSearch else { return }
            didLogSearch = true
            CarryLogger.shared.log(.pickerSearchUsed, context: "source=\(sourceMode.rawValue)")
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

    private func searchResultSection(titleKey: String, results: [SearchResultItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(results) { result in
                    searchResultRow(result)
                    if result.id != results.last?.id {
                        Rectangle()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
                            .frame(height: 1)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.52 : 0.66))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
        }
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
                        .fill(isSearchResultSelected(result) ? Color.primary : Color.clear)
                    Circle()
                        .strokeBorder(isSearchResultSelected(result) ? Color.primary : Color.secondary.opacity(0.4), lineWidth: 1.5)
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
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(UIColor.tertiarySystemFill))
                                )
                        }
                        if result.source == .custom {
                            Text(LocalizedStringKey("myitems.search.custom_tag"))
                                .font(.caption2.weight(.semibold))
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
                    if let category = result.category, !category.isEmpty {
                        Text(LocalizedStringKey(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 48)
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
                Text("No results")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Try a different keyword")
                    .font(.caption)
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
            Text(LocalizedStringKey("myitems.add.title"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(LocalizedStringKey("myitems.add.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var sourcePicker: some View {
        HStack(spacing: 4) {
            sourceSegment(
                title: "myitems.source.base",
                subtitle: "myitems.source.base.subtitle",
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
                subtitle: "myitems.source.custom.subtitle",
                isSelected: sourceMode == .myItems
            ) {
                sourceMode = .myItems
                expandedCategories.removeAll()
                isSearchFocused = false
                hideKeyboard()
                CarryLogger.shared.log(.pickerSourceSwitched, context: "to=myitems")
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 8, x: 0, y: 3)
        .frame(height: 58)
        .padding(.top, 2)
    }

    private func sourceSegment(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isDarkMode = colorScheme == .dark
        return Button(action: action) {
            VStack(spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary.opacity(0.78))
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(
                                colors: [
                                    isDarkMode ? Color(UIColor.secondarySystemBackground).opacity(0.99) : Color.primary.opacity(0.98),
                                    isDarkMode ? Color(UIColor.tertiarySystemBackground).opacity(0.98) : Color.primary.opacity(0.84)
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? (isDarkMode ? 0.06 : 0.02) : (isDarkMode ? 0.06 : 0.08)), lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.black.opacity(isDarkMode ? 0.10 : 0.10) : Color.black.opacity(isDarkMode ? 0.08 : 0.03), radius: isSelected ? 7 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func myItemsHeader(isCompact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("myitems.panel.subtitle"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey("myitems.panel.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(UIColor.systemBackground).opacity(isCompact ? 0.82 : 0.88))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.systemBackground).opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.012), radius: 4, x: 0, y: 1)
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
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundColor(.primary)
                .frame(width: 56, height: 56)
                .background {
                    ZStack {
                        Circle()
                            .fill(autoPackGradient)
                            .blur(radius: 8)
                            .opacity(0.5)
                        Circle()
                            .fill(Color(UIColor.systemBackground).opacity(0.94))
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(autoPackGradient, lineWidth: 1.5)
                }
        }
        .buttonStyle(AutoPackFABButtonStyle())
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
                        .fill((isSelected || isAlreadyAdded) ? Color.primary : Color.clear)
                    Circle()
                        .strokeBorder((isSelected || isAlreadyAdded) ? Color.primary : Color.secondary.opacity(0.4), lineWidth: 1.5)
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
                                .font(.caption2.weight(.semibold))
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
            Text("Search items...")
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
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Category header (pinned)

    @ViewBuilder
    private func categoryHeader(_ category: ItemPickerCategory) -> some View {
        let isExpanded = expandedCategories.contains(category.name)
        let selectedCount = category.items.filter {
            selectedItems.contains(PickerItemID(category: category.name, item: $0))
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
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(selectedCount)/\(category.items.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(UIColor.tertiarySystemFill))
                    )
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
    }

    // MARK: - Category body (expanded items)

    @ViewBuilder
    private func categoryBody(_ category: ItemPickerCategory) -> some View {
        let selectableItems = category.items.filter {
            !existingItemNames.contains(normalizedItemName($0))
        }
        let selectedCount = selectableItems.filter {
            selectedItems.contains(PickerItemID(category: category.name, item: $0))
        }.count
        let allSelected = !selectableItems.isEmpty && selectedCount == selectableItems.count
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

            ForEach(category.items, id: \.self) { item in
                itemRow(item, category: category.name)
                if item != category.items.last {
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
        return Button {
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
                        .fill((isSelected || isAlreadyAdded) ? Color.primary : Color.clear)
                    Circle()
                        .strokeBorder((isSelected || isAlreadyAdded) ? Color.primary : Color.secondary.opacity(0.4), lineWidth: 1.5)
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
                        if isAlreadyAdded {
                            Text(LocalizedStringKey("itempicker.already_added"))
                                .font(.caption2.weight(.semibold))
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
        .padding(.horizontal, 16)
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
        let sections = combinedSelectedSections()
        guard !sections.isEmpty else { return }
        let presetCount = selectedItems.count
        let myItemCount = selectedMyItemIDs.count
        let sourceLabel = presetCount > 0 && myItemCount > 0 ? "mixed"
            : presetCount > 0 ? "preset" : "myitems"
        CarryLogger.shared.log(.pickerConfirmed,
            context: "items=\(presetCount + myItemCount) source=\(sourceLabel)")

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
            store.setDraftTrip(bundle)
            router.path.append(CreationRoute.packingList(bundle.id))

        case .merge(let tripId):
            store.mergeItems(tripId: tripId, sections: sections)
            guard !isConfirmingSelection else { return }
            isConfirmingSelection = true
            showToast(NSLocalizedString("itempicker.toast.added_to_list", comment: ""))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                router.path.removeLast()
                isConfirmingSelection = false
            }
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
    var initialQuantity: Int = 1
    var onSave: (String, String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: String
    @State private var quantity: String

    init(
        titleKey: LocalizedStringKey,
        initialName: String = "",
        initialCategory: String = "",
        initialQuantity: Int = 1,
        onSave: @escaping (String, String, Int) -> Void
    ) {
        self.titleKey = titleKey
        self.initialName = initialName
        self.initialCategory = initialCategory
        self.initialQuantity = initialQuantity
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _category = State(initialValue: initialCategory)
        _quantity = State(initialValue: String(initialQuantity))
    }

    var body: some View {
        Form {
            Section {
                TextField("myitems.name", text: $name)
                TextField("myitems.category", text: $category)
                TextField("myitems.quantity", text: $quantity)
                    .keyboardType(.numberPad)
            }
        }
        .navigationTitle(titleKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done") {
                    let value = max(1, Int(quantity) ?? 1)
                    onSave(name, category, value)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
