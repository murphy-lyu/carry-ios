//
//  ItineraryReorderCollection.swift
//  Carry
//
//  行程停靠点的可重排容器——复刻打包清单 ReorderableItemCollection 的原生 interactive
//  movement（长按 1:1 跟手），但**放开跨 section（跨天）拖拽**：停靠点可从一天拖到另一天。
//
//  与打包清单的关键差异（spec: app-navigation-framework.md / itinerary-route-planning.md）：
//  - 不夹断到起点 section：`.changed` 直接喂原始位置，UIKit 自然把被拖行带过 section 边界。
//  - 松手提交**所有受影响的天**（而非只起点那一段）——跨天移动会改两天的归属。
//  - 行类型：`.stop` 可重排；`.addStop` 为行内非可重排按钮（同打包的 .add）。优化入口已移至 day header。
//  - 无内联编辑态（行程行不内联编辑），故省去打包里的 editing 复杂度。
//  本组件只做 collection 管线 + 拖拽；所有行的 SwiftUI 内容由上层闭包传入、UIHostingConfiguration 承载。
//

import SwiftUI
import UIKit

/// 一天的结构快照。`entries` = 该天时间轴上有序的行（住宿条 + 停靠点 + 交通段，按业务顺序），
/// **不含** leg / addStop——后两者由 collection 在 applySnapshot 时按规则插入/追加。
/// 仅 `.stop` 参与重排；交通/住宿为固定行（spec: itinerary-transport-lodging.md）。
nonisolated struct ItineraryDaySection: Hashable, Sendable {
    let id: UUID
    let entries: [ItineraryRowID]
}

/// 行标识。`.stop` 可拖；其余（`.leg` / `.transport` / `.lodging` / `.addStop`）不可拖。
/// `.leg(UUID)` = 该停靠点上方的连接段（与上一点的连线 + 距离），UUID 为「下方那个停靠点」的 id；
/// 仅在**相邻两个停靠点之间且其间无交通段**时插入（有交通段时，交通段本身就是连接）。
/// `.transport(UUID)` = 交通段（边）；`.lodging(stay:day:)` = 住宿常驻条。
/// 住宿跨多天 → 同一 stay 在多个 section 出现，故行 ID 必须带「天序」维度，
/// 否则 diffable 快照里 item 标识跨 section 重复会崩（item identifiers 须全局唯一）。
/// `day` 还用于让 LodgingBannerRow 区分入住/过夜/退房三态。
nonisolated enum ItineraryRowID: Hashable, Sendable {
    case stop(UUID)
    case leg(UUID)
    case transport(UUID)
    case lodging(stay: UUID, day: Int)
    case addStop(UUID)
    /// 只读日历事件叠加行（spec: itinerary-calendar-overlay.md）。带「天序」维度保全局唯一
    /// （跨多天的全天事件会在多个 section 出现，同 `.lodging` 的教训）。不可拖、非行程数据。
    case calendarEvent(id: String, day: Int)
}

struct ItineraryReorderCollection: UIViewRepresentable {

    let sections: [ItineraryDaySection]
    /// 选中的「天」——变化时把该天 section 吸顶（与上方日历条联动）。nil 不滚动。
    let scrollTargetDayId: UUID?
    /// 「地点排序」模式：仅渲染 day header + `.stop` 行（隐去 leg/transport/lodging/addStop），
    /// 长按延迟降到「即抓即拖」。上层用 `.id` 在进出模式时重建本组件，故 cell 内容随之刷新为压缩版。
    let isReordering: Bool
    let stopContent: (UUID) -> AnyView
    /// 连接段内容（连线 + 距离），入参为下方停靠点 id。
    let legContent: (UUID) -> AnyView
    /// 交通段内容（连接行：mode 图标 + 班次 + 起讫时间），入参为 segment id。
    let transportContent: (UUID) -> AnyView
    /// 住宿常驻条内容，入参为 (lodging stay id, 当前天序)。
    let lodgingContent: (UUID, Int) -> AnyView
    /// 只读日历事件叠加行内容，入参为 (event id, 当前天序)。spec: itinerary-calendar-overlay.md
    let calendarEventContent: (String, Int) -> AnyView
    let addStopContent: (UUID) -> AnyView
    let headerContent: (ItineraryDaySection) -> AnyView
    let onDelete: (UUID) -> Void
    /// 松手提交：落定后每天的完整 stopID 顺序（跨天则改归属）。
    let onArrange: ([(dayID: UUID, stopIDs: [UUID])]) -> Void
    /// 拖拽开始（触感准备 / 上层可借此收键盘等）。
    let onReorderBegan: () -> Void
    /// 用户手动滚动列表 → 当前吸顶的那天（反向联动：回写上方日历选中态）。
    let onFocusDay: (UUID) -> Void

    private static let headerKind = UICollectionView.elementKindSectionHeader

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator

        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfig.interSectionSpacing = 0

        let layout = UICollectionViewCompositionalLayout(
            sectionProvider: { [weak coordinator] _, env in
                // 复刻打包 ReorderableItemCollection 的 .list 配置——透明 cell + 吸顶 header +
                // 原生左划（编辑/删除）。custom group 压缩布局不自带 swipe；42a72b6 改成 group 时误删了
                // swipe provider 接线，致行程左划失效。改回 .list 修复，并与打包两套收敛。
                // cell/header 自身已设 backgroundConfiguration=.clear()，故 .list 下照旧透明；
                // 行高由 UIHostingConfiguration 自适应（与原 .estimated(56) 实际尺寸一致）。
                var config = UICollectionLayoutListConfiguration(appearance: .plain)
                config.showsSeparators = false
                config.backgroundColor = .clear
                config.headerMode = .supplementary            // 每天一个吸顶 header
                config.headerTopPadding = 0                   // 清掉 plain list 表头上方系统间距
                config.trailingSwipeActionsConfigurationProvider = { [weak coordinator] indexPath in
                    coordinator?.trailingSwipe(at: indexPath)
                }
                let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
                section.contentInsets = .zero
                section.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = true }
                return section
            },
            configuration: layoutConfig
        )

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        // 透明底：与打包 ReorderableItemCollection 一致，让内容在底部「行程/打包」切换器下被其
        // 渐变淡出（两面统一）。ItineraryView 根 ZStack 已铺实心 systemBackground 作稳定底板，
        // 故透明不会透出页面渐变（页面本就是实心、非渐变）。
        cv.backgroundColor = .clear
        cv.delaysContentTouches = false
        cv.isScrollEnabled = true
        cv.showsVerticalScrollIndicator = false
        cv.delegate = coordinator

        coordinator.configure(collectionView: cv, headerKind: Self.headerKind)
        return cv
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(with: self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        // 禁止在此调 layoutIfNeeded()：sizeThatFits 处于 SwiftUI 测量/更新周期内，强制同步布局会
        // 连带重渲染 cell 内的 SwiftUI 内容（UIHostingConfiguration）→「setting value during update」
        // AttributeGraph 重入崩溃（点「添加地点」必现）。本屏 collection 由父 VStack 给定剩余高度
        // （proposal.height 非 nil），尺寸不依赖强制布局；nil 时才读 contentSize 兜底，亦不强制布局。
        let width = proposal.width ?? uiView.bounds.width
        let height = proposal.height ?? uiView.collectionViewLayout.collectionViewContentSize.height
        return CGSize(width: width, height: max(height, 1))
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate {

        private var parent: ItineraryReorderCollection
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<UUID, ItineraryRowID>!
        private var headerKind: String = UICollectionView.elementKindSectionHeader
        /// 当前已同步的天（正反向共用的单一真相）：正向据此判断是否需滚，反向滚动时回写它，
        /// 从而切断「程序滚动 → didScroll → 回写选中 → update → 再次程序滚动」的回授环。
        private var lastScrolledDayId: UUID?
        /// 正向程序滚动进行中：期间屏蔽反向回写，避免动画途中穿过的中间天误触选中。
        private var isProgrammaticScroll = false

        private var isDragging = false
        private let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
        private let stepHaptic = UISelectionFeedbackGenerator()
        private var lastHapticIndexPath: IndexPath?
        private weak var longPressRecognizer: UILongPressGestureRecognizer?

        init(_ parent: ItineraryReorderCollection) { self.parent = parent }

        // MARK: Setup

        func configure(collectionView: UICollectionView, headerKind: String) {
            self.collectionView = collectionView
            self.headerKind = headerKind

            let cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, ItineraryRowID> {
                [weak self] cell, _, rowID in
                guard let self else { return }
                cell.isOpaque = false
                cell.backgroundColor = .clear
                cell.backgroundConfiguration = .clear()
                cell.contentView.backgroundColor = .clear
                switch rowID {
                case .stop(let id):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.stopContent(id) }.margins(.all, 0)
                case .leg(let toStopID):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.legContent(toStopID) }.margins(.all, 0)
                case .transport(let id):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.transportContent(id) }.margins(.all, 0)
                case .lodging(let stay, let day):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.lodgingContent(stay, day) }.margins(.all, 0)
                case .calendarEvent(let id, let day):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.calendarEventContent(id, day) }.margins(.all, 0)
                case .addStop(let dayID):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.addStopContent(dayID) }.margins(.all, 0)
                }
            }

            let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
                elementKind: headerKind
            ) { [weak self] header, _, indexPath in
                guard let self,
                      let sectionID = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
                // 吸顶 header 必须不透明：cv 背景为透明（为底部淡出），不能再靠它兜底，故在 cell 级
                // 给实心 systemBackground，pinned 时保证不透出滚动内容（与页面同色、无缝）。
                var headerBG = UIBackgroundConfiguration.clear()
                headerBG.backgroundColor = .systemBackground
                header.backgroundConfiguration = headerBG
                header.contentView.backgroundColor = .clear
                guard let model = self.parent.sections.first(where: { $0.id == sectionID }) else { return }
                header.contentConfiguration = UIHostingConfiguration { self.parent.headerContent(model) }
                    .margins(.all, 0)
            }

            let ds = UICollectionViewDiffableDataSource<UUID, ItineraryRowID>(collectionView: collectionView) {
                cv, indexPath, rowID in
                cv.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: rowID)
            }
            ds.supplementaryViewProvider = { cv, _, indexPath in
                cv.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }

            // 仅 .stop 可拖。
            ds.reorderingHandlers.canReorderItem = { rowID in
                if case .stop = rowID { return true }
                return false
            }
            // 松手：提交**所有**天的新 stop 顺序（跨天会改两天归属）。
            ds.reorderingHandlers.didReorder = { [weak self] transaction in
                guard let self else { return }
                let snapshot = transaction.finalSnapshot
                var dayOrders: [(dayID: UUID, stopIDs: [UUID])] = []
                for dayID in snapshot.sectionIdentifiers {
                    let stopIDs: [UUID] = snapshot.itemIdentifiers(inSection: dayID).compactMap {
                        if case .stop(let id) = $0 { return id }
                        return nil
                    }
                    dayOrders.append((dayID: dayID, stopIDs: stopIDs))
                }
                self.parent.onArrange(dayOrders)
            }

            self.dataSource = ds

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            // 排序模式「即抓即拖」（0.15s）：仍 > 0 以免快速滑动滚动被误判为拖拽（移动 >10pt 即失败回退滚动）。
            // 常态保持 0.4s，避免与点击/滚动冲突。
            longPress.minimumPressDuration = parent.isReordering ? 0.15 : 0.4
            collectionView.addGestureRecognizer(longPress)
            longPressRecognizer = longPress

            // 新建/重建的 collection 顶部恒为首个 section。以它为「已滚」基线：选中天=首天时
            // 首开不滚；若重建时选中的是非首天，紧随的 update() 会把它吸顶（保持与日历联动）。
            lastScrolledDayId = parent.sections.first?.id
            applySnapshot(animated: false)
        }

        // MARK: Update

        func update(with parent: ItineraryReorderCollection) {
            self.parent = parent
            longPressRecognizer?.minimumPressDuration = parent.isReordering ? 0.15 : 0.4
            // 拖拽进行中不 apply（否则覆盖 UIKit 正在做的 interactive movement → 弹回）。
            guard !isDragging else { return }
            applySnapshot(animated: true)
            scrollToSelectedDayIfNeeded()
        }

        /// 上方日历切换某天 → 把该天 section 吸顶。仅在选中天真正变化时滚一次。
        private func scrollToSelectedDayIfNeeded() {
            guard let target = parent.scrollTargetDayId, target != lastScrolledDayId else { return }
            lastScrolledDayId = target
            // applySnapshot 后让一帧落定（estimated 高度解析），再按落定布局求吸顶偏移。
            DispatchQueue.main.async { [weak self] in
                self?.scrollDayToTop(target, animated: true)
            }
        }

        /// 把 dayID 对应 section 的 header 顶到列表顶部。header 已 pinToVisibleBounds，落位即吸顶。
        private func scrollDayToTop(_ dayID: UUID, animated: Bool) {
            guard let collectionView, let dataSource else { return }
            let snapshot = dataSource.snapshot()
            guard let sectionIndex = snapshot.indexOfSection(dayID) else { return }
            // 目标 section 不在顶部 → 其 header 处于「自然」位置（非 pinned），minY 即该天起始 Y。
            let headerPath = IndexPath(item: 0, section: sectionIndex)
            guard let attrs = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: headerKind, at: headerPath
            ) else { return }
            let topInset = collectionView.adjustedContentInset.top
            let maxY = max(
                -topInset,
                collectionView.contentSize.height - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            let targetY = min(max(attrs.frame.minY - topInset, -topInset), maxY)
            // 已在目标位置：不滚也不置标志（animated 滚动若无位移不会回调 didEndScrollingAnimation，
            // 否则 isProgrammaticScroll 会卡在 true 而永久屏蔽反向联动）。
            guard abs(targetY - collectionView.contentOffset.y) > 0.5 else { return }
            isProgrammaticScroll = true
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
        }

        private func applySnapshot(animated: Bool) {
            guard let dataSource else { return }
            var snapshot = NSDiffableDataSourceSnapshot<UUID, ItineraryRowID>()
            // 「地点排序」模式：每天只放 day header + `.stop` 行（无 leg/交通/住宿/Add），
            // 让用户专注拖拽、一屏看更多天；提交仍由 didReorder 收集各 section 的 `.stop` 顺序。
            if parent.isReordering {
                for section in parent.sections {
                    snapshot.appendSections([section.id])
                    let stopRows = section.entries.filter { if case .stop = $0 { return true }; return false }
                    snapshot.appendItems(stopRows, toSection: section.id)
                }
                dataSource.apply(snapshot, animatingDifferences: animated)
                collectionView?.setNeedsLayout()
                collectionView?.layoutIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    self?.collectionView?.setNeedsLayout()
                    self?.collectionView?.layoutIfNeeded()
                    self?.updateBottomInsetForLastSectionPinning()
                }
                return
            }
            for section in parent.sections {
                snapshot.appendSections([section.id])
                // 据 entries 构建最终行：
                // - 相邻两个停靠点之间、且其间无交通段 → 插入 .leg（连线 + 直线距离）；
                // - 有交通段在两点之间 → 交通段本身即连接，不再插 leg；
                // - 住宿条 / 交通段原样保留；最后追加 addStop（优化入口已移至 day header）。
                var rows: [ItineraryRowID] = []
                var lastWasStop = false
                for entry in section.entries {
                    switch entry {
                    case .stop(let sid):
                        if lastWasStop { rows.append(.leg(sid)) }
                        rows.append(.stop(sid))
                        lastWasStop = true
                    case .transport, .lodging, .calendarEvent:
                        rows.append(entry)
                        lastWasStop = false
                    default:
                        rows.append(entry)
                    }
                }
                rows.append(.addStop(section.id))
                snapshot.appendItems(rows, toSection: section.id)
            }
            dataSource.apply(snapshot, animatingDifferences: animated)
            collectionView?.setNeedsLayout()
            collectionView?.layoutIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.collectionView?.setNeedsLayout()
                self?.collectionView?.layoutIfNeeded()
                self?.updateBottomInsetForLastSectionPinning()
            }
        }

        /// 底部「行程/打包」切换器净空（含 home indicator）。collection 用 `.ignoresSafeArea(.bottom)`
        /// 延伸到切换器下方（内容在其渐变里淡出），故需手动让末行让出这段——与打包 83 对齐。
        private let bottomBarClearance: CGFloat = 83

        /// 底部 contentInset = max(切换器净空, 末日吸顶所需)。
        /// - 切换器净空：让末行不被底部切换器盖住（且内容能滚到其下被渐变淡出）。
        /// - 末日吸顶所需：末日地点少时下方无内容可顶 → 补「视口高 − 末段高」使其也能吸顶到顶部。
        /// 取两者较大；变化 < 1pt 不写，避免布局抖动。
        private func updateBottomInsetForLastSectionPinning() {
            guard let cv = collectionView, let dataSource else { return }
            func apply(_ value: CGFloat) {
                if abs(cv.contentInset.bottom - value) > 0.5 { cv.contentInset.bottom = value }
            }
            let sections = dataSource.snapshot().sectionIdentifiers
            // 单天：无吸顶切换需求，底部仅需让出切换器净空。
            guard sections.count > 1 else { apply(bottomBarClearance); return }
            let path = IndexPath(item: 0, section: sections.count - 1)
            // 用「首行 minY − header 高」反推末段 header 的自然顶，避开「末段恰好 pinned 时 header origin 失真」。
            guard let itemAttrs = cv.layoutAttributesForItem(at: path),
                  let headerAttrs = cv.layoutAttributesForSupplementaryElement(ofKind: headerKind, at: path)
            else { apply(bottomBarClearance); return }
            let naturalHeaderTop = itemAttrs.frame.minY - headerAttrs.frame.height
            let lastSectionHeight = cv.collectionViewLayout.collectionViewContentSize.height - naturalHeaderTop
            // 注：cv 用 .ignoresSafeArea(.bottom) → safeAreaInsets.bottom == 0，bounds 已含切换器下方区域，
            // 故吸顶所需直接 = bounds.height − topInset − 末段高，无需再扣安全区。
            let pinRequirement = max(0, cv.bounds.height - cv.adjustedContentInset.top - lastSectionHeight)
            apply(max(bottomBarClearance, pinRequirement))
        }

        // MARK: Interactive movement（跨天放开，无夹断）

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            let location = gesture.location(in: collectionView)

            switch gesture.state {
            case .began:
                guard let indexPath = collectionView.indexPathForItem(at: location),
                      let rowID = dataSource.itemIdentifier(for: indexPath),
                      case .stop = rowID else { return }
                parent.onReorderBegan()
                isDragging = true
                lastHapticIndexPath = indexPath
                stepHaptic.prepare()
                liftHaptic.prepare()
                liftHaptic.impactOccurred()
                if !collectionView.beginInteractiveMovementForItem(at: indexPath) {
                    isDragging = false
                }
            case .changed:
                guard isDragging else { return }
                // 不夹断：原始位置喂回去，UIKit 自然把被拖行带过 section 边界（跨天）。
                collectionView.updateInteractiveMovementTargetPosition(location)
                fireStepHapticIfCrossed(at: location, in: collectionView)
            case .ended:
                guard isDragging else { return }
                collectionView.endInteractiveMovement()
                endDrag()
            default:
                guard isDragging else { return }
                collectionView.cancelInteractiveMovement()
                endDrag()
            }
        }

        private func endDrag() {
            isDragging = false
            lastHapticIndexPath = nil
        }

        private func fireStepHapticIfCrossed(at point: CGPoint, in collectionView: UICollectionView) {
            guard let ip = collectionView.indexPathForItem(at: point), ip != lastHapticIndexPath else { return }
            lastHapticIndexPath = ip
            stepHaptic.selectionChanged()
            stepHaptic.prepare()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 重排拖拽中：auto-scroll 期间手势不发 .changed，用手势实时位置持续推进目标位置（不夹断）。
            if isDragging {
                guard let collectionView, let recognizer = longPressRecognizer else { return }
                collectionView.updateInteractiveMovementTargetPosition(recognizer.location(in: collectionView))
                return
            }
            // 正向程序滚动途中不回写（否则穿过的中间天会逐一误触选中 → 与动画打架）。
            guard !isProgrammaticScroll else { return }
            reportTopVisibleDayIfChanged()
        }

        /// 用户中途抓住列表 → 视为手动滚动，立即解除程序滚动屏蔽，让反向联动接管。
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        /// 正向程序滚动动画结束 → 解除屏蔽。
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        /// 计算当前吸顶（最靠顶部）的 section 是哪天，变化了才回写上层选中态。
        private func reportTopVisibleDayIfChanged() {
            guard let collectionView, let dataSource else { return }
            let topEdge = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            // 顶部那天 = 仍有 cell 越过顶缘的最小 section（其 header 此刻正 pinned 在顶）。
            // 用实际 cell frame 判断，对 estimated 高度稳健。
            var topSection = Int.max
            for cell in collectionView.visibleCells {
                guard let ip = collectionView.indexPath(for: cell) else { continue }
                if cell.frame.maxY > topEdge + 1 { topSection = min(topSection, ip.section) }
            }
            guard topSection != Int.max else { return }
            let ids = dataSource.snapshot().sectionIdentifiers
            guard topSection < ids.count else { return }
            let dayID = ids[topSection]
            guard dayID != lastScrolledDayId else { return }
            // 先记为已同步：回写选中触发的 update() 据此判定「已在位」，不会再反手程序滚动。
            lastScrolledDayId = dayID
            parent.onFocusDay(dayID)
        }

        // MARK: Swipe

        func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let rowID = dataSource.itemIdentifier(for: indexPath),
                  case .stop(let id) = rowID else { return nil }
            let delete = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                self?.parent.onDelete(id)
                completion(true)
            }
            delete.image = UIImage(systemName: "trash")
            delete.backgroundColor = .systemRed
            // 编辑改由「点击整行」承载（tap = 打开详情/编辑），左滑只留删除——对齐通用范式、消除冗余入口。
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = false
            return config
        }
    }
}
