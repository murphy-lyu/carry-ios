//
//  ScenePickerView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - ScenePickerView

struct ScenePickerView: View {

    enum Mode {
        case create(TripInfo)
        case edit(tripId: UUID)
        case autoPack(tripInfo: TripInfo, seedSections: [PackingSection])
        case suggest(tripId: UUID)
    }

    private let mode: Mode

    init(tripInfo: TripInfo) {
        self.mode = .create(tripInfo)
    }

    init(editingTripId: UUID) {
        self.mode = .edit(tripId: editingTripId)
    }

    init(autoPackTripInfo: TripInfo, seedSections: [PackingSection]) {
        self.mode = .autoPack(tripInfo: autoPackTripInfo, seedSections: seedSections)
    }

    init(suggestForTripId: UUID) {
        self.mode = .suggest(tripId: suggestForTripId)
    }

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: Set<String> = []
    @State private var didLoadInitialSelection = false
    @State private var isSaved = false
    @State private var confirmedSuggestKeys: [String]? = nil
    @State private var didFinishSuggest = false

    private var hasSelection: Bool { !selectedItems.isEmpty }
    private var selectionCount: Int { selectedItems.count }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isAutoPack: Bool {
        if case .autoPack = mode { return true }
        return false
    }

    private var isSuggest: Bool {
        if case .suggest = mode { return true }
        return false
    }

    private var primaryButtonLabelKey: LocalizedStringKey {
        if isSaved { return "scenes.updated" }
        if isEditing {
            return hasSelection ? "scenes.update" : "scenes.select_one"
        } else if isAutoPack {
            return hasSelection ? "Auto Pack" : "scenes.select_one"
        } else if isSuggest {
            return hasSelection ? "See suggestions" : "scenes.skip"
        } else {
            return hasSelection ? "Generate my list" : "scenes.select_one"
        }
    }

    private var isPrimaryButtonEnabled: Bool {
        if isSaved { return false }
        if isSuggest { return true }
        return hasSelection
    }

    private var isPrimaryButtonHighlighted: Bool {
        if isSaved { return false }
        if isSuggest { return true }
        return hasSelection
    }

    var body: some View {
        ZStack {
            CarrySubtleBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heroSection

                    ForEach(Array(defaultSceneGroups.enumerated()), id: \.element.id) { index, group in
                        SceneGroupSection(group: group, selectedItems: $selectedItems)
                            .padding(.top, index == 0 ? -16 : 0)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button(action: { primaryAction() }) {
                    HStack(spacing: 8) {
                        if isSaved {
                            Image(systemName: "checkmark")
                                .fontWeight(.medium)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(primaryButtonLabelKey)
                            .transition(.opacity)
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(
                        isPrimaryButtonHighlighted
                        ? Color(UIColor.systemBackground)
                        : Color(UIColor.secondaryLabel)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                isPrimaryButtonHighlighted
                                ? Color(UIColor.label)
                                : Color(UIColor.secondarySystemFill)
                            )
                            .animation(.easeInOut(duration: 0.15), value: isPrimaryButtonHighlighted)
                    }
                    .animation(.easeInOut(duration: 0.2), value: isSaved)
                }
                .disabled(!isPrimaryButtonEnabled)
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(
                LinearGradient(
                    colors: [
                        Color(UIColor.systemBackground).opacity(0.92),
                        Color(UIColor.systemBackground).opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadInitialSelectionIfNeeded() }
        .sheet(isPresented: Binding(
            get: { confirmedSuggestKeys != nil },
            set: { if !$0 { confirmedSuggestKeys = nil } }
        )) {
            if case .suggest(let tripId) = mode, let keys = confirmedSuggestKeys {
                SuggestionPreviewView(tripId: tripId, sceneKeys: keys, didFinish: $didFinishSuggest)
            }
        }
        .onChange(of: didFinishSuggest) { _, finished in
            if finished { dismiss() }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose scenes")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Pick travel scenes to generate a better list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isAutoPack || isEditing || isSuggest {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .glassCircleButton()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }

    // MARK: Private

    private func loadInitialSelectionIfNeeded() {
        guard !didLoadInitialSelection else { return }
        didLoadInitialSelection = true
        let tripId: UUID
        switch mode {
        case .edit(let id):    tripId = id
        case .suggest(let id): tripId = id
        default: return
        }
        guard let trip = store.bundle(for: tripId) else { return }
        let savedKeys = Set(trip.selectedSceneKeys)
        let labels = sceneLabelToKey.compactMap { (label, key) -> String? in
            savedKeys.contains(key) ? label : nil
        }
        selectedItems = Set(labels)
    }

    private func primaryAction() {
        let keys = selectedItems.compactMap { sceneLabelToKey[$0] }
        switch mode {
        case .create(let info):
            generateList(info: info, keys: keys)
        case .edit(let tripId):
            guard !isSaved else { return }
            store.regenerateScenes(tripId: tripId, keys: keys)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeInOut(duration: 0.2)) { isSaved = true }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
            }
        case .autoPack(let info, let seedSections):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let id = buildTrip(info: info, keys: keys, seedSections: seedSections)
            guard store.bundle(for: id) != nil else {
                CarryLogger.shared.log(.autoPackNavigationFailed, context: "context=trip_not_persisted")
                return
            }
            router.path = NavigationPath()
            router.path.append(CreationRoute.packingList(id))
            dismiss()
        case .suggest:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            guard !keys.isEmpty else {
                if case .suggest(let tripId) = mode {
                    store.setSelectedSceneKeys(tripId: tripId, keys: [])
                }
                dismiss()
                return
            }
            confirmedSuggestKeys = keys
        }
    }

    @discardableResult
    private func buildTrip(info: TripInfo, keys: [String], seedSections: [PackingSection] = []) -> UUID {
        var sections = generatePackingSections(selectedScenes: keys, tripDays: info.durationDays)
        if !seedSections.isEmpty {
            mergeSeedSections(seedSections, into: &sections)
        }
        let bundle = TripBundle(
            name: info.name,
            destinationCity: info.destinationCity,
            days: info.durationDays,
            dateRange: info.dateRangeDisplay,
            departureDate: info.departureDate,
            selectedSceneKeys: keys,
            sections: sections
        )
        store.setDraftTrip(bundle)
        return bundle.id
    }

    private func generateList(info: TripInfo, keys: [String]) {
        let id = buildTrip(info: info, keys: keys)
        router.path.append(CreationRoute.packingList(id))
    }

    private func mergeSeedSections(_ seedSections: [PackingSection], into sections: inout [PackingSection]) {
        for seedSection in seedSections {
            if let targetIndex = sections.firstIndex(where: { $0.title == seedSection.title }) {
                guard let targetItems = sections[targetIndex].items else { continue }
                let existingNames = Set(targetItems.map { $0.name.lowercased() })
                var nextOrder = (targetItems.map(\.sortOrder).max() ?? -1) + 1
                for seedItem in seedSection.sortedItems where !existingNames.contains(seedItem.name.lowercased()) {
                    let newItem = PackingItem(
                        name: seedItem.name,
                        quantity: seedItem.quantity,
                        isAlert: seedItem.isAlert,
                        sortOrder: nextOrder
                    )
                    nextOrder += 1
                    sections[targetIndex].items?.append(newItem)
                }
            } else {
                let copiedItems = seedSection.sortedItems.enumerated().map { index, item in
                    PackingItem(
                        name: item.name,
                        quantity: item.quantity,
                        isAlert: item.isAlert,
                        sortOrder: index
                    )
                }
                let newSection = PackingSection(
                    title: seedSection.title,
                    items: copiedItems,
                    sortOrder: sections.count
                )
                sections.append(newSection)
            }
        }
    }
}

// MARK: - Scene Group Section

struct SceneGroupSection: View {

    let group: SceneGroup
    @Binding var selectedItems: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(group.title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.78))
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            GeometryReader { geo in
                let rows = chipRows(for: group.items, maxWidth: max(1, geo.size.width))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { item in
                                SceneChip(
                                    label: item,
                                    isSelected: selectedItems.contains(item)
                                ) {
                                    if selectedItems.contains(item) {
                                        selectedItems.remove(item)
                                    } else {
                                        selectedItems.insert(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: chipsHeight(for: group.items))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func chipRows(for items: [String], maxWidth: CGFloat) -> [[String]] {
        var rows: [[String]] = [[]]
        var currentRowWidth: CGFloat = 0
        let spacing: CGFloat = 8

        for item in items {
            let chipWidth = estimatedChipWidth(for: item)
            let nextWidth = rows[rows.count - 1].isEmpty
                ? chipWidth
                : currentRowWidth + spacing + chipWidth

            if nextWidth > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([item])
                currentRowWidth = chipWidth
            } else {
                rows[rows.count - 1].append(item)
                currentRowWidth = nextWidth
            }
        }
        return rows
    }

    private func chipsHeight(for items: [String]) -> CGFloat {
        let available = max(1, UIScreen.main.bounds.width - 32) // section has 16 + 16 padding
        let rowCount = chipRows(for: items, maxWidth: available).count
        let rowH: CGFloat = 30
        let spacing: CGFloat = 8
        return CGFloat(rowCount) * rowH + CGFloat(max(0, rowCount - 1)) * spacing
    }

    private func estimatedChipWidth(for item: String) -> CGFloat {
        let text = NSLocalizedString(item, comment: "") as NSString
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let textW = ceil(text.size(withAttributes: [.font: font]).width)
        let iconW: CGFloat = 16
        let innerSpacing: CGFloat = 6
        let horizontalPadding: CGFloat = 20
        return textW + iconW + innerSpacing + horizontalPadding
    }
}

// MARK: - Scene Chip

private let sceneSymbols: [String: String] = [
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
    "☕ Coffee lover":          "cup.and.saucer.fill",
    "🍵 Tea lover":            "cup.and.saucer.fill",
    "💊 Daily medication":     "pill.fill",
    "🔒 Personal (private)":   "lock.fill",
]

struct SceneChip: View {

    let label: String
    let isSelected: Bool
    let action: () -> Void

    private var displayKey: LocalizedStringKey {
        LocalizedStringKey(label)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol = sceneSymbols[label] {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .primary)
                }
                Text(displayKey)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.primary : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(isSelected ? 0 : 0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ScenePickerView(
            autoPackTripInfo: TripInfo(name: "Tokyo", destinationCity: "Tokyo"),
            seedSections: []
        )
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
    }
}
