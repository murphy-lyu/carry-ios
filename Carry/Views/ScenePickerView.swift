//
//  ScenePickerView.swift
//  Carry
//

import SwiftUI

// MARK: - ScenePickerView

struct ScenePickerView: View {

    /// Creation mode: build a brand-new trip from the given info.
    /// Edit mode: regenerate scenes for an existing trip.
    enum Mode {
        case create(TripInfo)
        case edit(tripId: UUID)
    }

    private let mode: Mode

    init(tripInfo: TripInfo) {
        self.mode = .create(tripInfo)
    }

    init(editingTripId: UUID) {
        self.mode = .edit(tripId: editingTripId)
    }

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @State private var selectedItems: Set<String> = []
    @State private var didLoadInitialSelection = false

    private var hasSelection: Bool { !selectedItems.isEmpty }
    private var selectionCount: Int { selectedItems.count }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var primaryButtonLabelKey: LocalizedStringKey {
        if isEditing {
            return hasSelection
                ? "scenes.update · \(selectionCount) selected"
                : "scenes.update"
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's your trip like?")
                        .font(.headline)
                        .fontWeight(.medium)
                    Text("Select all that apply")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // — Scene groups
                ForEach(defaultSceneGroups) { group in
                    SceneGroupSection(group: group, selectedItems: $selectedItems)
                }
            }
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: { primaryAction() }) {
                Text(primaryButtonLabelKey)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(Color(UIColor.systemBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.primary)
                    .cornerRadius(14)
            }
            .disabled(!hasSelection)
            .opacity(hasSelection ? 1.0 : 0.3)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(Color(UIColor.systemBackground))
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
            store.regenerateScenes(tripId: tripId, keys: keys)
            router.path.removeLast()
        }
    }

    private func generateList(info: TripInfo, keys: [String]) {
        let sections = generatePackingSections(selectedScenes: keys)
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
        router.path.append(CreationRoute.packingList(bundle.id))
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

struct SceneChip: View {

    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(label))
                .font(.caption)
                .foregroundColor(isSelected ? Color(UIColor.systemBackground) : .primary)
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
