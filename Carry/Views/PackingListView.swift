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
    @State private var openItemId: UUID? = nil

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var sections: [PackingSection] { bundle?.safeSections ?? [] }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { si, section in

                        sectionTitle(section.title)

                        ForEach(section.sortedItems, id: \.id) { item in
                            if editingItemId == item.id {
                                editableRow(itemId: item.id, sectionIndex: si)
                            } else {
                                PackingItemRow(
                                    item: item,
                                    isOpen: openItemId == item.id,
                                    onTap: { toggleItem(itemId: item.id) },
                                    onDelete: { deleteItem(itemId: item.id) },
                                    onOpenChange: { newOpen in
                                        openItemId = newOpen ? item.id : (openItemId == item.id ? nil : openItemId)
                                    }
                                )
                            }
                            divider
                        }

                        addItemRow(sectionIndex: si)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isNewTrip { saveTripButton }
        }
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

    private func toggleItem(itemId: UUID) {
        store.toggleItem(tripId: tripId, itemId: itemId)
        if totalCount > 0, packedCount == totalCount {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func deleteItem(itemId: UUID) {
        openItemId = nil
        store.removeItem(tripId: tripId, itemId: itemId)
    }

    // MARK: Subviews

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            HStack {
                Spacer()
                Text("\(packedCount) / \(totalCount) packed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: progress)
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .kerning(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func editableRow(itemId: UUID, sectionIndex: Int) -> some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                .frame(width: 16, height: 16)

            TextField("Item name", text: $editingText)
                .font(.subheadline)
                .focused($focusedItemId, equals: itemId)
                .submitLabel(.next)
                .onSubmit { appendNewItem(sectionIndex: sectionIndex) }

            Spacer()

            Circle()
                .fill(Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
    }

    private func addItemRow(sectionIndex: Int) -> some View {
        Button {
            appendNewItem(sectionIndex: sectionIndex)
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
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var saveTripButton: some View {
        Button {
            if let id = editingItemId { commitEdit(itemId: id) }
            router.path = NavigationPath()
        } label: {
            Text("Save trip")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(Color(UIColor.systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.primary)
                .cornerRadius(12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemBackground))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(UIColor.separator))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    // MARK: Private

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

    private func appendNewItem(sectionIndex: Int) {
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
    let isOpen: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onOpenChange: (Bool) -> Void

    private let actionWidth: CGFloat = 80
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onDelete) {
                Text("Delete")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .frame(width: actionWidth, height: 44)
                    .background(Color.red)
            }
            .buttonStyle(.plain)

            rowContent
                .background(Color(UIColor.systemBackground))
                .offset(x: offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let base: CGFloat = isOpen ? -actionWidth : 0
                            offset = min(0, max(-actionWidth - 20, base + value.translation.width))
                        }
                        .onEnded { _ in
                            let shouldOpen = offset < -actionWidth / 2
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                offset = shouldOpen ? -actionWidth : 0
                            }
                            onOpenChange(shouldOpen)
                        }
                )
        }
        .clipped()
        .onChange(of: isOpen) { _, newValue in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                offset = newValue ? -actionWidth : 0
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {

            // — Checkbox
            ZStack {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1)
                    .background(
                        Circle().fill(item.isPacked ? Color.primary : Color.clear)
                    )
                    .frame(width: 16, height: 16)

                if item.isPacked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(UIColor.systemBackground))
                }
            }

            // — Name
            Text(item.name)
                .font(.subheadline)
                .foregroundColor(item.isPacked ? .secondary : .primary)
                .strikethrough(item.isPacked)

            Spacer()

            // — Alert dot
            Circle()
                .fill(item.isAlert ? Color.alertOrange : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen {
                onOpenChange(false)
            } else {
                onTap()
            }
        }
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
