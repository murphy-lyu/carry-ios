//
//  PackingListView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - PackingListView

struct PackingListView: View {

    let tripId: UUID
    var isNewTrip: Bool = false

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.colorScheme) private var colorScheme

    @State private var editingItemId: UUID? = nil
    @State private var editingText: String = ""
    @State private var isAdvancingEdit = false
    @FocusState private var focusedItemId: UUID?

    @State private var showEditSheet = false
    @State private var showEditScenesSheet = false
    @State private var showSuggestSheet = false
    @State private var showReorderSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isSaved = false
    @State private var showConfetti = false
    @State private var showCompletionBanner = false
    @State private var hasTriggeredCompletion = false
    @State private var shimmerPhase: CGFloat = -1
    @State private var showNudgeBanner = false
    @State private var hasTriggeredNudge = false
    @State private var surpriseBatchOffset: Int = 0
    @State private var showSceneCardDismissHintBanner = false

    private let surpriseBatchSize = 5

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var sections: [PackingSection] {
        (bundle?.safeSections ?? []).filter { ($0.items?.isEmpty == false) }
    }
    private var hasScenes: Bool { !(bundle?.selectedSceneKeys.isEmpty ?? true) }
    private var sceneCardDismissed: Bool {
        store.isSceneCardDismissedGlobally || (bundle?.sceneCardDismissed ?? false)
    }
    private var totalCount: Int  { bundle?.totalCount  ?? 0 }
    private var packedCount: Int { bundle?.packedCount ?? 0 }
    private var progress: Double {
        totalCount == 0 ? 0 : Double(packedCount) / Double(totalCount)
    }
    private var isComplete: Bool {
        totalCount > 0 && packedCount == totalCount
    }

    private var surpriseItems: [SurpriseItem] {
        guard let bundle else { return [] }
        let existingNames = Set(
            bundle.safeSections.flatMap { $0.items ?? [] }.map { $0.name.lowercased() }
        )
        let dismissed = Set(bundle.dismissedSurpriseNames.map { $0.lowercased() })
        return computeSurpriseItems(for: bundle.selectedSceneKeys, existingNames: existingNames)
            .filter { !dismissed.contains($0.name.lowercased()) }
    }

    private var visibleSurpriseItems: [SurpriseItem] {
        guard !surpriseItems.isEmpty else { return [] }
        let total = surpriseItems.count
        guard total > surpriseBatchSize else { return surpriseItems }
        return (0..<surpriseBatchSize).map { i in surpriseItems[(surpriseBatchOffset + i) % total] }
    }

    private var canShuffle: Bool { surpriseItems.count > surpriseBatchSize }

    var body: some View {
        VStack(spacing: 0) {

            // — Progress header (fixed, does not scroll)
            progressHeader

            // — Scrollable list
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(section.sortedItems.filter { !$0.name.isEmpty || $0.id == editingItemId }, id: \.id) { item in
                                        row(for: item, sectionId: section.id)
                                            .padding(.horizontal, 16)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(UIColor.systemBackground))
                                    }
                                    addItemRow(sectionId: section.id)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 16)
                                        .background(Color(UIColor.systemBackground))
                                }
                            } header: {
                                sectionTitle(section.title, isFirst: index == 0)
                            }
                        }

                        if !surpriseItems.isEmpty && isNewTrip {
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(visibleSurpriseItems) { item in
                                        surpriseRow(for: item)
                                            .padding(.horizontal, 16)
                                            .background(Color(UIColor.systemBackground))
                                    }
                                }
                            } header: {
                                surpriseSectionHeader
                            }
                        }

                        if !sceneCardDismissed {
                            sceneEntryCard
                                .padding(.top, 8)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if editingItemId != nil {
                            dismissInlineEditing()
                        }
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                )
                .background(Color(UIColor.systemBackground))
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 83) }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if showCompletionBanner {
                            completionBanner
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if showNudgeBanner {
                            nudgeBanner
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if showSceneCardDismissHintBanner {
                            sceneCardDismissHintBanner
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                                .padding(.top, 4)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if editingItemId != nil {
                    dismissInlineEditing()
                }
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        )
        .safeAreaInset(edge: .bottom) {
            if isNewTrip {
                saveTripButton
                    .padding(.bottom, 16)
            }
        }
        .coordinateSpace(name: "packingRoot")
        .toolbarBackground(.visible, for: .tabBar)
        .navigationTitle(bundle?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ZStack {
                    Text(bundle?.name ?? "")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissInlineEditing()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if !isNewTrip {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit trip", systemImage: "pencil")
                        }
                    }
                    Button {
                        showReorderSheet = true
                    } label: {
                        Label("Edit sections", systemImage: "arrow.up.arrow.down")
                    }
                    if !isNewTrip {
                        Button {
                            let activityVC = UIActivityViewController(
                                activityItems: [shareText],
                                applicationActivities: nil
                            )
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let window = windowScene.windows.first,
                               let rootVC = window.rootViewController {
                                rootVC.present(activityVC, animated: true)
                            }
                        } label: {
                            Label("Share list", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showSuggestSheet = true
                        } label: {
                            Label("Add recommended items", systemImage: "tag")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete trip", systemImage: "trash")
                        }
                    } else {
                        Button {
                            showSuggestSheet = true
                        } label: {
                            Label("Add recommended items", systemImage: "tag")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
        }
        .overlay {
            if showConfetti {
                ConfettiView()
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            CarryLogger.shared.log(.tripOpened)
            if let b = bundle, b.sections == nil {
                CarryLogger.shared.log(.tripDataEmpty, context: "context=onAppear")
            }
            guard isComplete else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !hasTriggeredCompletion else { return }
                shimmerPhase = -1
                withAnimation(.linear(duration: 0.75)) {
                    shimmerPhase = 1
                }
            }
        }
        .onChange(of: isComplete) { _, complete in
            guard complete, !hasTriggeredCompletion else { return }
            hasTriggeredCompletion = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showConfetti = true
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showCompletionBanner = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(2500))
                withAnimation(.easeIn(duration: 0.3)) {
                    showCompletionBanner = false
                }
            }
        }
        .onChange(of: focusedItemId) { _, newValue in
            if newValue == nil, let id = editingItemId, !isAdvancingEdit {
                commitEdit(itemId: id)
            }
        }
        .onChange(of: progress) { _, newProgress in
            guard newProgress >= 0.85,
                  isNewTrip,
                  !hasTriggeredNudge,
                  !(bundle?.nudgeShown ?? true),
                  !surpriseItems.isEmpty else { return }
            hasTriggeredNudge = true
            store.markNudgeShown(tripId: tripId)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showNudgeBanner = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(3500))
                withAnimation(.easeIn(duration: 0.3)) { showNudgeBanner = false }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isComplete)
        .sheet(isPresented: $showEditSheet, onDismiss: {
            store.refresh()
        }) {
            if let bundle {
                EditTripView(trip: bundle)
            }
        }
        .sheet(isPresented: $showEditScenesSheet, onDismiss: {
            store.refresh()
        }) {
            ScenePickerView(editingTripId: tripId)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSuggestSheet) {
            ScenePickerView(suggestForTripId: tripId)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showReorderSheet) {
            NavigationStack {
                ReorderSectionsView(tripId: tripId) { newOrder in
                    store.reorderSections(tripId: tripId, newOrder: newOrder)
                }
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
            PackingItemRow(
                item: item,
                onTap: {
                    toggleItem(itemId: item.id)
                },
                onDecrement: {
                    decrementItemQuantity(itemId: item.id, current: item.quantity)
                },
                onIncrement: {
                    incrementItemQuantity(itemId: item.id, current: item.quantity)
                },
                onSetQuantity: { newValue in
                    store.updateItemQuantity(tripId: tripId, itemId: item.id, quantity: newValue)
                }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    saveToMyItems(item: item)
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
                .tint(.indigo)
                Button(role: .destructive) {
                    deleteItem(itemId: item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    // MARK: Actions

    private func toggleItem(itemId: UUID) {
        guard !isNewTrip else { return }
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

    private func saveToMyItems(item: PackingItem) {
        store.addMyItem(
            name: item.name,
            category: sectionTitle(for: item.id) ?? "",
            defaultQuantity: item.quantity
        )
    }

    private func sectionTitle(for itemId: UUID) -> String? {
        for section in sections {
            if (section.items ?? []).contains(where: { $0.id == itemId }) {
                return section.title
            }
        }
        return nil
    }

    private func incrementItemQuantity(itemId: UUID, current: Int) {
        let next = min(current + 1, 9_999)
        store.updateItemQuantity(tripId: tripId, itemId: itemId, quantity: next)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func decrementItemQuantity(itemId: UUID, current: Int) {
        let next = max(current - 1, 1)
        guard next != current else { return }
        store.updateItemQuantity(tripId: tripId, itemId: itemId, quantity: next)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func moveItems(in section: PackingSection, source: IndexSet, destination: Int) {
        if let id = editingItemId { commitEdit(itemId: id) }
        var ids = section.sortedItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.reorderItems(tripId: tripId, sectionId: section.id, newOrder: ids)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Share

    private var shareText: String {
        guard let bundle = bundle else { return "" }
        let sep = String(repeating: "━", count: 32)
        var lines: [String] = []
        let daysFormat = NSLocalizedString("%@ · %lld days", comment: "Trip date range and duration")
        let packedFormat = NSLocalizedString("%lld / %lld packed", comment: "Packed count over total count")

        // — Header
        let heading = [bundle.name, bundle.destinationCity]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        lines.append("🧳 \(heading)")
        lines.append("")
        lines.append("📅 \(String(format: daysFormat, locale: Locale.current, bundle.localizedDateRange, Int64(bundle.days)))")
        if packedCount == totalCount && totalCount > 0 {
            lines.append("📊 All packed! (\(totalCount))")
        } else {
            lines.append("📊 \(String(format: packedFormat, locale: Locale.current, Int64(packedCount), Int64(totalCount)))")
        }

        // — Sections
        lines.append("")
        lines.append(sep)
        lines.append("🧳 Packing List")
        lines.append(sep)

        for section in sections {
            let items = section.sortedItems.filter { !$0.name.isEmpty }
            let sectionPacked = items.filter { $0.isPacked }.count
            lines.append("")
            lines.append("📂 \(section.title) (\(sectionPacked)/\(items.count))")
            for item in items {
                let box = item.isPacked ? "  ✅" : "  ⭕"
                let flag = item.isAlert ? " ⚠️" : ""
                let qty = item.quantity > 1 ? " ×\(item.quantity)" : ""
                lines.append("\(box) \(item.name)\(qty)\(flag)")
            }
        }

        // — Footer
        lines.append("")
        lines.append(sep)
        lines.append("Shared via Carry 🧳")
        lines.append(sep)
        return lines.joined(separator: "\n")
    }

    // MARK: Subviews

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isNewTrip {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color(UIColor.systemGray5))
                            .frame(height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary)
                            .frame(width: max(0, geo.size.width * progress), height: 2)
                            .overlay {
                                LinearGradient(
                                    colors: [.clear, Color(UIColor.systemBackground).opacity(0.65), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: geo.size.width * 0.35)
                                .offset(x: shimmerPhase * geo.size.width * 0.675)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                    }
                }
                .frame(height: 2)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(tripInfoLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Group {
                    if isNewTrip {
                        Text("\(totalCount) items")
                    } else if isComplete {
                        Text("All packed ✓")
                    } else {
                        Text("\(totalCount - packedCount) left")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .animation(.easeInOut(duration: 0.3), value: isComplete)
            }
            .padding(.top, isNewTrip ? 0 : 8)
        }
        .background(Color(UIColor.systemBackground))
        .zIndex(2)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: progress)
    }

    private var tripInfoLine: String {
        [bundle?.destinationCity, bundle?.localizedDateRange]
            .compactMap { str in (str?.isEmpty == false) ? str : nil }
            .joined(separator: " · ")
    }

    private var completionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text("All packed — you're ready to go! 🎉")
                .foregroundStyle(.white)
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.black)
    }

    private var sceneEntryCard: some View {
        Button { showSuggestSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(UIColor.systemPurple))
                    .frame(width: 32, height: 32)
                    .background(Color(UIColor.systemPurple).opacity(0.1))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add recommended items")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Fill gaps with smart suggestions for this trip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.trailing, 30)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button {
                store.dismissSceneCard(tripId: tripId)
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSceneCardDismissHintBanner = true
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(3200))
                    withAnimation(.easeIn(duration: 0.2)) {
                        showSceneCardDismissHintBanner = false
                    }
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
    }

    private var nudgeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
            Text("Almost there! A few things worth a second thought ↓")
                .foregroundStyle(.white)
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemIndigo))
    }

    private var sceneCardDismissHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.white)
            Text("scene_card.dismissed.message")
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemGray))
    }

    private var surpriseSectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Worth considering")
                .font(.caption.bold())
                .foregroundStyle(Color(.systemGray))
                .kerning(1.5)
                .textCase(.uppercase)
            Spacer()
            if canShuffle {
                Button {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        surpriseBatchOffset = (surpriseBatchOffset + surpriseBatchSize) % surpriseItems.count
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text("surprise.shuffle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemBackground))
    }

    private func surpriseRow(for item: SurpriseItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(item.name))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(item.note))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                store.addSurpriseItem(tripId: tripId, item: item)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text("Add")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(UIColor.secondarySystemFill))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                store.dismissSurpriseItem(tripId: tripId, itemName: item.name)
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(Color(UIColor.systemGray3))
        }
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
            if !sceneCardDismissed {
                sceneEntryCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String, isFirst: Bool) -> some View {
        Text(LocalizedStringKey(title))
            .font(.caption.bold())
            .foregroundStyle(Color(.systemGray))
            .kerning(1.5)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemBackground))
        .compositingGroup()
        .zIndex(1)
    }

    private func editableRow(itemId: UUID, sectionId: UUID) -> some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 24, height: 24)

            TextField("", text: $editingText)
                .font(.subheadline)
                .tint(.primary)
                .focused($focusedItemId, equals: itemId)
                .submitLabel(.done)
                .onSubmit { focusedItemId = nil }

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
                    Text(isSaved ? "packing.start.saved" : "packing.start.action")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .transition(.opacity)
                }
                .foregroundColor(Color(UIColor.systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(UIColor.label))
                }
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

    private func dismissInlineEditing() {
        focusedItemId = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        if let id = editingItemId {
            commitEdit(itemId: id)
        }
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

// MARK: - Confetti

private struct ConfettiParticle: Identifiable {
    let id = UUID()
    let xFraction: CGFloat   // 0…1 of screen width
    let drift: CGFloat
    let size: CGFloat
    let color: Color
    let delay: Double
}

private struct ConfettiView: View {

    private let particles: [ConfettiParticle] = (0..<35).map { _ in
        ConfettiParticle(
            xFraction: CGFloat.random(in: 0...1),
            drift: CGFloat.random(in: -50...50),
            size: CGFloat.random(in: 4...9),
            color: [Color(.systemGray4), Color(.systemGray5)].randomElement()!,
            delay: Double.random(in: 0...0.5)
        )
    }

    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { p in
                    Circle()
                        .fill(p.color)
                        .frame(width: p.size, height: p.size)
                        .position(
                            x: p.xFraction * geo.size.width + (animate ? p.drift : 0),
                            y: animate ? geo.size.height + 20 : -10
                        )
                        .opacity(animate ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.8).delay(p.delay),
                            value: animate
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                animate = true
            }
        }
    }
}

// MARK: - Packing Item Row

struct PackingItemRow: View {

    let item: PackingItem
    let onTap: () -> Void
    var onDecrement: (() -> Void)? = nil
    var onIncrement: (() -> Void)? = nil
    var onSetQuantity: ((Int) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var checkScale: CGFloat = 1.0
    @State private var checkmarkOpacity: Double
    @State private var checkmarkScale: CGFloat
    @State private var isEditingQuantity = false
    @State private var quantityText = ""
    @State private var quantityPressing = false
    @FocusState private var focusedQuantityField: Bool

    init(
        item: PackingItem,
        onTap: @escaping () -> Void,
        onDecrement: (() -> Void)? = nil,
        onIncrement: (() -> Void)? = nil,
        onSetQuantity: ((Int) -> Void)? = nil,
    ) {
        self.item = item
        self.onTap = onTap
        self.onDecrement = onDecrement
        self.onIncrement = onIncrement
        self.onSetQuantity = onSetQuantity
        _checkmarkOpacity = State(initialValue: item.isPacked ? 1.0 : 0)
        _checkmarkScale = State(initialValue: item.isPacked ? 1.0 : 0.5)
    }

    private var displayedQuantity: Int {
        max(1, min(9_999, item.quantity))
    }

    var body: some View {
        HStack(spacing: 14) {
            quantityControl
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Text(LocalizedStringKey(item.name))
                        .font(.subheadline)
                        .foregroundColor(item.isPacked ? Color(.secondaryLabel) : .primary)
                        .strikethrough(item.isPacked)
                        .opacity(item.isPacked ? (colorScheme == .dark ? 0.75 : 0.6) : 1.0)

                    Spacer()

                    ZStack {
                        Circle()
                            .strokeBorder(
                                item.isPacked
                                    ? Color.primary.opacity(colorScheme == .dark ? 0.78 : 0.74)
                                    : Color(.systemGray3).opacity(colorScheme == .dark ? 0.85 : 0.72),
                                lineWidth: 1.4
                            )
                            .background(
                                Circle().fill(item.isPacked ? Color.primary.opacity(colorScheme == .dark ? 0.9 : 0.84) : Color.clear)
                            )
                            .frame(width: 24, height: 24)

                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(UIColor.systemBackground))
                            .scaleEffect(checkmarkScale)
                            .opacity(checkmarkOpacity)
                    }
                    .scaleEffect(checkScale)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 44)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.isPacked)
        .onChange(of: focusedQuantityField) { _, focused in
            if !focused, isEditingQuantity {
                commitQuantityEdit()
            }
        }
        .onChange(of: item.isPacked) { _, isPacked in
            if isPacked {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    checkmarkOpacity = 1.0
                    checkmarkScale = 1.0
                }
                withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) {
                    checkScale = 1.15
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        checkScale = 1.0
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    checkmarkOpacity = 0
                    checkmarkScale = 0.5
                }
                withAnimation(.easeOut(duration: 0.1)) {
                    checkScale = 0.85
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        checkScale = 1.0
                    }
                }
            }
        }
    }

    private var quantityControl: some View {
        HStack(spacing: 0) {
            Group {
                if isEditingQuantity {
                    TextField("", text: $quantityText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .focused($focusedQuantityField)
                        .lineLimit(1)
                        .frame(width: 40, height: 24, alignment: .center)
                        .onChange(of: quantityText) { _, newValue in
                            quantityText = String(newValue.filter(\.isNumber).prefix(4))
                        }
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") {
                                    commitQuantityEdit()
                                }
                            }
                        }
                } else {
                    Text("\(displayedQuantity)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .tracking(displayedQuantity >= 1000 ? -0.2 : 0)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .frame(width: 40, height: 24, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            beginQuantityEdit()
                        }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isEditingQuantity
                        ? Color(.secondarySystemFill).opacity(colorScheme == .dark ? 0.95 : 0.78)
                        : Color(.secondarySystemFill).opacity(colorScheme == .dark ? 0.86 : 0.62)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isEditingQuantity
                        ? Color.primary.opacity(colorScheme == .dark ? 0.30 : 0.20)
                        : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10),
                    lineWidth: isEditingQuantity ? 1.1 : 0.9
                )
        )
        .opacity(item.isPacked ? 0.82 : 1.0)
        .scaleEffect(quantityPressing ? 0.96 : 1.0)
        .animation(.spring(response: 0.16, dampingFraction: 0.72), value: quantityPressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !quantityPressing { quantityPressing = true }
                }
                .onEnded { _ in
                    quantityPressing = false
                }
        )
    }

    private func beginQuantityEdit() {
        guard !isEditingQuantity else { return }
        isEditingQuantity = true
        quantityText = String(displayedQuantity)
        DispatchQueue.main.async {
            focusedQuantityField = true
        }
    }

    private func commitQuantityEdit() {
        let trimmed = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Int(trimmed) ?? displayedQuantity
        let clamped = max(1, min(9_999, value))
        onSetQuantity?(clamped)
        isEditingQuantity = false
        focusedQuantityField = false
        quantityText = ""
    }
}

// MARK: - Reorder Sections Sheet

struct ReorderSectionsView: View {

    let tripId: UUID
    let onDone: ([UUID]) -> Void

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var ordered: [PackingSection] = []
    @State private var showAddAlert = false
    @State private var newSectionName = ""
    @State private var renamingSection: PackingSection? = nil
    @State private var renameName = ""
    @State private var pendingNewIds: Set<UUID> = []
    @State private var pendingRenames: [UUID: String] = [:]
    @State private var pendingDeleteIds: Set<UUID> = []

    @State private var draggingId: UUID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartGlobalY: CGFloat = 0
    @State private var dragStartIndex: Int = 0
    @State private var dragCurrentIndex: Int = 0

    private let rowH: CGFloat = 52
    private let rowGap: CGFloat = 8
    private var slotH: CGFloat { rowH + rowGap }

    private var showRenameAlert: Binding<Bool> {
        Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: rowGap) {
                ForEach(ordered) { section in
                    rowView(section: section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 80)
        }
        .scrollDisabled(draggingId != nil)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Edit sections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { commitDone() }
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    newSectionName = ""
                    showAddAlert = true
                } label: {
                    Label("New section", systemImage: "plus")
                }
            }
        }
        .alert("New section", isPresented: $showAddAlert) {
            TextField("Section name", text: $newSectionName)
            Button("Add") { commitAdd() }
            Button("Cancel", role: .cancel) { newSectionName = "" }
        }
        .alert("Rename", isPresented: showRenameAlert) {
            TextField("Section name", text: $renameName)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSection = nil }
        }
        .onAppear {
            ordered = store.bundle(for: tripId)?.safeSections
                .filter { $0.items?.isEmpty == false } ?? []
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(section: PackingSection) -> some View {
        let isDragging = draggingId == section.id
        HStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28)) { deleteSection(section) }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                    .frame(width: 48, height: rowH)
            }
            .buttonStyle(.plain)

            Button {
                let current = pendingRenames[section.id] ?? NSLocalizedString(section.title, comment: "")
                renameName = current
                renamingSection = section
            } label: {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(pendingRenames[section.id] ?? section.title))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowH)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: rowH)
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture(for: section))
        }
        .padding(.horizontal, 4)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(
            color: isDragging ? Color.black.opacity(0.13) : Color.black.opacity(0.06),
            radius: isDragging ? 14 : 8,
            x: 0,
            y: isDragging ? 6 : 3
        )
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .zIndex(isDragging ? 10 : 0)
        .offset(y: isDragging ? displayedDragOffset : 0)
    }

    private func dragGesture(for section: PackingSection) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if draggingId == nil {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        draggingId = section.id
                    }
                    let idx = ordered.firstIndex { $0.id == section.id } ?? 0
                    dragStartIndex = idx
                    dragCurrentIndex = idx
                    dragStartGlobalY = value.startLocation.y
                    dragTranslation = 0
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                guard draggingId == section.id else { return }

                dragTranslation = value.location.y - dragStartGlobalY

                let deltaSlots: Int
                if dragTranslation >= 0 {
                    deltaSlots = Int((dragTranslation + slotH * 0.5) / slotH)
                } else {
                    deltaSlots = Int((dragTranslation - slotH * 0.5) / slotH)
                }
                let tentative = dragStartIndex + deltaSlots
                let target = max(0, min(ordered.count - 1, tentative))

                if target != dragCurrentIndex {
                    let from = dragCurrentIndex
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        ordered.move(
                            fromOffsets: IndexSet(integer: from),
                            toOffset: target > from ? target + 1 : target
                        )
                    }
                    dragCurrentIndex = target
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    draggingId = nil
                    dragTranslation = 0
                }
                dragStartGlobalY = 0
            }
    }

    private var displayedDragOffset: CGFloat {
        dragTranslation - CGFloat(dragCurrentIndex - dragStartIndex) * slotH
    }

    // MARK: - Actions

    private func commitAdd() {
        let name = newSectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let nextOrder = (ordered.map(\.sortOrder).max() ?? -1) + 1
        let blankItem = PackingItem(name: "", isAlert: false, sortOrder: 0)
        let section = PackingSection(title: name, items: [blankItem], sortOrder: nextOrder)
        ordered.append(section)
        pendingNewIds.insert(section.id)
        newSectionName = ""
    }

    private func commitRename() {
        guard let section = renamingSection else { return }
        let name = renameName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { renamingSection = nil; return }
        pendingRenames[section.id] = name
        renamingSection = nil
    }

    private func deleteSection(_ section: PackingSection) {
        ordered.removeAll { $0.id == section.id }
        if pendingNewIds.contains(section.id) {
            pendingNewIds.remove(section.id)
        } else {
            pendingDeleteIds.insert(section.id)
        }
    }

    private func commitDone() {
        for sectionId in pendingDeleteIds {
            store.removeSection(tripId: tripId, sectionId: sectionId)
        }
        for (sectionId, newName) in pendingRenames where !pendingNewIds.contains(sectionId) {
            store.renameSection(tripId: tripId, sectionId: sectionId, newName: newName)
        }
        let newSections = ordered.filter { pendingNewIds.contains($0.id) }
        for section in newSections {
            if let rename = pendingRenames[section.id] { section.title = rename }
        }
        if !newSections.isEmpty {
            store.insertPendingSections(tripId: tripId, sections: newSections)
        }
        onDone(ordered.map(\.id))
        dismiss()
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
