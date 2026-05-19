//
//  ScenePickerView.swift
//  Carry
//

import SwiftUI

// MARK: - ScenePickerView

struct ScenePickerView: View {

    enum Mode {
        case create(TripInfo)
        case edit(tripId: UUID)
        case autoPack(tripInfo: TripInfo, seedSections: [PackingSection])
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

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: Set<String> = []
    @State private var didLoadInitialSelection = false
    @State private var isSaved = false

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

    private var primaryButtonLabelKey: LocalizedStringKey {
        if isSaved { return "scenes.updated" }
        if isEditing {
            return hasSelection
                ? "scenes.update · \(selectionCount) selected"
                : "scenes.update"
        } else if isAutoPack {
            return hasSelection
                ? "Auto Pack · \(selectionCount) selected"
                : "Auto Pack"
        } else {
            return hasSelection
                ? "Generate my list · \(selectionCount) selected"
                : "Generate my list"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // — Header
                HStack(spacing: 0) {
                    Text("What's your trip like?")
                        .font(.title2)
                        .bold()
                    Spacer()
                    if isAutoPack || isEditing {
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
                .padding(.horizontal, 16)
                .padding(.top, (isAutoPack || isEditing) ? 24 : 8)

                // — Scene groups
                ForEach(defaultSceneGroups) { group in
                    SceneGroupSection(group: group, selectedItems: $selectedItems)
                }
            }
            .padding(.bottom, 16)
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
                    .foregroundColor(hasSelection ? Color(UIColor.systemBackground) : Color(UIColor.secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(hasSelection ? Color(UIColor.label) : Color(UIColor.secondarySystemFill))
                            .animation(.easeInOut(duration: 0.15), value: hasSelection)
                    }
                    .animation(.easeInOut(duration: 0.2), value: isSaved)
                }
                .disabled(!hasSelection || isSaved)
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(.regularMaterial)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadInitialSelectionIfNeeded() }
    }

    // MARK: Private

    private func loadInitialSelectionIfNeeded() {
        guard !didLoadInitialSelection else { return }
        didLoadInitialSelection = true
        guard case .edit(let tripId) = mode,
              let trip = store.bundle(for: tripId) else { return }
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
            router.path = NavigationPath()
            router.path.append(CreationRoute.packingList(id))
            dismiss()
        }
    }

    @discardableResult
    private func buildTrip(info: TripInfo, keys: [String], seedSections: [PackingSection] = []) -> UUID {
        var sections = generatePackingSections(selectedScenes: keys)
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
        store.addTrip(bundle)
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
                    let newItem = PackingItem(name: seedItem.name, isAlert: seedItem.isAlert, sortOrder: nextOrder)
                    nextOrder += 1
                    sections[targetIndex].items?.append(newItem)
                }
            } else {
                let copiedItems = seedSection.sortedItems.enumerated().map { index, item in
                    PackingItem(name: item.name, isAlert: item.isAlert, sortOrder: index)
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
                .foregroundStyle(.tertiary)
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(group.items, id: \.self) { item in
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
            .padding(.horizontal, 16)
        }
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
    "👶 Travelling with kids": "figure.and.child.holdinghands",
    "🥾 Hiking / camping":     "tent.fill",
    "💍 Honeymoon":            "heart.fill",
    "🩸 Near period":          "drop.fill",
    "☕ Coffee lover":          "cup.and.saucer.fill",
    "🍵 Tea lover":            "cup.and.saucer.fill",
    "💊 Daily medication":     "pill.fill",
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

// MARK: - Flow Layout

struct FlowLayout: Layout {

    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        computeLayout(subviews: subviews, in: proposal.replacingUnspecifiedDimensions().width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = computeLayout(subviews: subviews, in: bounds.width)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: .unspecified
            )
        }
    }

    // MARK: Private

    private struct LayoutResult {
        var placements: [(x: CGFloat, y: CGFloat)] = []
        var size: CGSize = .zero
    }

    private func computeLayout(subviews: Subviews, in maxWidth: CGFloat) -> LayoutResult {
        var result = LayoutResult()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + verticalSpacing
                x = 0
                lineHeight = 0
            }
            result.placements.append((x: x, y: y))
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
            result.size.width = max(result.size.width, x - horizontalSpacing)
        }
        result.size.height = y + lineHeight
        return result
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ScenePickerView(tripInfo: TripInfo())
    }
    .environmentObject(TripStore())
    .environmentObject(NavigationRouter())
}
