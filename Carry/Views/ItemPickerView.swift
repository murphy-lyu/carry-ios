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
    @State private var showMyItemAddSheet = false
    @State private var selectedMyItemCollection: String = "Default"

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

    private var presetCategoryOrder: [String: Int] {
        Dictionary(uniqueKeysWithValues: itemPickerCatalog.enumerated().map { ($1.name, $0) })
    }

    private var presetItemOrderByCategory: [String: [String: Int]] {
        Dictionary(uniqueKeysWithValues: itemPickerCatalog.map { category in
            let itemOrder = Dictionary(uniqueKeysWithValues: category.items.enumerated().map { ($1, $0) })
            return (category.name, itemOrder)
        })
    }

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
                .map { PickerItemID(category: cat.name, item: canonicalItemName($0)) }
        }
    }

    private func itemMatchesQuery(_ itemKey: String, query: String) -> Bool {
        let canonical = canonicalItemName(itemKey)
        let localized = NSLocalizedString(canonical, comment: "")
        let raw = canonical
        return normalizedForSearch(localized).contains(query) ||
               normalizedForSearch(raw).contains(query)
    }

    private func normalizedForSearch(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func myItemsSearchResults() -> [MyItem] {
        let query = normalizedForSearch(searchText)
        return store.myItems(in: selectedMyItemCollection).filter {
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

                if sourceMode == .myItems {
                    List {
                        myItemsHeader
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))

                        let myItems = myItemsSearchResults().sorted(by: compareMyItems(_:_:))
                        if myItems.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: searchText.isEmpty ? "shippingbox" : "magnifyingglass")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(searchText.isEmpty ? LocalizedStringKey("myitems.empty.title") : "No results")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.center)
                                if searchText.isEmpty {
                                    Text(LocalizedStringKey("myitems.empty.subtitle"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineSpacing(2)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
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
                    .sheet(isPresented: $showMyItemAddSheet) {
                        NavigationStack {
                            ItemPickerMyItemEditorView(titleKey: "myitems.add.title") { name, category, quantity in
                                let normalizedCategory = category.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "Custom" : category
                                let item = store.addMyItem(name: name, category: normalizedCategory, defaultQuantity: quantity, collectionName: selectedMyItemCollection)
                                selectedMyItemIDs.insert(item.id)
                                showToast("Saved to My Items")
                            }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if searchText.isEmpty {
                                ForEach(itemPickerCatalog, id: \.name) { category in
                                    Section {
                                        if expandedCategories.contains(category.name) {
                                            categoryBody(category)
                                        }
                                    } header: {
                                        categoryHeader(category)
                                    }
                                    .padding(.bottom, 0)
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
        HStack(spacing: 0) {
            sourceSegment(
                title: "myitems.source.base",
                subtitle: "myitems.source.base.subtitle",
                isSelected: sourceMode == .preset
            ) {
                sourceMode = .preset
                searchText = ""
                expandedCategories.removeAll()
                isSearchFocused = false
                hideKeyboard()
            }

            sourceSegment(
                title: "myitems.source.mine",
                subtitle: "myitems.source.mine.subtitle",
                isSelected: sourceMode == .myItems
            ) {
                sourceMode = .myItems
                searchText = ""
                expandedCategories.removeAll()
                isSearchFocused = false
                hideKeyboard()
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
        Button(action: action) {
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
                                Color.primary.opacity(0.98),
                                Color.primary.opacity(0.84)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    Color(UIColor.systemBackground).opacity(0.78),
                                    Color(UIColor.systemBackground).opacity(0.68)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.02 : 0.08), lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.black.opacity(0.10) : Color.black.opacity(0.03), radius: isSelected ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var myItemsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("myitems.title"))
                        .font(.headline)
                    Text(verbatim: selectedMyItemCollection == "Default"
                         ? String(localized: "myitems.collection.default_hint")
                         : selectedMyItemCollection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showMyItemAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text(LocalizedStringKey("myitems.add.title"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(UIColor.systemBackground).opacity(0.84))
                    )
                }
                .buttonStyle(.plain)
            }

            if store.myItemCollections().count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.myItemCollections(), id: \.self) { collection in
                            Button {
                                selectedMyItemCollection = collection
                                searchText = ""
                            } label: {
                                Text(collection)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(selectedMyItemCollection == collection ? Color(UIColor.systemBackground) : .primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selectedMyItemCollection == collection ? Color.primary : Color(UIColor.systemBackground).opacity(0.84))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.primary.opacity(selectedMyItemCollection == collection ? 0 : 0.08), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text(selectedMyItemIDs.isEmpty
                 ? String(localized: "myitems.none_selected")
                 : String.localizedStringWithFormat(NSLocalizedString("myitems.selected_count", comment: ""), selectedMyItemIDs.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(UIColor.systemBackground).opacity(0.90),
                            Color(UIColor.systemBackground).opacity(0.80)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 6, x: 0, y: 2)
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
        let isSelected = selectedMyItemIDs.contains(item.id)
        return Button {
            if isSelected {
                selectedMyItemIDs.remove(item.id)
            } else {
                selectedMyItemIDs.insert(item.id)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(item.name))
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !item.category.isEmpty {
                        Text(LocalizedStringKey(item.category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compareMyItems(_ lhs: MyItem, _ rhs: MyItem) -> Bool {
        let lhsCategoryRank = presetCategoryOrder[lhs.category] ?? Int.max
        let rhsCategoryRank = presetCategoryOrder[rhs.category] ?? Int.max
        if lhsCategoryRank != rhsCategoryRank {
            return lhsCategoryRank < rhsCategoryRank
        }

        if lhs.category.localizedCaseInsensitiveCompare(rhs.category) != .orderedSame {
            return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
        }

        let lhsItemRank = presetItemOrderByCategory[lhs.category]?[lhs.name] ?? Int.max
        let rhsItemRank = presetItemOrderByCategory[rhs.category]?[rhs.name] ?? Int.max
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
        .background(
            Color(UIColor.systemBackground).opacity(0.86)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.025))
                .frame(height: 1)
                .padding(.horizontal, 0)
        }
        .padding(.horizontal, 16)
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
