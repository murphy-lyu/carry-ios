//
//  PackingListView.swift
//  Carry
//

import SwiftUI
import UIKit

/// Identifiable wrapper so a freshly-picked photo (its item provider) can drive the reposition
/// `.sheet(item:)`. The image is loaded INSIDE the reposition sheet (so iCloud downloads show a
/// spinner there, not on the packing list).
private struct PickedBackgroundProvider: Identifiable {
    let id = UUID()
    let provider: NSItemProvider
}

// MARK: - PackingListView

/// 行程详情页的两张脸（spec: itinerary-route-planning.md）：打包清单 / 行程路线规划。
private enum DetailTab: Hashable {
    case packing
    case itinerary
}

/// 每个行程「上次看的面」记忆（spec: app-navigation-framework.md）。
/// 已有行程开在「记住的上次面」，仅在无记录时才默认行程规划——
/// 不是「已有行程一律行程规划」（旧注释如此，与实际不符，易误导）。
private enum TripDetailFaceStore {
    private static func key(_ id: UUID) -> String { "trip_detail_face_\(id.uuidString)" }
    static func load(tripId: UUID) -> DetailTab {
        UserDefaults.standard.string(forKey: key(tripId)) == "packing" ? .packing : .itinerary
    }
    static func save(_ face: DetailTab, tripId: UUID) {
        UserDefaults.standard.set(face == .packing ? "packing" : "itinerary", forKey: key(tripId))
    }
}

struct PackingListView: View {

    let tripId: UUID
    var isNewTrip: Bool = false

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.colorScheme) private var colorScheme

    /// 当前选中的面。初始面在 `init` 里就解析好，使**首帧即为正确的面**——
    /// 不再靠 onAppear 把默认 `.packing` 纠正过来（那会在打开「行程规划」行程时，
    /// 于 push 动画里先闪一下打包）。新建流程始终打包；已有行程开在记住的上次面。
    @State private var detailTab: DetailTab

    init(tripId: UUID, isNewTrip: Bool = false) {
        self.tripId = tripId
        self.isNewTrip = isNewTrip
        _detailTab = State(initialValue: isNewTrip ? .packing : TripDetailFaceStore.load(tripId: tripId))
    }

    @StateObject private var weatherManager = WeatherManager()

    @State private var editingItemId: UUID? = nil
    @State private var editingText: String = ""

    @State private var showEditSheet = false
    @State private var showEditScenesSheet = false
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

    @State private var showReminderSheet = false
    @State private var showSuggestSheet = false
    @State private var showBackgroundPicker = false
    @State private var pendingPickedProvider: NSItemProvider?
    @State private var repositionProvider: PickedBackgroundProvider?

    /// 新建预览页内容的入场揭示开关：landing 时由 false→true 驱动 chips 交错淡入上浮。
    /// 用"内容入场"本身作为"已添加"的确认，替代会顶内容的浮层 toast。
    @State private var didRevealPreview = false

    @State private var surpriseItems: [SurpriseItem] = []
    @State private var surpriseItemPool: [SurpriseItem] = []
    @State private var selectedSurpriseNames: Set<String> = []
    @State private var shownSurpriseNames: Set<String> = []

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var sections: [PackingSection] {
        bundle?.safeSections ?? []
    }
    private var hasScenes: Bool { !(bundle?.selectedSceneKeys.isEmpty ?? true) }
    private var totalCount: Int  { bundle?.totalCount  ?? 0 }
    private var packedCount: Int { bundle?.packedCount ?? 0 }
    private var progress: Double {
        totalCount == 0 ? 0 : Double(packedCount) / Double(totalCount)
    }
    private var isComplete: Bool {
        totalCount > 0 && packedCount == totalCount
    }


    var body: some View {
        ZStack {
            CarrySubtleBackground()
            // 两张脸由底部胶囊切换（spec: app-navigation-framework.md）；不再用顶部 Segmented。
            Group {
                switch detailTab {
                case .packing:
                    packingContent
                case .itinerary:
                    ItineraryView(tripId: tripId)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isNewTrip {
                saveTripButton
            } else {
                bottomFaceSwitch
            }
        }
        .onChange(of: detailTab) { _, newFace in
            if !isNewTrip { TripDetailFaceStore.save(newFace, tripId: tripId) }
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
                        .font(.system(.headline, design: .rounded))
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
            // 行程动作「…」两面常驻；打包专属动作仅在打包面出现（spec: app-navigation-framework.md）。
            if !isNewTrip {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if detailTab == .packing {
                            Button {
                                router.path.append(CreationRoute.addItems(tripId))
                            } label: {
                                Label("packing.menu.add_from_library", systemImage: "shippingbox")
                            }
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
                        }
                        Button {
                            showReminderSheet = true
                        } label: {
                            Label("reminder.menu.item", systemImage: bundle?.remindersEnabled == true ? "bell" : "bell.slash")
                        }
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit trip", systemImage: "pencil")
                        }
                        if detailTab == .packing {
                            Button {
                                showReorderSheet = true
                            } label: {
                                Label("Edit sections", systemImage: "arrow.up.arrow.down")
                            }
                        }
                        // Cosmetic, optional — sits below the two Edit actions.
                        // Single entry, toggled by state: has a cover → remove; none → add.
                        if backgroundImage != nil {
                            Button(role: .destructive) {
                                store.clearBackground(forTripId: tripId)
                            } label: {
                                Label("trip.background.remove", systemImage: "trash")
                            }
                        } else {
                            Button {
                                showBackgroundPicker = true
                            } label: {
                                Label("trip.background.add", systemImage: "photo")
                            }
                        }
                        if detailTab == .packing {
                            Button {
                                CarryLogger.shared.log(.packingListShared)
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
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete trip", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
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
            if isNewTrip { loadSurpriseItems() }
            if !isNewTrip { fetchDestinationWeather() }
            // 新建预览：让刚整理好的物品 chips 交错入场，作为"已添加"的确认
            // （取代旧的顶部 toast——后者会把列表顶下去、消失时又弹回，不优雅）。
            if isNewTrip && !didRevealPreview {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.34)) { didRevealPreview = true }
                }
            }
            CarryLogger.shared.log(.tripOpened)
            // Remember this trip so "Continue Packing" shortcut can reopen it.
            UserDefaults.standard.set(tripId.uuidString, forKey: "carry_last_opened_trip")
            if let b = bundle, b.sections == nil {
                CarryLogger.shared.log(.tripDataEmpty, context: "context=onAppear")
            }
            // Live Activity：打开打包清单时自动启动（若用户已开启开关）
#if !targetEnvironment(macCatalyst)
            if let b = bundle {
                Task { @MainActor in LiveActivityManager.shared.startIfNeeded(for: b) }
            }
#endif
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
        .onChange(of: showSuggestSheet) { _, isShowing in
            guard !isShowing, isNewTrip else { return }
            loadSurpriseItems()
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
        .sheet(isPresented: $showBackgroundPicker, onDismiss: {
            // Present the reposition sheet only after the picker fully dismisses (avoids the
            // two-sheets-at-once race). The image then loads INSIDE the reposition sheet.
            if let provider = pendingPickedProvider {
                pendingPickedProvider = nil
                repositionProvider = PickedBackgroundProvider(provider: provider)
            }
        }) {
            PhotoPicker(
                onPick: { provider in
                    pendingPickedProvider = provider
                    showBackgroundPicker = false
                },
                onCancel: { showBackgroundPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $repositionProvider) { picked in
            BackgroundRepositionView(provider: picked.provider) { finalImage, crop in
                if let name = BackgroundImageStore.save(finalImage) {
                    store.setLocalBackground(fileName: name, crop: crop, forTripId: tripId)
                    // The cover shows on the home card, not here — a success haptic confirms
                    // the save registered (the detail screen otherwise doesn't visibly change).
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
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

    // MARK: - 底部胶囊切换（行程 ｜ 打包）

    /// 拇指可达的底部切换。居中悬浮，区别于通用 Tab 栏的「程序化」。
    private var bottomFaceSwitch: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                faceSegment(.itinerary, title: "detail.tab.itinerary", icon: "map")
                faceSegment(.packing, title: "detail.tab.packing", icon: "checklist")
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.04)
                            : Color.black.opacity(0.03)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 14, x: 0, y: 5)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(UIColor.systemBackground).opacity(0.0),
                    Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.92 : 0.96),
                    Color(UIColor.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func faceSegment(_ face: DetailTab, title: LocalizedStringKey, icon: String) -> some View {
        let selected = detailTab == face
        return Button {
            guard detailTab != face else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { detailTab = face }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            CarryLogger.shared.log(.detailFaceSwitched, context: "to=\(face == .packing ? "packing" : "itinerary")")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CarryAccent.color)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 打包内容 + 「点空白处收起内联编辑/键盘」手势。该手势**只作用于打包页**——
    /// 早先放在根 ZStack 上时会吞掉行程页 List 行内按钮的 touch-up（导致加停靠点/加一天无响应）。
    private var packingContent: some View {
        mainContent
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
    }

    private var mainContent: some View {
        ZStack(alignment: .top) {
            contentSurface

            if sections.isEmpty {
                emptyState
            } else if isNewTrip {
                previewPackingList
            } else {
                normalPackingList
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

    private var backgroundImage: UIImage? {
        guard let entry = bundle?.primaryBackground, let name = entry.localFileName else { return nil }
        return BackgroundImageStore.image(named: name)
    }

    /// 新建预览模式：纯展示内容（件数行 / chips / surprise / scenePrompt），无重排需求，沿用 List。
    private var previewPackingList: some View {
        List {
            if totalCount > 0 {
                Section {
                    previewSummaryRow
                        .opacity(didRevealPreview ? 1 : 0)
                        .offset(y: didRevealPreview ? 0 : 12)
                        .animation(.easeOut(duration: 0.34), value: didRevealPreview)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)
            }

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Section {
                    previewChipsRow(items: section.sortedItems.filter { !$0.name.isEmpty })
                        .opacity(didRevealPreview ? 1 : 0)
                        .offset(y: didRevealPreview ? 0 : 12)
                        .animation(.easeOut(duration: 0.34).delay(Double(min(index, 6)) * 0.05), value: didRevealPreview)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    sectionTitle(section.title, isFirst: index == 0)
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSeparator(.hidden)
            }

            if hasScenes && !surpriseItems.isEmpty {
                Section {
                    ForEach(surpriseItems) { item in
                        surpriseItemRow(item)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    surpriseSectionHeader
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSeparator(.hidden)
                .opacity(didRevealPreview ? 1 : 0)
                .offset(y: didRevealPreview ? 0 : 12)
                .animation(.easeOut(duration: 0.34).delay(Double(min(sections.count, 6)) * 0.05), value: didRevealPreview)
            }

            if !hasScenes {
                Section {
                    scenePromptCard
                        .opacity(didRevealPreview ? 1 : 0)
                        .offset(y: didRevealPreview ? 0 : 12)
                        .animation(.easeOut(duration: 0.34).delay(Double(min(sections.count, 6)) * 0.05), value: didRevealPreview)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .listSectionSpacing(0)
        .scrollIndicators(.hidden)
        .safeAreaPadding(.bottom, 83)
    }

    /// 正常模式：UICollectionView 原生 interactive movement 列表（长按拖拽 1:1 跟手）。
    private var normalPackingList: some View {
        ReorderableItemCollection(
            sections: sections.map { section in
                ReorderableItemCollection.Section(
                    id: section.id,
                    title: section.title,
                    isFirst: false,
                    itemIDs: section.sortedItems
                        .filter { !$0.name.isEmpty || $0.id == editingItemId }
                        .map(\.id)
                )
            },
            editingItemId: editingItemId,
            infoContent: destinationInfoContent,
            itemContent: { id in AnyView(itemRowContent(id: id)) },
            editingContent: { id in AnyView(inlineEditRowContent(itemId: id)) },
            addContent: { sid in
                AnyView(
                    addItemRow(sectionId: sid)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                )
            },
            headerContent: { model in AnyView(sectionTitle(model.title, isFirst: model.isFirst)) },
            onDelete: { deleteItem(itemId: $0) },
            onReorder: { sid, ids in store.reorderItems(tripId: tripId, sectionId: sid, newOrder: ids) },
            onReorderBegan: {
                // 起拖前提交在编辑的行；起拖触感由 collection 的 liftHaptic 负责。
                if let id = editingItemId { commitEdit(itemId: id) }
            }
        )
        .ignoresSafeArea(.container, edges: .bottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            if showCompletionBanner {
                completionBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// DestinationInfo 作为 collection 顶部不可重排行（随列表滚动）。无则 nil。
    private var destinationInfoContent: (() -> AnyView)? {
        guard let trip = bundle,
              trip.departureDate >= Calendar.current.startOfDay(for: Date()) else { return nil }
        return {
            AnyView(
                DestinationInfoView(trip: trip, weatherManager: weatherManager)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            )
        }
    }

    @ViewBuilder
    private func itemRowContent(id: UUID) -> some View {
        if let item = packingItem(id) {
            PackingItemRow(
                item: item,
                showCheckmark: true,
                showQuantity: true,
                onTap: { toggleItem(itemId: id) },
                onDecrement: { decrementItemQuantity(itemId: id, current: item.quantity) },
                onIncrement: { incrementItemQuantity(itemId: id, current: item.quantity) },
                onSetQuantity: { store.updateItemQuantity(tripId: tripId, itemId: id, quantity: $0) }
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func inlineEditRowContent(itemId: UUID) -> some View {
        InlineEditRow(
            text: $editingText,
            onEnd: { if editingItemId == itemId { commitEdit(itemId: itemId) } }
        )
        .padding(.horizontal, 22)
        .padding(.vertical, 4)
    }

    private func packingItem(_ id: UUID) -> PackingItem? {
        for section in sections {
            if let item = (section.items ?? []).first(where: { $0.id == id }) { return item }
        }
        return nil
    }


    // MARK: Actions

    private func fetchDestinationWeather() {
        guard let trip = bundle, !trip.isDateless, trip.latitude != 0 else { return }
        let start = trip.departureDate
        let end = Calendar.current.date(byAdding: .day, value: max(trip.days - 1, 0), to: start) ?? start
        var dests: [(index: Int, lat: Double, lon: Double)] = [
            (index: 0, lat: trip.latitude, lon: trip.longitude)
        ]
        for (i, extra) in trip.additionalDestinations.enumerated() where extra.latitude != 0 {
            dests.append((index: i + 1, lat: extra.latitude, lon: extra.longitude))
        }
        weatherManager.fetchAll(destinations: dests, tripStartDate: start, tripEndDate: end)
    }

    private func loadSurpriseItems() {
        guard let bundle = bundle else { return }
        let existingLower = Set(
            bundle.safeSections.flatMap { $0.items ?? [] }
                .filter { !$0.name.isEmpty }
                .map { $0.name.lowercased() }
        )
        let sceneKeys = bundle.selectedSceneKeys
        let mode: SurpriseRankingMode = sceneKeys.isEmpty ? .manualFirst : .sceneFirst
        let dismissed = Set(bundle.dismissedSurpriseNames.map { $0.lowercased() })
        let pool = computeSurpriseItems(
            for: sceneKeys,
            existingNames: existingLower,
            rankingMode: mode
        )
        .filter { !dismissed.contains($0.name.lowercased()) }
        surpriseItemPool = pool
        surpriseItems = Array(pool.prefix(3))
        selectedSurpriseNames = []
        shownSurpriseNames = Set(surpriseItems.map(\.name))
    }

    private func shuffleSurpriseItems() {
        let currentNames = Set(surpriseItems.map(\.name))
        let remaining = surpriseItemPool.filter { !currentNames.contains($0.name) }
        guard !remaining.isEmpty else { return }
        let picks = Array(remaining.shuffled().prefix(3))
        surpriseItems = picks
        shownSurpriseNames.formUnion(picks.map(\.name))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

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

    // MARK: Share

    private var shareText: String {
        guard let bundle = bundle else { return "" }
        let sep = String(repeating: "━", count: 32)
        var lines: [String] = []
        let packedFormat = NSLocalizedString("%lld / %lld packed", comment: "Packed count over total count")

        // — Header
        let heading = [bundle.name, bundle.destinationCity]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        lines.append("🧳 \(heading)")
        lines.append("")
        if !bundle.isDateless {
            // 「A 天 B 晚」：天 = 含两端实际天数(spanDays)、晚 = 晚数(days)；与日期选择器同口径。
            let span = String(format: NSLocalizedString("date.days_nights", comment: "Trip span: N days M nights"),
                              Int64(bundle.spanDays), Int64(bundle.days))
            lines.append("📅 \(bundle.localizedDateRange) · \(span)")
        }
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
            .padding(.horizontal, 16)

            tripInfoCard
                .padding(.top, 6)
                .padding(.horizontal, 16)

        }
        .zIndex(2)
        .padding(.top, 10)
        .padding(.bottom, 0)
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
        guard let bundle else { return nil }
        // 无日期「规划中」行程：头部不显示占位日期，改显示规划标签——清单页是独立上下文
        //（没有首页「规划中」分区标题兜底），需自己传达"这是计划、日期待定"。
        if bundle.isDateless {
            return NSLocalizedString("packing.header.planning", comment: "Planning trip header, no dates set")
        }
        let date = bundle.localizedDateRange
        guard !date.isEmpty else { return nil }
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
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemBackground))
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
        return String(format: NSLocalizedString("%lld left", comment: ""), Int64(totalCount - packedCount))
    }

    private var scenePromptCard: some View {
        Button {
            showSuggestSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.7) : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add recommended items")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("packing.scene_card.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color(UIColor.secondarySystemBackground).opacity(0.6)
                    : Color(UIColor.systemBackground).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.06), lineWidth: 1)
        )
    }

    private var surpriseSectionHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                Text("Nice to have")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                    .kerning(1.2)
                    .textCase(.uppercase)
            }
            Spacer()
            if surpriseItemPool.count > 3 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shuffleSurpriseItems()
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.primary.opacity(0.03))
                .frame(height: 1)
        }
        .background(Rectangle().fill(Color(UIColor.systemBackground)))
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
                    Circle().fill(isSelected ? CarryAccent.color : Color.clear)
                    Circle().strokeBorder(isSelected ? CarryAccent.color : Color.secondary.opacity(0.4), lineWidth: 1.5)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 单一表面居中列，与首页/行程空态同构：图标 → rounded 标题 → 副标题 → 统一 CTA 胶囊。
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "suitcase")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("packing.empty.title")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("packing.empty.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // CTA：全 App 空态统一胶囊（与首页/行程空态共用 CarryEmptyStatePrimaryButtonStyle）。
            Button {
                if sections.isEmpty {
                    showAddItemsRoute = true
                } else {
                    router.path.append(CreationRoute.addItems(tripId))
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Add item")
                }
            }
            .buttonStyle(CarryEmptyStatePrimaryButtonStyle())
            .padding(.top, 6)

            Spacer()
        }
        .padding(.horizontal, 24)
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
            // Keep internal spacing unchanged; only nudge the whole pinned header up
            // to eliminate the 1pt seam between top bar and section header layer.
            .offset(y: -1)
            .zIndex(3)
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
                let poolSnapshot = surpriseItemPool
                let selectedSnapshot = selectedSurpriseNames
                let shownSnapshot = shownSurpriseNames
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if isNewTrip {
                        for item in poolSnapshot {
                            if selectedSnapshot.contains(item.name) {
                                store.addSurpriseItem(tripId: tripId, item: item)
                            } else if shownSnapshot.contains(item.name) {
                                store.dismissSurpriseItem(tripId: tripId, itemName: item.name)
                            }
                        }
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

    /// 新建预览顶部的常驻件数行——保留旧 toast 唯一的信息量（已整理的件数），
    /// 但它在布局里固定存在、随增删实时更新，不会出现/消失，因而不会顶动列表。
    private var previewSummaryRow: some View {
        Text(String.localizedStringWithFormat(
            NSLocalizedString("packing.preview.summary", comment: ""), totalCount))
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        // 失焦由 InlineEditRow 内部 @FocusState 管；这里负责收起键盘并提交在编辑的行
        // （响应清单区域的全局点击）。
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
        // 先提交当前在编辑的行，再插入新空行；新行的 InlineEditRow 出现即自动聚焦。
        if let id = editingItemId { commitEdit(itemId: id) }
        let newId = store.addItem(tripId: tripId, sectionIndex: sectionIndex)
        editingItemId = newId
        editingText = ""
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
                    Spacer(minLength: 24)
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
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                // 让空状态在 ScrollView 可视区（导航栏与底部栏之间）内垂直居中，
                // 而非整屏居中：内容高度对齐容器可视高度，再由对称 Spacer 居中。
                .containerRelativeFrame(.vertical, alignment: .center)
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

// MARK: - InlineEditRow

/// 正常模式下新增物品的内联编辑行。自带 @FocusState：cell 出现即聚焦（编辑行永远是
/// 新插入的 cell，onAppear 聚焦可靠）；回车或失焦时回调提交。样式对齐旧 editableRow。
private struct InlineEditRow: View {
    @Binding var text: String
    let onEnd: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 24, height: 24)

            TextField("", text: $text)
                .font(.subheadline)
                .tint(.primary)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { focused = false }
                .textFieldStyle(.plain)

            Spacer()

            Circle()
                .fill(Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(height: 44)
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onEnd() }
        }
    }
}

// MARK: - Preview

#Preview {
    PackingListView(tripId: UUID())
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
}
