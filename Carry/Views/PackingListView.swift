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
    @State private var showAddSectionAlert = false
    @State private var newSectionName = ""
    @State private var showAddItemsRoute = false
    @State private var isSaved = false
    @State private var showConfetti = false
    @State private var showCompletionBanner = false
    @State private var hasTriggeredCompletion = false
    @State private var shimmerPhase: CGFloat = -1
    @State private var showNudgeBanner = false
    @State private var hasTriggeredNudge = false
    @State private var surpriseBatchOffset: Int = 0
    @State private var showReminderSheet = false
    @State private var showSceneCardDismissHintBanner = false
    @State private var draggingItemId: UUID? = nil
    @State private var dragStartIds: [UUID] = []
    @State private var dragStartIndex: Int = 0
    @State private var currentDragIndex: Int = 0
    @State private var toastVisible = false
    @State private var toastText = ""

    private let surpriseBatchSize = 1

    // Cached — recomputed only when store.trips or store.myItems changes,
    // not on every body re-evaluation (inline edit keystrokes, toggle taps, etc.)
    @State private var cachedSurpriseItems: [SurpriseItem] = []

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var sections: [PackingSection] {
        bundle?.safeSections ?? []
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

    private var surpriseItems: [SurpriseItem] { cachedSurpriseItems }

    private func rebuildSurpriseItems() {
        guard let bundle else { cachedSurpriseItems = []; return }
        let existingNames = Set(
            bundle.safeSections.flatMap { $0.items ?? [] }.map { canonicalItemName($0.name).lowercased() }
        )
        let myItemNames = Set(
            store.myItems.map { canonicalItemName($0.name).lowercased() }
        )
        let dismissed = Set(bundle.dismissedSurpriseNames.map { $0.lowercased() })
        let rankingMode: SurpriseRankingMode = hasScenes ? .sceneFirst : .manualFirst
        cachedSurpriseItems = computeSurpriseItems(
            for: bundle.selectedSceneKeys,
            existingNames: existingNames.union(myItemNames),
            rankingMode: rankingMode
        )
            .filter { !dismissed.contains($0.name.lowercased()) }
    }

    private var visibleSurpriseItems: [SurpriseItem] {
        guard !cachedSurpriseItems.isEmpty else { return [] }
        let total = cachedSurpriseItems.count
        guard total > surpriseBatchSize else { return cachedSurpriseItems }
        return (0..<surpriseBatchSize).map { i in cachedSurpriseItems[(surpriseBatchOffset + i) % total] }
    }

    private var canShuffle: Bool { cachedSurpriseItems.count > surpriseBatchSize }

    var body: some View {
        ZStack {
            CarrySubtleBackground()
            mainContent
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
            }
        }
        .coordinateSpace(name: "packingRoot")
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        .navigationTitle(bundle?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(bundle?.name ?? "")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)

                    if let dateRange = tripDateRangeLine {
                        Text(dateRange)
                            .font(.caption2)
                            .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.78) : Color.secondary.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
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
                    if !isNewTrip {
                        Button {
                            router.path.append(CreationRoute.addItems(tripId))
                        } label: {
                            Label("packing.menu.add_from_library", systemImage: "shippingbox")
                        }
                    }
                    if !isNewTrip {
                        Button {
                            showReorderSheet = true
                        } label: {
                            Label("Edit sections", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    if !isNewTrip {
                        Button {
                            showReminderSheet = true
                        } label: {
                            Label("reminder.menu.item", systemImage: bundle?.remindersEnabled == true ? "bell" : "bell.slash")
                        }
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
                        Divider()
                        if totalCount > 0 {
                            Button {
                                if isComplete {
                                    markTripUncompleted()
                                } else {
                                    markTripCompleted()
                                }
                            } label: {
                                Label(isComplete ? "packing.mark_uncomplete" : "packing.mark_complete", systemImage: isComplete ? "arrow.uturn.left.circle" : "checkmark.circle")
                            }
                        }
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
            rebuildSurpriseItems()
            CarryLogger.shared.log(.tripOpened)
            // Remember this trip so "Continue Packing" shortcut can reopen it.
            UserDefaults.standard.set(tripId.uuidString, forKey: "carry_last_opened_trip")
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
        .onChange(of: store.trips) { _, _ in
            rebuildSurpriseItems()
        }
        .onDisappear {
            store.refresh()
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
        .alert("New section", isPresented: $showAddSectionAlert) {
            TextField("Section name", text: $newSectionName)
            Button("Create") {
                addSectionFromEmptyState()
            }
            Button("Cancel", role: .cancel) {
                newSectionName = ""
            }
        }
        .onChange(of: showAddItemsRoute) { _, newValue in
            guard newValue else { return }
            router.path.append(CreationRoute.addItems(tripId))
            showAddItemsRoute = false
        }
        .sheet(isPresented: $showReminderSheet) {
            if let bundle = bundle {
                TripReminderSheet(bundle: bundle)
                    .environmentObject(store)
            }
        }
        .alert(
            String(format: NSLocalizedString("Delete %@?", comment: ""), bundle?.name ?? ""),
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

    private var mainContent: some View {
        ZStack(alignment: .top) {
            contentSurface

            VStack(spacing: 0) {
                if toastVisible {
                    toastBanner
                }

                if sections.isEmpty {
                    emptyState
                } else {
                    packingList
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isNewTrip {
                progressHeader
            }
        }
    }

    private var contentSurface: some View {
        Color(UIColor.systemBackground)
            .ignoresSafeArea()
    }

    private var packingList: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Section {
                    if isNewTrip {
                        previewChipsRow(items: section.sortedItems.filter { !$0.name.isEmpty })
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(section.sortedItems.filter { !$0.name.isEmpty || $0.id == editingItemId }, id: \.id) { item in
                            row(for: item, sectionId: section.id)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        addItemRow(sectionId: section.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    sectionTitle(section.title, isFirst: index == 0)
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSeparator(.hidden)
            }

            if isNewTrip && !sceneCardDismissed {
                Section {
                    sceneEntryCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, isNewTrip ? 8 : 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .listSectionSpacing(0)
        .scrollIndicators(.hidden)
        .safeAreaPadding(.bottom, 83)
        .safeAreaInset(edge: .top, spacing: 0) {
            if showCompletionBanner || showNudgeBanner || showSceneCardDismissHintBanner {
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

    @ViewBuilder
    private func row(for item: PackingItem, sectionId: UUID) -> some View {
        contentRow(for: item, sectionId: sectionId)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Do NOT use role: .destructive — it maps to UIContextualAction(.destructive)
                // which plays a UIKit expand-then-collapse animation on tap, causing a ghost
                // artifact. A plain button with .tint(.red) gives identical visuals without
                // the animation, and the explicit white foreground fixes dark-mode visibility.
                Button {
                    deleteItem(itemId: item.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.white)
                }
                .tint(.red)
            }
    }

    @ViewBuilder
    private func contentRow(for item: PackingItem, sectionId: UUID) -> some View {
        if editingItemId == item.id {
            editableRow(itemId: item.id, sectionId: sectionId)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        } else {
            PackingItemRow(
                item: item,
                showCheckmark: !isNewTrip,
                showQuantity: !isNewTrip,
                onTap: {
                    toggleItem(itemId: item.id)
                },
                onDecrement: { decrementItemQuantity(itemId: item.id, current: item.quantity) },
                onIncrement: { incrementItemQuantity(itemId: item.id, current: item.quantity) },
                onSetQuantity: { newValue in
                    store.updateItemQuantity(tripId: tripId, itemId: item.id, quantity: newValue)
                }
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .allowsHitTesting(draggingItemId == nil)
            .opacity(draggingItemId != nil && draggingItemId != item.id ? 0.55 : 1.0)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(draggingItemId == item.id ? 0.45 : 0), lineWidth: 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(draggingItemId == item.id ? 0.05 : 0))
                    )
                    .padding(.vertical, 2)
            }
            .scaleEffect(draggingItemId == item.id ? 1.04 : 1.0)
            .shadow(
                color: draggingItemId == item.id ? .black.opacity(0.18) : .clear,
                radius: 10, x: 0, y: 5
            )
            .animation(.easeInOut(duration: 0.18), value: draggingItemId == item.id)
            .animation(.easeInOut(duration: 0.18), value: draggingItemId != nil)
            .background(
                LongPressDragBridge(
                    onBegan: {
                        guard !isNewTrip else { return }
                        guard let section = sections.first(where: { $0.id == sectionId }) else { return }
                        let sectionItems = section.sortedItems.filter { !$0.name.isEmpty }
                        dragStartIds = sectionItems.map(\.id)
                        dragStartIndex = sectionItems.firstIndex(where: { $0.id == item.id }) ?? 0
                        currentDragIndex = dragStartIndex
                        draggingItemId = item.id
                    },
                    onChanged: { translation in
                        guard draggingItemId == item.id else { return }
                        let delta = Int((translation / 44).rounded())
                        let newIndex = max(0, min(dragStartIds.count - 1, dragStartIndex + delta))
                        guard newIndex != currentDragIndex else { return }
                        currentDragIndex = newIndex
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        var ids = dragStartIds
                        guard let fromIdx = ids.firstIndex(of: item.id) else { return }
                        ids.remove(at: fromIdx)
                        ids.insert(item.id, at: min(newIndex, ids.count))
                        store.reorderItems(tripId: tripId, sectionId: sectionId, newOrder: ids)
                    },
                    onEnded: {
                        draggingItemId = nil
                        dragStartIds = []
                        dragStartIndex = 0
                        currentDragIndex = 0
                    }
                )
            )
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
    private func markTripCompleted() {
        store.markTripCompleted(tripId: tripId)
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

    private func markTripUncompleted() {
        store.markTripUncompleted(tripId: tripId)
        hasTriggeredCompletion = false
        showConfetti = false
        showCompletionBanner = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
            let allPackedFormat = NSLocalizedString("packing.share.all_packed", comment: "")
            lines.append("📊 \(String(format: allPackedFormat, Int64(totalCount)))")
        } else {
            lines.append("📊 \(String(format: packedFormat, locale: Locale.current, Int64(packedCount), Int64(totalCount)))")
        }

        // — Sections
        lines.append("")
        lines.append(sep)
        lines.append("🧳 \(NSLocalizedString("packing.share.list_title", comment: ""))")
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
        lines.append(NSLocalizedString("packing.share.footer", comment: ""))
        lines.append(sep)
        return lines.joined(separator: "\n")
    }

    // MARK: Subviews

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color(UIColor.systemGray5).opacity(0.82))
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
                            .frame(width: geo.size.width * 0.38)
                            .offset(x: shimmerPhase * geo.size.width * 0.675)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                }
            }
            .frame(height: 2.5)

            tripInfoCard
                .padding(.top, 6)
        }
        .zIndex(2)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: progress)
    }

    private var tripInfoCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(colorScheme == .dark ? 0.9 : 0.82))
                    Text(packingStatusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.75 : 0.65))
                }
                    .animation(.easeInOut(duration: 0.2), value: packedCount)
                    .animation(.easeInOut(duration: 0.2), value: totalCount)

                Spacer(minLength: 8)

                Button {
                    showReminderSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: reminderStatusIconName)
                            .font(.system(size: 9, weight: .semibold))
                        Text(reminderStatusText)
                            .font(.caption2.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.94) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.022))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.02), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private var tripInfoLine: String {
        [bundle?.destinationCity, bundle?.localizedDateRange]
            .compactMap { str in (str?.isEmpty == false) ? str : nil }
            .joined(separator: " · ")
    }

    private var tripDateRangeLine: String? {
        guard let date = bundle?.localizedDateRange, !date.isEmpty else { return nil }
        return date
    }

    private var completionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.primary.opacity(0.72) : Color.primary.opacity(0.82))
                .frame(width: 22, height: 22)
                .background(Circle().fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.primary.opacity(0.045)))
            Text("packing.complete.banner")
                .foregroundStyle(.primary)
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: 1)
                .padding(.horizontal, 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: 1)
                .padding(.horizontal, 0)
        }
    }

    private var reminderStatusText: String {
        let count = bundle?.reminderConfigs.count ?? 0
        if count == 0 {
            return NSLocalizedString("reminder.menu.item", comment: "")
        }
        if count == 1 {
            return NSLocalizedString("trip.reminder.count.one", comment: "")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("trip.reminders.count", comment: ""),
            count
        )
    }

    private var reminderStatusIconName: String {
        let count = bundle?.reminderConfigs.count ?? 0
        let remindersEnabled = bundle?.remindersEnabled == true
        if !remindersEnabled || count == 0 {
            return "bell.slash"
        }
        return "bell.fill"
    }

    private var packingStatusText: String {
        if totalCount == 0 {
            return NSLocalizedString("packing.empty.items", comment: "")
        }
        if isComplete {
            return NSLocalizedString("packing.complete.short", comment: "")
        }
        return String(format: NSLocalizedString("packing.items.left", comment: ""), Int64(totalCount - packedCount))
    }

    private var sceneEntryCard: some View {
        Button { showSuggestSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.orange.opacity(0.88) : Color.orange)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(colorScheme == .dark ? Color.orange.opacity(0.14) : Color.orange.opacity(0.12)))
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
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.82) : Color(UIColor.systemBackground).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.035) : Color.primary.opacity(0.035), lineWidth: 1)
        )
        .padding(.vertical, 2)
        .overlay(alignment: .trailing) {
            Button {
                store.dismissSceneCard(tripId: tripId)
                CarryLogger.shared.log(.sceneCardDismissed)
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
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.indigo.opacity(0.88) : Color.indigo)
                .frame(width: 28, height: 28)
                .background(Circle().fill(colorScheme == .dark ? Color.indigo.opacity(0.14) : Color.indigo.opacity(0.12)))
            Text("Almost there! A few things worth a second thought ↓")
                .foregroundStyle(.primary)
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.88) : Color(UIColor.systemBackground).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var sceneCardDismissHintBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
            Text("scene_card.dismissed.message")
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.88) : Color(UIColor.systemBackground).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var surpriseSectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Worth considering")
                .font(.caption.bold())
                .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
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
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.primary.opacity(0.03))
                .frame(height: 1)
        }
        .background(
            Rectangle()
                .fill(Color(UIColor.systemBackground))
        )
        .zIndex(1)
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
                CarryLogger.shared.log(.surpriseItemAdded, context: "item=\(item.name)")
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
                CarryLogger.shared.log(.surpriseItemDismissed, context: "item=\(item.name)")
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(Color(UIColor.systemGray3))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "suitcase")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("packing.empty.title")
                .font(.headline)
                .foregroundColor(.primary)
            Text("packing.empty.subtitle")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)

            VStack(spacing: 10) {
                Button {
                    if sections.isEmpty {
                        showAddItemsRoute = true
                    } else {
                        router.path.append(CreationRoute.addItems(tripId))
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add item")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.primary.opacity(0.055))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.06), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)

            Spacer()
            if isNewTrip && !sceneCardDismissed {
                sceneEntryCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String, isFirst: Bool) -> some View {
        Text(LocalizedStringKey(title))
            .font(.caption.weight(.medium))
            .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
            .kerning(1.2)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.primary.opacity(0.03))
                    .frame(height: 1)
            }
            .background(
                Rectangle()
                    .fill(Color(UIColor.systemBackground))
            )
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
                .textFieldStyle(.plain)

            Spacer()

            Circle()
                .fill(Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(height: 44)
    }

    private func previewChipsRow(items: [PackingItem]) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(items) { item in
                Text(LocalizedStringKey(item.name))
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(.secondarySystemFill)))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
    }

    private func addItemRow(sectionId: UUID) -> some View {
        Button {
            appendNewItem(sectionId: sectionId)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Add item")
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(addItemTextTint)
            .frame(height: 28)
            .padding(.horizontal, 2)
            .opacity(isComplete ? 0.55 : 0.78)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func addSectionFromEmptyState() {
        let name = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = store.addSection(tripId: tripId, name: name)
        newSectionName = ""
    }

    private var addItemTint: Color {
        if colorScheme == .dark {
            return isComplete ? Color.primary.opacity(0.32) : Color.primary.opacity(0.58)
        } else {
            return isComplete ? Color.primary.opacity(0.48) : Color.primary.opacity(0.72)
        }
    }

    private var addItemBadgeFill: Color {
        if colorScheme == .dark {
            return isComplete ? Color.white.opacity(0.02) : Color.white.opacity(0.04)
        } else {
            return isComplete ? Color.primary.opacity(0.025) : Color.primary.opacity(0.05)
        }
    }

    private var addItemTextTint: Color {
        if colorScheme == .dark {
            return isComplete ? Color.secondary.opacity(0.42) : Color.secondary.opacity(0.76)
        } else {
            return isComplete ? Color.secondary.opacity(0.48) : Color.secondary.opacity(0.72)
        }
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
                    if isNewTrip {
                        let city = store.bundle(for: tripId)?.destinationCity ?? ""
                        store.commitDraftTrip()
                        if !city.isEmpty {
                            store.updateCountryCode(for: tripId, city: city)
                        }
                    }
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
                .background(Color(UIColor.label))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.08), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.2), value: isSaved)
            }
            .buttonStyle(SolidPressButtonStyle())
            .allowsHitTesting(!isSaved)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Color(UIColor.systemBackground))
    }

    private var toastBanner: some View {
        Text(toastText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func showToast(_ messageKey: String) {
        toastText = NSLocalizedString(messageKey, comment: "")
        withAnimation(.easeInOut(duration: 0.2)) {
            toastVisible = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toastVisible = false
                }
            }
        }
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
    var showCheckmark: Bool = true
    var showQuantity: Bool = true
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
    @FocusState private var focusedQuantityField: Bool

    init(
        item: PackingItem,
        showCheckmark: Bool = true,
        showQuantity: Bool = true,
        onTap: @escaping () -> Void,
        onDecrement: (() -> Void)? = nil,
        onIncrement: (() -> Void)? = nil,
        onSetQuantity: ((Int) -> Void)? = nil,
    ) {
        self.item = item
        self.showCheckmark = showCheckmark
        self.showQuantity = showQuantity
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
            if showQuantity {
                quantityControl
            }
            HStack(spacing: 18) {
                Text(LocalizedStringKey(item.name))
                    .font(.callout)
                    .foregroundColor(item.isPacked ? Color(.secondaryLabel) : .primary)
                    .strikethrough(item.isPacked)
                    .opacity(item.isPacked ? (colorScheme == .dark ? 0.60 : 0.52) : 1.0)

                Spacer()

                if showCheckmark {
                    Spacer(minLength: 10)
                    ZStack {
                        Circle()
                            .strokeBorder(
                                item.isPacked
                                    ? Color(.systemGray2).opacity(colorScheme == .dark ? 0.9 : 1.0)
                                    : Color.primary.opacity(colorScheme == .dark ? 0.7 : 0.6),
                                lineWidth: 1.4
                            )
                            .background(
                                Circle().fill(item.isPacked ? Color(.systemGray2).opacity(colorScheme == .dark ? 0.85 : 1.0) : Color.clear)
                            )
                            .frame(width: 24, height: 24)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(UIColor.systemBackground))
                            .scaleEffect(checkmarkScale)
                            .opacity(checkmarkOpacity)
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(minHeight: 44)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.isPacked)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
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
                        .textFieldStyle(.plain)
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
                        ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)
                        : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isEditingQuantity
                        ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.11)
                        : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.05),
                    lineWidth: isEditingQuantity ? 0.9 : 0.75
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(item.isPacked ? 0.72 : 1.0)
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
    @Environment(\.colorScheme) private var colorScheme

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
            if ordered.isEmpty {
                VStack(spacing: 16) {
                    Spacer(minLength: 90)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No sections yet")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Create a section to organize your packing list.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    Button {
                        newSectionName = ""
                        showAddAlert = true
                    } label: {
                        Label("New section", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(PressableScaleButtonStyle(scale: 0.985, pressedBrightness: -0.02, pressedOpacity: 0.95))
                    .padding(.horizontal, 16)
                    Spacer(minLength: 90)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: rowGap) {
                    ForEach(ordered) { section in
                        rowView(section: section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
        }
        .scrollDisabled(draggingId != nil)
        .background(CarrySubtleBackground())
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
            Button("Create") { commitAdd() }
            Button("Cancel", role: .cancel) { newSectionName = "" }
        }
        .alert("Rename", isPresented: showRenameAlert) {
            TextField("Section name", text: $renameName)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSection = nil }
        }
        .onAppear {
            ordered = store.bundle(for: tripId)?.safeSections ?? []
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
                HStack(spacing: 12) {
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

            HStack(spacing: 18) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: rowH)
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture(for: section))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color(UIColor.secondarySystemBackground).opacity(0.64)
                    : Color(UIColor.systemBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.05), lineWidth: 1)
        )
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

// MARK: - My Items Collection Picker

private struct MyItemsCollectionPickerView: View {
    @Binding var selectedCollection: String
    let collections: [String]
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var visibleCollections: [String] {
        collections.isEmpty ? ["Default"] : collections
    }

    var body: some View {
        Form {
            Section {
                ForEach(visibleCollections, id: \.self) { collection in
                    Button {
                        selectedCollection = collection
                    } label: {
                        HStack {
                            Text(collection)
                            if collection == "Default" {
                                Text("Default collection")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedCollection == collection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Choose where this item should be saved.")
            }
        }
        .navigationTitle("Save to Collection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onConfirm()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - LongPressDragBridge

private struct LongPressDragBridge: UIViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        // Only search for the cell once — skip the view-tree walk on every
        // subsequent SwiftUI update (inline edit keystrokes, etc.)
        guard context.coordinator.attachedRecognizer == nil else { return }
        DispatchQueue.main.async {
            var v: UIView? = uiView
            while let current = v {
                if let cell = current as? UICollectionViewCell {
                    let alreadyAttached = (cell.gestureRecognizers ?? []).contains {
                        ($0 as? UILongPressGestureRecognizer)?.delegate === context.coordinator
                    }
                    if !alreadyAttached {
                        let r = UILongPressGestureRecognizer(
                            target: context.coordinator,
                            action: #selector(Coordinator.handle(_:))
                        )
                        r.minimumPressDuration = 0.4
                        r.allowableMovement = 10
                        r.cancelsTouchesInView = false
                        r.delaysTouchesBegan = false
                        r.delaysTouchesEnded = false
                        r.delegate = context.coordinator
                        cell.addGestureRecognizer(r)
                        context.coordinator.attachedRecognizer = r
                    }
                    break
                }
                v = current.superview
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: (() -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        weak var attachedRecognizer: UILongPressGestureRecognizer?
        private var startY: CGFloat = 0
        private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)

        @objc func handle(_ r: UILongPressGestureRecognizer) {
            guard let view = r.view?.superview else { return }
            let y = r.location(in: view).y
            switch r.state {
            case .began:
                startY = y
                impactFeedback.prepare()
                DispatchQueue.main.async { self.onBegan?() }
                impactFeedback.impactOccurred()
            case .changed:
                DispatchQueue.main.async { self.onChanged?(y - self.startY) }
            case .ended, .cancelled, .failed:
                DispatchQueue.main.async { self.onEnded?() }
            default: break
            }
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

// MARK: - Preview

#Preview {
    PackingListView(tripId: UUID())
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
}
