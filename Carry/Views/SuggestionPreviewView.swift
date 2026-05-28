//
//  SuggestionPreviewView.swift
//  Carry
//

import SwiftUI

struct SuggestionPreviewView: View {

    let tripId: UUID
    let sceneKeys: [String]
    @Binding var didFinish: Bool

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedNames: Set<String> = []
    @State private var sections: [(title: String, items: [String])] = []
    @State private var surpriseItems: [SurpriseItem] = []
    @State private var selectedSurpriseNames: Set<String> = []

    private var selectedCount: Int { selectedNames.count + selectedSurpriseNames.count }
    private var hasSelection: Bool { !selectedNames.isEmpty || !selectedSurpriseNames.isEmpty }
    private var hasContent: Bool { !sections.isEmpty || !surpriseItems.isEmpty }

    private var displaySections: [(title: String, items: [String])] { sections }

    private var displaySurpriseItems: [SurpriseItem] { surpriseItems }

    private var surpriseItemNames: Set<String> { Set(surpriseItems.map(\.name)) }
    private var chromeBackgroundColor: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color(UIColor.systemBackground)
    }
    private var primaryButtonBackground: Color {
        hasSelection
            ? Color(UIColor.label)
            : (colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(UIColor.systemGray3))
    }
    private var primaryButtonForeground: Color {
        hasSelection ? Color(UIColor.systemBackground) : Color(UIColor.secondaryLabel)
    }

    var body: some View {
        ZStack {
            chromeBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBlock

                if hasContent {
                    list
                } else {
                    emptyState
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if hasContent {
                confirmFooter
            }
        }
        .onAppear { load() }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !displaySections.isEmpty {
                    ForEach(Array(displaySections.enumerated()), id: \.element.title) { _, section in
                        Section {
                            ForEach(section.items, id: \.self) { item in
                                itemRow(item)
                            }
                        } header: {
                            sectionHeader(section.title)
                        }
                    }
                }

                if !displaySurpriseItems.isEmpty {
                    Section {
                        ForEach(displaySurpriseItems) { item in
                            surpriseItemRow(item)
                        }
                    } header: {
                        surpriseHeader
                    }
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 100)
        }
        .background(chromeBackgroundColor)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("suggestions.title")
                    .font(.title2)
                    .bold()
                Spacer()
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
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.medium))
                .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                .kerning(1.1)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.02) : Color.primary.opacity(0.02))
                .frame(height: 1)
        }
        .background(chromeBackgroundColor)
        .zIndex(1)
    }

    private var surpriseHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Nice to have")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                    .kerning(1.1)
                    .textCase(.uppercase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.02) : Color.primary.opacity(0.02))
                .frame(height: 1)
        }
        .background(chromeBackgroundColor)
        .zIndex(1)
    }

    private func itemRow(_ name: String) -> some View {
        let isSurprise = surpriseItemNames.contains(name)
        let isSelected = selectedNames.contains(name) || selectedSurpriseNames.contains(name)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                if isSurprise {
                    if isSelected { selectedSurpriseNames.remove(name) } else { selectedSurpriseNames.insert(name) }
                } else {
                    if isSelected { selectedNames.remove(name) } else { selectedNames.insert(name) }
                }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                Text(LocalizedStringKey(name))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(height: 48)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func surpriseItemRow(_ item: SurpriseItem) -> some View {
        let isSelected = selectedSurpriseNames.contains(item.name)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                if isSelected { selectedSurpriseNames.remove(item.name) } else { selectedSurpriseNames.insert(item.name) }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(item.name))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(LocalizedStringKey(item.note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var confirmFooter: some View {
        VStack(spacing: 0) {
            Button { confirm() } label: {
                Group {
                    if hasSelection {
                        Text(String(format: NSLocalizedString("suggestions.add_items_count", comment: ""), selectedCount))
                    } else {
                        Text("suggestions.none_needed")
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(primaryButtonForeground)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(primaryButtonBackground)
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(hasSelection ? 0.08 : 0.14), lineWidth: 1)
                )
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(chromeBackgroundColor)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("suggestions.empty.title")
                .font(.headline)
            Text("suggestions.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Data

    private func load() {
        guard let bundle = store.bundle(for: tripId) else { return }
        let existingLower = Set(
            bundle.safeSections.flatMap { $0.items ?? [] }.map { $0.name.lowercased() }
        )
        let myItemLower = Set(
            store.myItems.map { canonicalItemName($0.name).lowercased() }
        )
        let excludedLower = existingLower.union(myItemLower)

        // Regular suggestions (default unselected)
        let generated = generatePackingSections(selectedScenes: sceneKeys, tripDays: bundle.days)
        var result: [(title: String, items: [String])] = []
        var allNames = Set<String>()
        for section in generated {
            let newItems = (section.items ?? [])
                .filter { !excludedLower.contains($0.name.lowercased()) }
                .map { $0.name }
            guard !newItems.isEmpty else { continue }
            result.append((title: section.title, items: newItems))
            newItems.forEach { allNames.insert($0) }
        }
        sections = result
        selectedNames = allNames
        selectedSurpriseNames.removeAll()

        // Surprise items (not pre-selected) — exclude names already in regular suggestions, cap at 3
        let dismissed = Set(bundle.dismissedSurpriseNames.map { $0.lowercased() })
        let excludedNames = excludedLower.union(allNames.map { $0.lowercased() })
        surpriseItems = computeSurpriseItems(
            for: sceneKeys,
            existingNames: excludedNames,
            rankingMode: .sceneFirst
        )
        .filter { !dismissed.contains($0.name.lowercased()) }
        .prefix(3)
        .map { $0 }
    }

    private func confirm() {
        guard let tripBundle = store.bundle(for: tripId) else { return }
        var sectionIndex = 0
        var newSections: [PackingSection] = []
        for section in sections {
            let chosen = section.items.filter { selectedNames.contains($0) }
            guard !chosen.isEmpty else { continue }
            let items = chosen.enumerated().map { idx, name in
                PackingItem(name: name, quantity: defaultQuantity(for: name, tripDays: tripBundle.days), isAlert: false, sortOrder: idx)
            }
            newSections.append(PackingSection(title: section.title, items: items, sortOrder: sectionIndex))
            sectionIndex += 1
        }
        store.addScenesAndMerge(tripId: tripId, keys: sceneKeys, sections: newSections)

        for item in surpriseItems {
            if selectedSurpriseNames.contains(item.name) {
                store.addSurpriseItem(tripId: tripId, item: item)
            } else {
                store.dismissSurpriseItem(tripId: tripId, itemName: item.name)
            }
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didFinish = true
        dismiss()
    }
}

#Preview {
    @Previewable @State var didFinish = false
    SuggestionPreviewView(tripId: UUID(), sceneKeys: [], didFinish: $didFinish)
        .environmentObject(TripStore())
}
