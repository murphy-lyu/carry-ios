//
//  ReorderableItemCollection.swift
//  Carry
//
//  正常模式打包清单的可重排容器。用 UICollectionView 原生 interactive movement
//  实现长按拖拽时被拖行快照 1:1 跟手、其它行 rubber-band 让位、松手只提交一次。
//
//  设计边界（见 specs/smooth-drag-reorder.md）：
//  - 本组件只做 collection 管线 + 拖拽手势，不持有任何业务/样式。所有行的 SwiftUI
//    内容（PackingItemRow / editableRow / addItemRow / sectionTitle）由上层通过闭包
//    传入并用 UIHostingConfiguration 承载，样式/本地化/动画全部复用，不在此重复实现。
//  - 物品只在所属 section 内重排（与旧实现一致）；跨 section 拖拽被夹断。
//  - add-item 行、section header 不可重排。
//

import SwiftUI
import UIKit

/// 一个分组的结构快照（只含可重排所需的 id/顺序与表头信息，不含 item 内容本身）。
/// 顶层非隔离类型，以满足 diffable data source 对 SectionIdentifier 的 Sendable 要求。
nonisolated struct ReorderSectionModel: Hashable, Sendable {
    let id: UUID
    let title: String
    let isFirst: Bool
    let itemIDs: [UUID]
}

/// 行标识。顶层非隔离，满足 diffable data source 对 ItemIdentifier 的 Sendable 要求。
nonisolated enum ReorderRowID: Hashable, Sendable {
    case item(UUID)
    case add(UUID)   // 关联 sectionId
    case info         // 顶部不可重排信息行（如 DestinationInfo）
}

struct ReorderableItemCollection: UIViewRepresentable {

    typealias Section = ReorderSectionModel
    typealias RowID = ReorderRowID

    let sections: [Section]
    /// 当前处于内联编辑态的 item（不可重排，渲染为编辑行）。
    let editingItemId: UUID?

    /// 顶部不可重排信息行（DestinationInfo）。nil 表示不展示。随列表一起滚动。
    let infoContent: (() -> AnyView)?
    /// 行内容闭包——每次 SwiftUI 更新都会带最新数据重建，Coordinator 持最新引用。
    let itemContent: (UUID) -> AnyView
    let editingContent: (UUID) -> AnyView
    let addContent: (UUID) -> AnyView
    let headerContent: (Section) -> AnyView

    /// swipe 删除（复用上层 deleteItem）。
    let onDelete: (UUID) -> Void
    /// 松手提交一次：sectionId + 该 section 重排后的完整 itemID 顺序。
    let onReorder: (UUID, [UUID]) -> Void
    /// 拖拽开始：上层借此提交在编辑的行 + 触感准备。
    let onReorderBegan: () -> Void

    // list 配置 headerMode=.supplementary 时，布局请求的 header kind 即此标准值，
    // 注册与 dequeue 必须用它，否则 _createPreparedSupplementaryView 断言崩溃。
    private static let headerKind = UICollectionView.elementKindSectionHeader
    /// 顶部 info section 的固定标识（不与任何真实 section.id 冲突的常量 UUID）。
    static let infoSectionID = UUID(uuidString: "00000000-0000-0000-0000-0000C0FFEE00")!

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator

        // 段间距 0，对齐旧 List 的 .listSectionSpacing(0)。
        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfig.interSectionSpacing = 0

        // 用 sectionProvider 逐 section 配置：info section 无表头（否则空表头会撑出间距），
        // 其余 section 才有吸顶表头（对齐旧 .listStyle(.plain) 的 sticky header）。
        let layout = UICollectionViewCompositionalLayout(
            sectionProvider: { [weak coordinator] sectionIndex, env in
                var config = UICollectionLayoutListConfiguration(appearance: .plain)
                config.showsSeparators = false
                config.backgroundColor = .clear
                config.headerMode = (coordinator?.isInfoSection(sectionIndex) ?? false)
                    ? .none : .supplementary
                // plain list 默认在表头上方加一段系统间距（约 20pt），旧 SwiftUI List 没有。
                // 清零，让段间距完全由各行自身 padding 决定（对齐旧版）。
                config.headerTopPadding = 0
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
        cv.backgroundColor = .clear
        cv.delaysContentTouches = false
        cv.alwaysBounceVertical = true
        cv.keyboardDismissMode = .interactive
        cv.showsVerticalScrollIndicator = false
        cv.contentInset.top = -8      // 对齐旧 List 的 .contentMargins(.top, -8)
        cv.contentInset.bottom = 83   // 让末行让出底部 tab/悬浮按钮（对齐旧 safeAreaPadding(.bottom, 83)）
        cv.delegate = coordinator

        coordinator.configure(collectionView: cv, headerKind: Self.headerKind)
        return cv
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(with: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate {

        private var parent: ReorderableItemCollection
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<UUID, RowID>!

        /// 拖拽起点所在 section，用于把目标位置夹断在同一 section 内。
        private var movingFromSection: Int?
        private let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
        /// 逐格重排触感（每跨一行一次），还原旧实现的手感。
        private let stepHaptic = UISelectionFeedbackGenerator()
        private var lastHapticIndexPath: IndexPath?
        /// 长按手势引用——auto-scroll 期间用它的实时位置在 scrollViewDidScroll 里重夹断。
        private weak var longPressRecognizer: UILongPressGestureRecognizer?

        init(_ parent: ReorderableItemCollection) {
            self.parent = parent
        }

        /// 顶部 info section 的 sectionIndex（有 info 时恒为 0）。供 layout 决定该 section 不要表头。
        func isInfoSection(_ index: Int) -> Bool {
            parent.infoContent != nil && index == 0
        }

        // MARK: Setup

        func configure(collectionView: UICollectionView, headerKind: String) {
            self.collectionView = collectionView

            let cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, RowID> {
                [weak self] cell, _, rowID in
                guard let self else { return }
                cell.backgroundConfiguration = .clear()
                cell.contentView.backgroundColor = .clear
                switch rowID {
                case .item(let id):
                    let content: AnyView = (id == self.parent.editingItemId)
                        ? self.parent.editingContent(id)
                        : self.parent.itemContent(id)
                    cell.contentConfiguration = UIHostingConfiguration { content }
                        .margins(.all, 0)
                case .add(let sectionId):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.addContent(sectionId) }
                        .margins(.all, 0)
                case .info:
                    let content = self.parent.infoContent?() ?? AnyView(EmptyView())
                    cell.contentConfiguration = UIHostingConfiguration { content }
                        .margins(.all, 0)
                }
            }

            let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
                elementKind: headerKind
            ) { [weak self] header, _, indexPath in
                guard let self,
                      let sectionID = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
                header.backgroundConfiguration = .clear()
                header.contentView.backgroundColor = .clear
                // info section 无表头：给一个零高度内容，list 自尺寸会收起。
                guard sectionID != ReorderableItemCollection.infoSectionID,
                      let model = self.parent.sections.first(where: { $0.id == sectionID }) else {
                    header.contentConfiguration = UIHostingConfiguration { EmptyView() }.margins(.all, 0)
                    return
                }
                header.contentConfiguration = UIHostingConfiguration { self.parent.headerContent(model) }
                    .margins(.all, 0)
            }

            let ds = UICollectionViewDiffableDataSource<UUID, RowID>(collectionView: collectionView) {
                cv, indexPath, rowID in
                cv.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: rowID)
            }
            ds.supplementaryViewProvider = { cv, _, indexPath in
                cv.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }

            // 原生重排：仅 .item 可拖；松手时把受影响 section 的新顺序提交一次。
            ds.reorderingHandlers.canReorderItem = { [weak self] rowID in
                guard case .item(let id) = rowID else { return false }
                return id != self?.parent.editingItemId
            }
            ds.reorderingHandlers.didReorder = { [weak self] transaction in
                guard let self else { return }
                // 受影响的 section（拖拽起点）的新 itemID 顺序。
                let snapshot = transaction.finalSnapshot
                let affected: [UUID]
                if let from = self.movingFromSection,
                   from < snapshot.sectionIdentifiers.count {
                    affected = [snapshot.sectionIdentifiers[from]]
                } else {
                    affected = snapshot.sectionIdentifiers
                }
                for sectionID in affected {
                    let ids: [UUID] = snapshot.itemIdentifiers(inSection: sectionID).compactMap {
                        if case .item(let id) = $0 { return id }
                        return nil
                    }
                    self.parent.onReorder(sectionID, ids)
                }
            }

            self.dataSource = ds

            // 长按驱动 interactive movement —— 1:1 跟手的来源。
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.4
            collectionView.addGestureRecognizer(longPress)
            longPressRecognizer = longPress

            lastEditingItemId = parent.editingItemId
            applySnapshot(animated: false, previousEditing: nil)
        }

        // MARK: Update

        /// 上一次的编辑态 item，用于只 reconfigure“进/出编辑态”的那一行。
        private var lastEditingItemId: UUID?

        func update(with parent: ReorderableItemCollection) {
            let previousEditing = lastEditingItemId
            self.parent = parent
            self.lastEditingItemId = parent.editingItemId
            // 拖拽进行中绝不 apply 快照——否则会用父视图的旧顺序覆盖 UIKit 正在做的
            // interactive movement，导致被拖行中途“弹回”。落手后 didReorder→写库→重渲染
            // 会再次触发 update，届时再应用（此时顺序已与 store 一致，无可见跳变）。
            guard movingFromSection == nil else { return }
            applySnapshot(animated: true, previousEditing: previousEditing)
        }

        private func applySnapshot(animated: Bool, previousEditing: UUID?) {
            guard let dataSource else { return }
            var snapshot = NSDiffableDataSourceSnapshot<UUID, RowID>()
            if parent.infoContent != nil {
                snapshot.appendSections([ReorderableItemCollection.infoSectionID])
                snapshot.appendItems([.info], toSection: ReorderableItemCollection.infoSectionID)
            }
            for section in parent.sections {
                snapshot.appendSections([section.id])
                var rows: [RowID] = section.itemIDs.map { .item($0) }
                rows.append(.add(section.id))
                snapshot.appendItems(rows, toSection: section.id)
            }
            // 结构（增删/重排）走 apply 的 diff。内容（勾选/数量/名称）无需 reconfigure：
            // PackingItem 是 SwiftData @Model（Observable），属性变化会自动刷新宿主 SwiftUI。
            // 唯一需要 reconfigure 的是“进/出编辑态”的行——它要在 PackingItemRow 与
            // InlineEditRow 间切换，而该选择是在 cell 注册闭包里按 editingItemId 求值的。
            dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
                guard let self, let ds = self.dataSource else { return }
                let current = ds.snapshot().itemIdentifiers
                let toggled: [RowID] = [previousEditing, self.parent.editingItemId]
                    .compactMap { $0 }
                    .map { RowID.item($0) }
                    .filter { current.contains($0) }
                guard !toggled.isEmpty else { return }
                var reconfig = ds.snapshot()
                reconfig.reconfigureItems(toggled)
                ds.apply(reconfig, animatingDifferences: false)
            }
        }

        // MARK: Interactive movement

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            let location = gesture.location(in: collectionView)

            switch gesture.state {
            case .began:
                guard let indexPath = collectionView.indexPathForItem(at: location),
                      let rowID = dataSource.itemIdentifier(for: indexPath),
                      case .item(let id) = rowID,
                      id != parent.editingItemId else { return }
                // 若此刻正有别的行在内联编辑：先提交它，并放弃本次拖拽——让快照刷新、空编辑行
                // 先消失，避免拖拽期间（update 被 guard 跳过）残留一行。用户再次长按即可拖。
                if parent.editingItemId != nil {
                    parent.onReorderBegan()
                    return
                }
                parent.onReorderBegan()
                movingFromSection = indexPath.section
                lastHapticIndexPath = indexPath
                stepHaptic.prepare()
                liftHaptic.prepare()
                liftHaptic.impactOccurred()
                if !collectionView.beginInteractiveMovementForItem(at: indexPath) {
                    movingFromSection = nil
                }
            case .changed:
                guard let from = movingFromSection else { return }
                // 手势级 Y 夹断：把目标位置限制在起点 section 内，物理上无法越界到别的 section。
                let clamped = clampLocationToSection(location, section: from, in: collectionView)
                collectionView.updateInteractiveMovementTargetPosition(clamped)
                fireStepHapticIfCrossed(at: clamped, in: collectionView)
            case .ended:
                guard movingFromSection != nil else { return }
                collectionView.endInteractiveMovement()
                endDrag()
            default:
                guard movingFromSection != nil else { return }
                collectionView.cancelInteractiveMovement()
                endDrag()
            }
        }

        private func endDrag() {
            movingFromSection = nil
            lastHapticIndexPath = nil
        }

        /// 跨过一行（手指所在 slot 变化）就补一次 selection 触感，还原旧版"哒哒"手感。
        private func fireStepHapticIfCrossed(at point: CGPoint, in collectionView: UICollectionView) {
            guard let ip = collectionView.indexPathForItem(at: point), ip != lastHapticIndexPath else { return }
            lastHapticIndexPath = ip
            stepHaptic.selectionChanged()
            stepHaptic.prepare()
        }

        /// auto-scroll 期间手势不发 .changed，但这里会持续触发：用长按手势的实时位置重夹断，
        /// 使被拖行在自动滚动时也不越出本 section（夹到非边缘位置后 auto-scroll 自然停下）。
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let from = movingFromSection,
                  let collectionView,
                  let recognizer = longPressRecognizer else { return }
            let clamped = clampLocationToSection(recognizer.location(in: collectionView),
                                                 section: from, in: collectionView)
            collectionView.updateInteractiveMovementTargetPosition(clamped)
        }

        /// 把目标位置的 Y 夹在起点 section 内，使拖拽不越出本 section。
        /// 关键：用拖拽中**不动的**锚点——表头底边 + add-item 行顶边——而非 .item 行的实时
        /// 布局。后者在重排动画期会移动、且当被拖行是端点时边界会取到它自己的浮动位置，喂回
        /// updateInteractiveMovementTargetPosition 会形成反馈，造成相邻 item 上下横跳。
        private func clampLocationToSection(_ location: CGPoint,
                                            section: Int,
                                            in collectionView: UICollectionView) -> CGPoint {
            let snapshot = dataSource.snapshot()
            guard section < snapshot.sectionIdentifiers.count else { return location }
            let sectionID = snapshot.sectionIdentifiers[section]

            var lower = -CGFloat.greatestFiniteMagnitude   // 上界：表头底边
            var upper =  CGFloat.greatestFiniteMagnitude    // 下界：add-item 行顶边
            if let headerAttr = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: section)) {
                lower = headerAttr.frame.maxY
            }
            if let addIdx = dataSource.indexPath(for: .add(sectionID)),
               let addAttr = collectionView.layoutAttributesForItem(at: addIdx) {
                upper = addAttr.frame.minY
            }
            guard lower <= upper else { return location }
            var p = location
            p.y = min(max(location.y, lower), upper)
            return p
        }

        // 跨 section 拦截完全由上面的手势级 Y 夹断（clampLocationToSection）负责。
        // 注：UICollectionViewDelegate 的 targetIndexPathForMoveFromItemAt 在 diffable +
        // interactive movement 下实测不被调用，故不实现它。

        // MARK: Swipe

        func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let rowID = dataSource.itemIdentifier(for: indexPath),
                  case .item(let id) = rowID,
                  id != parent.editingItemId else { return nil }
            // 沿用旧结论：不用 .destructive style，避免 UIKit 展开-收起的 ghost 动画。
            let delete = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                self?.parent.onDelete(id)
                completion(true)
            }
            delete.image = UIImage(systemName: "trash")
            delete.backgroundColor = .systemRed
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = false
            return config
        }
    }
}
