//
//  PackingListView.swift
//  Carry
//

import SwiftUI

// MARK: - PackingListView

struct PackingListView: View {

    let tripId: UUID
    var isNewTrip: Bool = false

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var editingItemId: UUID? = nil
    @State private var editingText: String = ""
    @State private var isAdvancingEdit = false
    @FocusState private var focusedItemId: UUID?

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isSaved = false

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var sections: [PackingSection] {
        (bundle?.safeSections ?? []).filter { ($0.items?.isEmpty == false) }
    }
    private var totalCount: Int  { bundle?.totalCount  ?? 0 }
    private var packedCount: Int { bundle?.packedCount ?? 0 }
    private var progress: Double {
        totalCount == 0 ? 0 : Double(packedCount) / Double(totalCount)
    }
    private var isComplete: Bool {
        totalCount > 0 && packedCount == totalCount
    }

    var body: some View {
        VStack(spacing: 0) {

            // — Progress header (fixed, does not scroll)
            progressHeader

            if isComplete {
                completionBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // — Scrollable list
            if sections.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        Section {
                            ForEach(section.sortedItems.filter { !$0.name.isEmpty || $0.id == editingItemId }, id: \.id) { item in
                                row(for: item, sectionId: section.id)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color(UIColor.systemBackground))
                            }
                            .onMove { source, destination in
                                moveItems(in: section, source: source, destination: destination)
                            }

                            addItemRow(sectionId: section.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color(UIColor.systemBackground))
                        } header: {
                            sectionTitle(section.title, isFirst: index == 0)
                                .listRowInsets(EdgeInsets())
                        }
                        .listSectionSeparator(.hidden)
                    }

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .listSectionSpacing(0)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 83) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isNewTrip {
                saveTripButton
                    .padding(.bottom, 16)
            }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .navigationTitle(bundle?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit trip", systemImage: "pencil")
                    }
                    Button {
                        router.path.append(CreationRoute.editScenes(tripId))
                    } label: {
                        Label("Edit scenes", systemImage: "tag")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete trip", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
        }
        .onChange(of: focusedItemId) { _, newValue in
            if newValue == nil, let id = editingItemId, !isAdvancingEdit {
                commitEdit(itemId: id)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isComplete)
        .sheet(isPresented: $showEditSheet) {
            if let bundle {
                EditTripView(trip: bundle)
            }
        }
        .alert(
            "Delete \(bundle?.name ?? "")?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                store.removeTrip(withId: tripId)
                router.path = NavigationPath()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete your packing list and all progress.")
        }
    }

    // MARK: Row dispatch

    @ViewBuilder
    private func row(for item: PackingItem, sectionId: UUID) -> some View {
        if editingItemId == item.id {
            editableRow(itemId: item.id, sectionId: sectionId)
        } else {
            PackingItemRow(item: item) {
                toggleItem(itemId: item.id)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteItem(itemId: item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Actions

    private func toggleItem(itemId: UUID) {
        store.toggleItem(tripId: tripId, itemId: itemId)
        if totalCount > 0, packedCount == totalCount {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func deleteItem(itemId: UUID) {
        store.removeItem(tripId: tripId, itemId: itemId)
    }

    private func moveItems(in section: PackingSection, source: IndexSet, destination: Int) {
        if let id = editingItemId { commitEdit(itemId: id) }
        var ids = section.sortedItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.reorderItems(tripId: tripId, sectionId: section.id, newOrder: ids)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Subviews

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(height: 2)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .frame(width: max(0, geo.size.width * progress), height: 2)
                }
            }
            .frame(height: 2)

            HStack(alignment: .firstTextBaseline) {
                Text(tripInfoLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(packedCount) / \(totalCount) packed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: progress)
    }

    private var tripInfoLine: String {
        [bundle?.destinationCity, bundle?.dateRange]
            .compactMap { str in (str?.isEmpty == false) ? str : nil }
            .joined(separator: " · ")
    }

    private var completionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.primary)
            Text("All packed. You're ready to go!")
                .foregroundColor(.primary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Spacer()
            Image(systemName: "suitcase")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("packing.empty.title")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.top, 12)
            Text("packing.empty.subtitle")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Spacer()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String, isFirst: Bool) -> some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .kerning(1.5)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, isFirst ? 8 : 24)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.systemBackground))
    }

    private func editableRow(itemId: UUID, sectionId: UUID) -> some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 24, height: 24)

            TextField("", text: $editingText)
                .font(.subheadline)
                .focused($focusedItemId, equals: itemId)
                .submitLabel(.next)
                .onSubmit { appendNewItem(sectionId: sectionId) }

            Spacer()

            Circle()
                .fill(Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(height: 44)
    }

    private func addItemRow(sectionId: UUID) -> some View {
        Button {
            appendNewItem(sectionId: sectionId)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                Text("Add item")
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    private var saveTripButton: some View {
        VStack(spacing: 0) {
            Button {
                guard !isSaved else { return }
                if let id = editingItemId { commitEdit(itemId: id) }
                isSaved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    router.path = NavigationPath([tripId])
                    await NotificationManager.requestAuthorizationIfNeeded()
                }
            } label: {
                HStack(spacing: 8) {
                    if isSaved {
                        Image(systemName: "checkmark")
                            .fontWeight(.medium)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(isSaved ? "Saved!" : "Save trip")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .transition(.opacity)
                }
                .foregroundColor(Color(UIColor.systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.primary)
                .cornerRadius(14)
                .animation(.easeInOut(duration: 0.2), value: isSaved)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(Color(UIColor.systemBackground))
    }

    // MARK: Editing

    private func commitEdit(itemId: UUID) {
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.removeItem(tripId: tripId, itemId: itemId)
        } else {
            store.updateItemName(tripId: tripId, itemId: itemId, name: trimmed)
        }
        editingItemId = nil
        editingText = ""
    }

    private func appendNewItem(sectionId: UUID) {
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        isAdvancingEdit = true
        withAnimation(.easeInOut(duration: 0.2)) {
            if let id = editingItemId { commitEdit(itemId: id) }
            let newId = store.addItem(tripId: tripId, sectionIndex: sectionIndex)
            editingItemId = newId
            editingText = ""
            DispatchQueue.main.async {
                focusedItemId = newId
                isAdvancingEdit = false
            }
        }
    }
}

// MARK: - Packing Item Row

struct PackingItemRow: View {

    let item: PackingItem
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {

            // — Checkbox
            ZStack {
                Circle()
                    .strokeBorder(item.isPacked ? Color(.systemGray2) : Color(.systemGray3), lineWidth: 1.5)
                    .background(
                        Circle().fill(item.isPacked ? Color(.systemGray2) : Color.clear)
                    )
                    .frame(width: 24, height: 24)

                if item.isPacked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }

            // — Name
            Text(item.name)
                .font(.subheadline)
                .foregroundColor(item.isPacked ? Color(.tertiaryLabel) : .primary)
                .strikethrough(item.isPacked)

            Spacer()

            // — Alert dot
            Circle()
                .fill(item.isAlert ? Color.alertOrange : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
        }
        .frame(minHeight: 44)
        .opacity(item.isPacked ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.15), value: item.isPacked)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PackingListView(tripId: TripStore().trips.first!.id)
    }
    .environmentObject(TripStore())
    .environmentObject(NavigationRouter())
}
