//
//  ItemPickerView.swift
//  Carry
//

import SwiftUI

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
        "Passport", "Flight tickets", "Visa", "Hotel booking",
        "Travel insurance", "ID card", "Driver's license", "Itinerary"
    ]),
    ItemPickerCategory(name: "Travel Accessories", items: [
        "Luggage lock", "Travel pillow", "Eye mask", "Earplugs",
        "Packing cubes", "Laundry bag", "Umbrella", "Travel towel"
    ]),
    ItemPickerCategory(name: "Health & Safety", items: [
        "Painkillers", "Antihistamines", "Motion sickness tablets",
        "Hand sanitiser", "Face masks", "First aid kit",
        "Prescription medication", "Vitamins"
    ]),
    ItemPickerCategory(name: "Electronics", items: [
        "Phone charger", "Laptop", "Laptop charger", "Earphones",
        "Noise-cancelling headphones", "Portable charger", "Camera",
        "Camera charger", "Travel adapter", "E-reader"
    ]),
    ItemPickerCategory(name: "Clothing", items: [
        "T-shirt", "Jeans", "Shorts", "Underwear", "Socks", "Pajamas", "Dress",
        "Formal wear", "Sweater", "Hoodie", "Belt", "Rain jacket"
    ]),
    ItemPickerCategory(name: "Toiletries", items: [
        "Toothbrush", "Toothpaste", "Deodorant", "Shampoo", "Conditioner",
        "Body wash", "Face wash", "Moisturiser", "Lip balm", "Razor",
        "Sunscreen", "Feminine hygiene products", "Cotton swabs", "Nail clippers"
    ]),
    ItemPickerCategory(name: "Food & Snacks", items: [
        "Snack bars", "Instant noodles", "Nuts", "Dried fruit",
        "Candy", "Gum", "Protein powder"
    ]),
    ItemPickerCategory(name: "Entertainment", items: [
        "Book", "Playing cards", "Portable speaker", "Headphones",
        "Journal", "Pen"
    ]),
    ItemPickerCategory(name: "Beach & Outdoor", items: [
        "Sunglasses", "Swimsuit", "Flip flops", "Beach towel",
        "Snorkel", "Insect repellent", "Hiking boots", "Trekking poles"
    ]),
    ItemPickerCategory(name: "Winter Travel", items: [
        "Wool coat", "Thermal underwear", "Gloves", "Scarf",
        "Beanie", "Snow boots", "Hand warmers", "Ski goggles"
    ]),
]

// MARK: - ItemPickerView

struct ItemPickerView: View {

    private enum Mode {
        case create(TripInfo)
        case merge(tripId: UUID)
    }

    private let mode: Mode

    init(tripInfo: TripInfo) {
        self.mode = .create(tripInfo)
    }

    init(tripId: UUID) {
        self.mode = .merge(tripId: tripId)
    }

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var searchText = ""
    @State private var selectedItems: Set<PickerItemID> = []
    @State private var expandedCategories: Set<String> = []
    @State private var showAutoPackSheet = false
    @State private var toastVisible = false
    @State private var toastText = ""

    private var hasSelection: Bool { !selectedItems.isEmpty }

    private var isCreateMode: Bool {
        if case .create = mode { return true }
        return false
    }

    private var tripInfoForAutoPack: TripInfo? {
        if case .create(let info) = mode { return info }
        return nil
    }

    private var filteredResults: [PickerItemID] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return itemPickerCatalog.flatMap { cat in
            cat.items
                .filter { $0.lowercased().contains(query) }
                .map { PickerItemID(category: cat.name, item: $0) }
        }
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

            // Scrollable content
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
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmSelection() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(hasSelection ? .primary : Color(UIColor.tertiaryLabel))
                        .frame(width: 32, height: 32)
                        .glassCircleButton()
                }
                .buttonStyle(.plain)
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
                        .strokeBorder(isSelected ? Color.primary : Color.secondary.opacity(0.4), lineWidth: 1.5)
                        .background(Circle().fill(isSelected ? Color.primary : Color.clear))
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
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
        let sections = buildSections()
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

    private func buildSections() -> [PackingSection] {
        var sectionIndex = 0
        var result: [PackingSection] = []
        for category in itemPickerCatalog {
            let items = category.items
                .filter { selectedItems.contains(PickerItemID(category: category.name, item: $0)) }
                .enumerated()
                .map { idx, name in PackingItem(name: name, isAlert: false, sortOrder: idx) }
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
