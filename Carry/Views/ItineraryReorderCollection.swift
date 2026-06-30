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
    /// 当天 sortOrder（0-based）——geoLeg 连线取当天色用。
    var dayOrder: Int = 0
    let entries: [ItineraryRowID]
}

/// 行标识。`.stop` 可拖；其余（`.leg` / `.transport` / `.lodging` / `.addStop`）不可拖。
/// `.leg(UUID)` = 该停靠点上方的连接段（与上一点的连线 + 距离），UUID 为「下方那个停靠点」的 id；
/// 仅在**相邻两个停靠点之间且其间无交通段**时插入（有交通段时，交通段本身就是连接）。
/// `.transport(UUID)` = 交通段（边）；`.lodging(stay:day:role:)` = 住宿当天的脊上节点。
/// 住宿跨多天 → 同一 stay 在多个 section 出现，故行 ID 必须带「天序」维度，
/// 否则 diffable 快照里 item 标识跨 section 重复会崩（item identifiers 须全局唯一）。
/// `day` + `role` 区分入住/出发/过夜/退房——**整中间日同一 stay 出两个节点（depart+overnight）**，
/// 故 role 也进 id 维度保唯一（同租车两事件的教训）。
nonisolated enum LodgingRole: Hashable, Sendable {
    case checkIn, depart, overnight, checkout
}

/// 距离连线的「连接点」（spec: itinerary-distance-legs.md）：解析成一个真实地点坐标。
/// `.transport(_, arrival:)` 取交通段的 to 端(arrival=true)或 from 端(false)——且仅当该端有详细地址
/// （机场无地址、自然排除）。地址门控在 ItineraryView 的 connEndpoint 闭包里做。
nonisolated enum ConnEndpoint: Hashable, Sendable {
    case stop(UUID)
    case lodging(UUID)
    case transport(UUID, arrival: Bool)
}

nonisolated enum ItineraryRowID: Hashable, Sendable {
    case stop(UUID)
    case leg(UUID)
    /// 任意「真实地点」间的距离连接段（spec: itinerary-distance-legs.md）：from=上一行的离开点、
    /// to=下一行的进入点。覆盖交通/租车端点参与的相邻；stop↔stop / stop↔lodging 仍走 `.leg`/`.lodgingLeg`。
    /// (from,to,day) 在一天内唯一 → diffable id 唯一。
    case geoLeg(from: ConnEndpoint, to: ConnEndpoint, day: Int)
    case transport(UUID)
    case lodging(stay: UUID, day: Int, role: LodgingRole)
    /// 住宿端点与相邻地点之间的距离连接段：`departing` 区分「酒店→地点」(true) 与「地点→酒店」(false)。
    /// 带 day + stop + departing 维度保全局唯一（同 `.leg` 的角色，但一端是酒店坐标）。spec 增补 2026-06-20。
    case lodgingLeg(stay: UUID, stop: UUID, day: Int, departing: Bool)
    /// 租车事件行：同一租车段在**取车日**（pickup=true）与**还车日**（pickup=false）各出一条。
    /// 带「天序」维度保全局唯一（同 `.lodging` 的教训——跨多天复用不能重复 id）。不可拖、非可重排数据。
    /// spec: itinerary-car-rental.md（增补：租车两事件）。
    case carRental(segment: UUID, day: Int, pickup: Bool)
    case addStop(UUID)
    /// 只读日历事件叠加行（spec: itinerary-calendar-overlay.md）。带「天序」维度保全局唯一
    /// （跨多天的全天事件会在多个 section 出现，同 `.lodging` 的教训）。不可拖、非行程数据。
    case calendarEvent(id: String, day: Int)
    /// 「地点排序」模式下，**空天**的占位落点行（UUID = 该天 section id）。
    /// diffable 原生重排无法把 item 拖进 0 item 的 section → 给空天补一行可接收落点的占位；
    /// 不可拖（canReorderItem 仅 .stop），提交时 didReorder 只收 .stop、占位被天然过滤掉。
    case emptyDayDrop(UUID)
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
    /// 任意「真实地点」间的距离连线内容（spec: itinerary-distance-legs.md），入参为 (from, to, 当天天序)。
    let geoLegContent: (ConnEndpoint, ConnEndpoint, Int) -> AnyView
    /// 解析某行的连接点（asExit=true 取「离开点」、false 取「进入点」）+ 地址门控：交通端无详细地址 / 无坐标 → nil。
    /// 模型在 ItineraryView 侧，故门控在闭包里做。两端都非 nil 时 applySnapshot 才插 geoLeg。
    let connEndpoint: (ItineraryRowID, Bool) -> ConnEndpoint?
    /// 交通段内容（连接行：mode 图标 + 班次 + 起讫时间），入参为 segment id。
    let transportContent: (UUID) -> AnyView
    /// 住宿脊上节点内容，入参为 (lodging stay id, 当前天序, 当天角色)。
    let lodgingContent: (UUID, Int, LodgingRole) -> AnyView
    /// 住宿端点距离连接段内容，入参为 (stay id, stop id, 当前天序, departing)。
    let lodgingLegContent: (UUID, UUID, Int, Bool) -> AnyView
    /// 租车事件行内容（segmentID, dayOrder, pickup）。
    let carRentalContent: (UUID, Int, Bool) -> AnyView
    /// 只读日历事件叠加行内容，入参为 (event id, 当前天序)。spec: itinerary-calendar-overlay.md
    let calendarEventContent: (String, Int) -> AnyView
    let addStopContent: (UUID) -> AnyView
    let headerContent: (ItineraryDaySection) -> AnyView
    /// 左滑删除：地点（按 stopID）。
    let onDelete: (UUID) -> Void
    /// 左滑删除：交通段（航班/火车/巴士/渡轮/租车，按 segmentID——租车两行任删一条都删整段）。
    let onDeleteTransport: (UUID) -> Void
    /// 左滑删除：住宿（按 stayID——跨多天任一行删除即删整段）。
    let onDeleteLodging: (UUID) -> Void
    /// 松手提交：落定后每天的完整 stopID 顺序（跨天则改归属）。
    let onArrange: ([(dayID: UUID, stopIDs: [UUID])]) -> Void
    /// 拖拽开始（触感准备 / 上层可借此收键盘等）。
    let onReorderBegan: () -> Void
    /// 用户手动滚动列表 → 当前吸顶的那天（反向联动：回写上方日历选中态）。
    let onFocusDay: (UUID) -> Void
    /// 滚动方向 → 是否隐藏底部「行程/打包」切换器：下滑读列表→隐藏让位、上滑/近顶→显示（iOS 原生工具栏套路）。
    /// 始终可达（上滑即回），不剥夺打包入口。spec: 出发后专注行程列表（3+2）。
    var onScrollHideChange: (Bool) -> Void = { _ in }

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
        /// 底部切换器隐藏状态（滚动方向驱动）：上次 offset + 当前隐藏态，只在翻转时回调上层，避免每帧抖动。
        private var lastScrollHideY: CGFloat = 0
        private var switcherHidden = false
        private let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
        private let stepHaptic = UISelectionFeedbackGenerator()
        private var lastHapticIndexPath: IndexPath?
        private weak var longPressRecognizer: UILongPressGestureRecognizer?

        // 自定义可控自动滚动（拖拽到上/下边缘时）：接管 UIKit 内置交互移动的自动滚动——后者速度/触发区
        // 不可调、太猛，导致「一进边缘就狂滚冲过头」、难定位插入点。做法：喂给 UIKit 的目标位置夹在可视区
        // 内边带，UIKit 因而不自滚；改由本 CADisplayLink 按「离边缘越近越快、二次曲线渐进、上限低」推进
        // contentOffset。注：跟手输入循环（每帧依当前手指位置推进），非固定时长动画，不属「displayLink 做动画」反模式。
        private var autoScrollLink: CADisplayLink?
        private var autoScrollSpeed: CGFloat = 0          // 带符号 pt/s，负=上滚
        private let autoScrollZone: CGFloat = 48          // 上/下触发带高度（也是目标夹断的内边距）
        private let autoScrollMaxSpeed: CGFloat = 420     // 边缘处速度的绝对上限 pt/s（再快的行高也不超过它）
        // 速度按「行/秒」而非「点/秒」封顶：用户真正感知的是「每秒掠过几个插入点（行）」。固定 pt/s 下，
        // 压缩行（排序模式 ~44pt）比常规行（~88pt）每秒掠过的行数翻倍 → 同样手感却「冲过头」。改成
        // 边缘速度 = 实测被拖行高 × 本常数（封顶 autoScrollMaxSpeed），两种行高自动统一到同一「插入点/秒」。
        private let autoScrollRowsPerSec: CGFloat = 3     // 边缘处最多每秒掠过的行数
        private let autoScrollFallbackRowHeight: CGFloat = 56  // 行高测不到时的保守缺省（绝不回落到 maxSpeed 快档）
        private var draggedRowHeight: CGFloat = 0         // .began 时实测被拖 cell 高度，驱动上面的按行封顶
        // 我在拖拽期间「拥有」的权威 contentOffset.y：displayLink 推进它；scrollViewDidScroll 把任何
        // 偏离它的位移（=UIKit 内置自滚）回正到它。`reverting` 防回正写入再次触发 didScroll 的递归。
        private var dragAnchorOffsetY: CGFloat = 0
        private var revertingNativeScroll = false
        // true 仅在本类自己写 contentOffset 的那一瞬：scrollViewDidScroll 据此区分「我的推进」与「原生自滚」。
        private var applyingControlledScroll = false

        init(_ parent: ItineraryReorderCollection) { self.parent = parent }

        deinit { autoScrollLink?.invalidate() }

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
                case .geoLeg(let from, let to, let day):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.geoLegContent(from, to, day) }.margins(.all, 0)
                case .lodgingLeg(let stay, let stop, let day, let departing):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.lodgingLegContent(stay, stop, day, departing) }.margins(.all, 0)
                case .transport(let id):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.transportContent(id) }.margins(.all, 0)
                case .lodging(let stay, let day, let role):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.lodgingContent(stay, day, role) }.margins(.all, 0)
                case .carRental(let seg, let day, let pickup):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.carRentalContent(seg, day, pickup) }.margins(.all, 0)
                case .calendarEvent(let id, let day):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.calendarEventContent(id, day) }.margins(.all, 0)
                case .addStop(let dayID):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.addStopContent(dayID) }.margins(.all, 0)
                case .emptyDayDrop:
                    cell.contentConfiguration = UIHostingConfiguration { EmptyDayDropHint() }.margins(.all, 0)
                }
            }

            let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
                elementKind: headerKind
            ) { [weak self] header, _, indexPath in
                guard let self,
                      let sectionID = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
                // 吸顶 header 必须不透明：cv 背景为透明（为底部淡出），不能再靠它兜底，故在 cell 级
                // 给实心 systemBackground，pinned 时保证不透出滚动内容（与页面同色、无缝）。
                // UIBackgroundConfiguration 在 pin 时会被 UIKit 重置（不重调 handler），改用
                // UIView.backgroundColor 直接设在 cell 层，pin 提升不影响这个属性。
                header.backgroundColor = .systemBackground
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
                    if stopRows.isEmpty {
                        // 空天补一行占位落点，否则无法把地点拖进 0 item 的 section。
                        snapshot.appendItems([.emptyDayDrop(section.id)], toSection: section.id)
                    } else {
                        snapshot.appendItems(stopRows, toSection: section.id)
                    }
                }
                dataSource.apply(snapshot, animatingDifferences: shouldAnimate(animated, applying: snapshot))
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
                var previous: ItineraryRowID? = nil
                for entry in section.entries {
                    // 连接段：相邻两地点之间插直线距离 leg（其间有交通段时交通段本身即连接、不插）；
                    // 地点与住宿端点相邻则插「酒店↔地点」距离 leg（spec 增补 2026-06-20）。
                    switch (previous, entry) {
                    case (.stop, .stop(let sid)):
                        rows.append(.leg(sid))
                    case (.lodging(let stay, let day, _), .stop(let sid)):
                        rows.append(.lodgingLeg(stay: stay, stop: sid, day: day, departing: true))   // 酒店→地点
                    case (.stop(let psid), .lodging(let stay, let day, _)):
                        rows.append(.lodgingLeg(stay: stay, stop: psid, day: day, departing: false)) // 地点→酒店
                    default:
                        // 其余相邻（交通/租车端点参与）：两端都是「有详细地址的真实落点」才插距离连线。
                        // 机场端无地址 → connEndpoint 返 nil → 不插（spec: itinerary-distance-legs.md）。
                        if let prev = previous,
                           let from = parent.connEndpoint(prev, true),    // 上一行的「离开点」
                           let to = parent.connEndpoint(entry, false) {    // 下一行的「进入点」
                            rows.append(.geoLeg(from: from, to: to, day: section.dayOrder))
                        }
                    }
                    rows.append(entry)
                    previous = entry
                }
                rows.append(.addStop(section.id))
                snapshot.appendItems(rows, toSection: section.id)
            }
            // 连线（rail）随邻居拓扑变：节点 cell 的上/下连线、首尾、leg 由「邻居/位置」算出。diff 只重渲染
            // 身份变化的 item（增删/移动），身份不变但邻居变了的 cell（如删交通后下一节点变首项）会留旧连线
            // → 悬空线头，需返回重进才正常。故对「本次仍存在」的 item 显式 reconfigure，按新拓扑重算连线。
            let previousItems = Set(dataSource.snapshot().itemIdentifiers)
            let persisting = snapshot.itemIdentifiers.filter { previousItems.contains($0) }
            if !persisting.isEmpty { snapshot.reconfigureItems(persisting) }
            dataSource.apply(snapshot, animatingDifferences: shouldAnimate(animated, applying: snapshot))
            collectionView?.setNeedsLayout()
            collectionView?.layoutIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.collectionView?.setNeedsLayout()
                self?.collectionView?.layoutIfNeeded()
                self?.updateBottomInsetForLastSectionPinning()
                self?.refreshVisibleHeaders()
            }
        }

        /// 是否对本次 apply 播放逐行差异动画。**批量结构变化**（如相册导入一次性插入大量地点）一律关动画：
        /// 既消除「地点一个个蹦出来」的观感，又免去 UIKit 为数百行排布插入/移动动画的开销（长行程下尤甚）。
        /// 小改动（单个增删）仍保留动画反馈。
        private func shouldAnimate(_ requested: Bool, applying snapshot: NSDiffableDataSourceSnapshot<UUID, ItineraryRowID>) -> Bool {
            guard requested, let dataSource else { return false }
            let current = dataSource.snapshot()
            if current.numberOfItems == 0 { return false }                       // 首次填充不播动画
            if current.numberOfSections != snapshot.numberOfSections { return false }
            return abs(snapshot.numberOfItems - current.numberOfItems) <= 12      // 超阈值＝批量 → 不播
        }

        /// 重配可见 section 头部的内容——section id=天 UUID，加交通/地点等不改天身份，diffable 不会重配头部，
        /// 导致依赖行程级状态的头部内容（如多时区的 GMT 小标）刷不出来。apply 后主动重设一遍。
        private func refreshVisibleHeaders() {
            guard let collectionView, let dataSource else { return }
            let sectionIDs = dataSource.snapshot().sectionIdentifiers
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: headerKind) {
                guard indexPath.section < sectionIDs.count,
                      let model = parent.sections.first(where: { $0.id == sectionIDs[indexPath.section] }),
                      let header = collectionView.supplementaryView(forElementKind: headerKind, at: indexPath) as? UICollectionViewCell
                else { continue }
                // 必须与 headerRegistration 完全一致——尤其 `.margins(.all, 0)`，否则默认内边距会把整个
                // 头部（含彩色圆点）右移、与时间轴 rail 错位（已踩坑：漏了 margins 致圆点不再与活动图标同列）。
                header.contentConfiguration = UIHostingConfiguration { self.parent.headerContent(model) }
                    .margins(.all, 0)
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
                // 实测被拖 cell 高度，给自动滚动按「行/秒」封顶（压缩/常规行手感一致）。
                // 三级兜底：可见 cell → 布局属性 → 保守缺省；绝不让它为 0（=回落到 maxSpeed 快档）。
                draggedRowHeight = collectionView.cellForItem(at: indexPath)?.bounds.height
                    ?? collectionView.layoutAttributesForItem(at: indexPath)?.size.height
                    ?? autoScrollFallbackRowHeight
                if !collectionView.beginInteractiveMovementForItem(at: indexPath) {
                    isDragging = false
                } else {
                    // 我接管 contentOffset：以当前偏移为权威基线，自滚只由本类 displayLink 推进；
                    // UIKit 内置交互移动自滚（不可关/不可调速）的任何写入，都会在 scrollViewDidScroll 里被回正。
                    dragAnchorOffsetY = collectionView.contentOffset.y
                }
            case .changed:
                guard isDragging else { return }
                // 据手指与边缘距离驱动「按行/秒受控」的自滚（原生自滚由 scrollViewDidScroll 回正压住）。
                updateDrag(rawLocation: location)
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
            stopAutoScroll()
            isDragging = false
            lastHapticIndexPath = nil
            draggedRowHeight = 0
        }

        // MARK: 受控自动滚动（取代 UIKit 内置的不可关/不可调速自滚）
        //
        // 背景：拖拽用 UIKit 原生 `beginInteractiveMovementForItem`，它自带的「拖到边缘自动滚动」每帧
        // 推进 20~40pt（≈1000+pt/s）、无公开 API 关闭或调速，导致「手指挪一点点列表就冲过头」、难定位插入点。
        // 试过 `updateInteractiveMovementTargetPosition` 夹内带、`isScrollEnabled=false` 都压不住（实测日志为证）。
        // 方案：本类「拥有」拖拽期间的 contentOffset —— 自己的 displayLink 以「行/秒」受控推进 `dragAnchorOffsetY`，
        // 而 scrollViewDidScroll 把任何非本类的位移（=原生自滚）即时回正到该权威值，于是原生那一跳从不被画出。

        /// 拖拽中更新：把目标位置喂给 UIKit（驱动被拖 cell 跟随），并据手指与上下边缘距离设定受控滚动速度。
        private func updateDrag(rawLocation raw: CGPoint) {
            guard let cv = collectionView else { return }
            cv.updateInteractiveMovementTargetPosition(clampedToBand(raw, in: cv))
            autoScrollSpeed = autoScrollVelocity(forFinger: raw, in: cv)
            if autoScrollSpeed == 0 { stopAutoScroll() } else { startAutoScrollIfNeeded() }
        }

        /// 目标 Y 夹到「距可视上/下边各 autoScrollZone」的内带：自滚期间被拖 cell 停在带内、内容从其下流过。
        private func clampedToBand(_ p: CGPoint, in cv: UICollectionView) -> CGPoint {
            let top = cv.contentOffset.y + cv.safeAreaInsets.top + autoScrollZone
            let bottom = cv.contentOffset.y + cv.bounds.height - cv.safeAreaInsets.bottom - autoScrollZone
            guard bottom > top else { return p }   // 可视区太矮，放弃夹断
            return CGPoint(x: p.x, y: min(max(p.y, top), bottom))
        }

        /// 手指进入上/下触发带 → 带符号速度（二次曲线：带内边缘≈0、越近屏幕边越快，上限 autoScrollMaxSpeed）。
        private func autoScrollVelocity(forFinger raw: CGPoint, in cv: UICollectionView) -> CGFloat {
            // 边缘以「可见视口 + 真实安全区」为准，绝不用 adjustedContentInset.bottom——后者含末段吸顶预留的
            // 巨大底部 inset（实测 281pt），会把「底边」抬到屏幕中部、令自滚在中段就误触发（=「过于灵敏」真根）。
            let topEdge = cv.contentOffset.y + cv.safeAreaInsets.top
            let bottomEdge = cv.contentOffset.y + cv.bounds.height - cv.safeAreaInsets.bottom
            let dTop = raw.y - topEdge
            let dBottom = bottomEdge - raw.y
            // 边缘最大速度按行高封顶（行/秒 → 点/秒），再不超过绝对上限；行高测不到时退回绝对上限。
            let cap = draggedRowHeight > 0
                ? min(autoScrollMaxSpeed, draggedRowHeight * autoScrollRowsPerSec)
                : autoScrollMaxSpeed
            if dTop < autoScrollZone {
                let t = max(0, min(1, (autoScrollZone - dTop) / autoScrollZone))
                return -cap * t * t
            }
            if dBottom < autoScrollZone {
                let t = max(0, min(1, (autoScrollZone - dBottom) / autoScrollZone))
                return cap * t * t
            }
            return 0
        }

        private func startAutoScrollIfNeeded() {
            guard autoScrollLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(stepAutoScroll(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        }

        private func stopAutoScroll() {
            autoScrollLink?.invalidate()
            autoScrollLink = nil
            autoScrollSpeed = 0
        }

        @objc private func stepAutoScroll(_ link: CADisplayLink) {
            guard isDragging, autoScrollSpeed != 0, let cv = collectionView else { stopAutoScroll(); return }
            let dt = CGFloat(link.duration > 0 ? link.duration : 1.0 / 60)
            let minY = -cv.adjustedContentInset.top
            let maxY = max(minY, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let newY = min(max(cv.contentOffset.y + autoScrollSpeed * dt, minY), maxY)
            guard newY != cv.contentOffset.y else { stopAutoScroll(); return }   // 到顶/底，停
            dragAnchorOffsetY = newY        // 先更新权威值，再写 offset（否则 didScroll 会把我自己的推进当原生回正）
            applyingControlledScroll = true
            cv.contentOffset.y = newY   // 触发 scrollViewDidScroll → 重夹目标，cell 贴住内带、内容从其下流过
            applyingControlledScroll = false
            if let recognizer = longPressRecognizer {   // 滚动后按新可视位置重算速度（停下也在此判定）
                autoScrollSpeed = autoScrollVelocity(forFinger: recognizer.location(in: cv), in: cv)
                if autoScrollSpeed == 0 { stopAutoScroll() }
            }
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
                if revertingNativeScroll { return }
                // 非本类引起的位移 = UIKit 内置交互移动自滚（无公开 API 可关/可调速，太猛）→ 即时回正到权威值。
                // 同步发生在渲染前，故原生那一跳不会被画出来；净滚动只由本类 displayLink 以受控速度推进。
                if !applyingControlledScroll && abs(collectionView.contentOffset.y - dragAnchorOffsetY) > 0.01 {
                    revertingNativeScroll = true
                    collectionView.contentOffset.y = dragAnchorOffsetY
                    revertingNativeScroll = false
                }
                // 用当前手指位置重夹目标，cell 贴住内带。
                collectionView.updateInteractiveMovementTargetPosition(
                    clampedToBand(recognizer.location(in: collectionView), in: collectionView))
                return
            }
            // 性能：**滚动途中不回写 focused 天**。回写会改上层 @State → 触发 ItineraryView.body
            // 整体重算（daySections 逐天重建 timeline + 地图重建全部标注），长行程下快速滚动会
            // 连续触发几十轮整页重建 → 卡顿。改为「滚动停下时回写一次」（见下方两个 end 回调），
            // 滚动过程零 body 重算、纯 UIKit 列表滚动，丝滑且与行程长度无关。
            updateSwitcherHide(scrollView)
        }

        /// 滚动方向 → 底部切换器隐藏/显示：近顶恒显示；下滑超阈值隐藏、上滑超阈值显示。只在翻转时回调上层
        /// （驱动 SwiftUI 带动画收起/展开 safeAreaInset，腾出列表空间），不每帧回调。程序滚动期间不参与。
        private func updateSwitcherHide(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            let y = scrollView.contentOffset.y
            let topY = -scrollView.adjustedContentInset.top
            let dy = y - lastScrollHideY
            lastScrollHideY = y
            let next: Bool
            if y <= topY + 8 {
                next = false                 // 近顶：恒显示（避免顶部抖动）
            } else if dy > 6 {
                next = true                  // 下滑：隐藏让位
            } else if dy < -6 {
                next = false                 // 上滑：显示
            } else {
                return                       // 微动不翻转，留滞回
            }
            guard next != switcherHidden else { return }
            switcherHidden = next
            parent.onScrollHideChange(next)
        }

        /// 用户中途抓住列表 → 视为手动滚动，立即解除程序滚动屏蔽，让反向联动接管。
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        /// 拖拽结束且不会惯性滑动 → 回写一次顶部天。
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate, !isProgrammaticScroll else { return }
            reportTopVisibleDayIfChanged()
        }

        /// 惯性滑动结束 → 回写一次顶部天。
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            reportTopVisibleDayIfChanged()
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
            guard let rowID = dataSource.itemIdentifier(for: indexPath) else { return nil }
            // 可删的用户实体行才有左滑：地点 / 交通(航班·火车·巴士·渡轮) / 租车 / 住宿。
            // 日历事件(系统只读)、连接线(leg/lodgingLeg)、占位行(emptyDayDrop/addStop) 不可删 → 无左滑。
            switch rowID {
            case .stop, .transport, .carRental, .lodging: break
            default: return nil
            }
            let delete = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                switch rowID {
                case .stop(let id):              self.parent.onDelete(id)
                case .transport(let id):         self.parent.onDeleteTransport(id)
                case .carRental(let seg, _, _):  self.parent.onDeleteTransport(seg)   // 取/还任一行 → 删整段
                case .lodging(let stay, _, _):   self.parent.onDeleteLodging(stay)    // 跨天任一行 → 删整段
                default: break
                }
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

// MARK: - EmptyDayDropHint

/// 「地点排序」模式下空天的占位落点提示：虚线圆角框 + 「拖到这里」，提示该天可接收地点。
/// 不可拖、不入库（提交时被 didReorder 过滤）。spec: itinerary-reorder-mode.md。
private struct EmptyDayDropHint: View {
    var body: some View {
        Text("itinerary.reorder.drop_here")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .accessibilityLabel(Text("itinerary.reorder.drop_here"))
    }
}
