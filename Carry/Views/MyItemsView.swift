//
//  MyItemsView.swift
//  Carry
//

import SwiftUI

struct MyItemsView: View {

    @EnvironmentObject private var store: TripStore
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var editingItem: MyItem?

    private var visibleItems: [MyItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.myItems
            .filter { item in
                query.isEmpty
                    || item.name.lowercased().contains(query)
                    || item.category.lowercased().contains(query)
            }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        List {
            if visibleItems.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visibleItems) { item in
                    myItemRow(item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                editingItem = item
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)

                            Button(role: .destructive) {
                                store.removeMyItem(id: item.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("Search"))
        .navigationTitle("myitems.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                MyItemEditorView(titleKey: "myitems.add.title") { name, category, quantity in
                    let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSLocalizedString("myitems.custom_category", comment: "") : category
                    _ = store.addMyItem(name: name, category: normalizedCategory, defaultQuantity: quantity)
                }
            }
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                MyItemEditorView(
                    titleKey: "myitems.edit.title",
                    initialName: item.name,
                    initialCategory: item.category,
                    initialQuantity: item.defaultQuantity
                ) { name, category, quantity in
                    store.updateMyItem(item, name: name, category: category, defaultQuantity: quantity)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("myitems.empty.title")
                .font(.headline)
            Text("myitems.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddSheet = true
            } label: {
                Text("myitems.add.title")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.vertical, 24)
    }

    private func myItemRow(_ item: MyItem) -> some View {
        Button {
            editingItem = item
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.clear)
                    .overlay(
                        Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    )
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .foregroundStyle(.primary)
                    if !item.category.isEmpty {
                        Text(item.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MyItemEditorView: View {

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
