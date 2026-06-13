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
//  - 行类型：`.stop` 可重排；`.addStop` / `.optimize` 为行内非可重排按钮（同打包的 .add）。
//  - 无内联编辑态（行程行不内联编辑），故省去打包里的 editing 复杂度。
//  本组件只做 collection 管线 + 拖拽；所有行的 SwiftUI 内容由上层闭包传入、UIHostingConfiguration 承载。
//

import SwiftUI
import UIKit

/// 一天的结构快照（dayID + 该天 stopID 顺序 + 是否显示「优化」入口）。
nonisolated struct ItineraryDaySection: Hashable, Sendable {
    let id: UUID
    let stopIDs: [UUID]
    let showsOptimize: Bool
}

/// 行标识。`.stop` 可拖；`.addStop` / `.optimize` 不可拖（关联 dayID）。
nonisolated enum ItineraryRowID: Hashable, Sendable {
    case stop(UUID)
    case addStop(UUID)
    case optimize(UUID)
}

struct ItineraryReorderCollection: UIViewRepresentable {

    let sections: [ItineraryDaySection]
    let stopContent: (UUID) -> AnyView
    let addStopContent: (UUID) -> AnyView
    let optimizeContent: (UUID) -> AnyView
    let headerContent: (ItineraryDaySection) -> AnyView
    let onDelete: (UUID) -> Void
    /// 滑动「编辑」：唤起停靠点编辑（替代原先的点击整行编辑）。
    let onEdit: (UUID) -> Void
    /// 松手提交：落定后每天的完整 stopID 顺序（跨天则改归属）。
    let onArrange: ([(dayID: UUID, stopIDs: [UUID])]) -> Void
    /// 拖拽开始（触感准备 / 上层可借此收键盘等）。
    let onReorderBegan: () -> Void

    private static let headerKind = UICollectionView.elementKindSectionHeader

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator

        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfig.interSectionSpacing = 0

        let layout = UICollectionViewCompositionalLayout(
            sectionProvider: { [weak coordinator] sectionIndex, _ in
                let rowCount = max(1, coordinator?.rowCount(in: sectionIndex) ?? 1)

                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(56)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                item.contentInsets = .zero

                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(CGFloat(rowCount) * 56)
                )
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: groupSize,
                    repeatingSubitem: item,
                    count: rowCount
                )

                let section = NSCollectionLayoutSection(group: group)
                section.contentInsets = .zero
                section.interGroupSpacing = 0
                section.supplementaryContentInsetsReference = .none

                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(56)
                )
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize,
                    elementKind: Self.headerKind,
                    alignment: .top
                )
                header.pinToVisibleBounds = true
                section.boundarySupplementaryItems = [header]
                return section
            },
            configuration: layoutConfig
        )

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        // 让整个 itinerary 列表共享一个稳定底板，避免透明 row / 吸顶 header 直接透出页面渐变，
        // 形成“分块感”。
        cv.backgroundColor = .systemBackground
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
        uiView.layoutIfNeeded()
        let width = proposal.width ?? uiView.bounds.width
        let height = proposal.height ?? uiView.collectionViewLayout.collectionViewContentSize.height
        return CGSize(width: width, height: max(height, 1))
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate {

        private var parent: ItineraryReorderCollection
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<UUID, ItineraryRowID>!

        private var isDragging = false
        private let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
        private let stepHaptic = UISelectionFeedbackGenerator()
        private var lastHapticIndexPath: IndexPath?
        private weak var longPressRecognizer: UILongPressGestureRecognizer?

        init(_ parent: ItineraryReorderCollection) { self.parent = parent }

        // MARK: Setup

        func configure(collectionView: UICollectionView, headerKind: String) {
            self.collectionView = collectionView

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
                case .addStop(let dayID):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.addStopContent(dayID) }.margins(.all, 0)
                case .optimize(let dayID):
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.optimizeContent(dayID) }.margins(.all, 0)
                }
            }

            let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
                elementKind: headerKind
            ) { [weak self] header, _, indexPath in
                guard let self,
                      let sectionID = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
                header.isOpaque = false
                header.backgroundColor = .clear
                header.backgroundConfiguration = .clear()
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
            longPress.minimumPressDuration = 0.4
            collectionView.addGestureRecognizer(longPress)
            longPressRecognizer = longPress

            applySnapshot(animated: false)
        }

        func rowCount(in sectionIndex: Int) -> Int {
            guard sectionIndex < parent.sections.count else { return 1 }
            let section = parent.sections[sectionIndex]
            return max(1, section.stopIDs.count + 1 + (section.showsOptimize ? 1 : 0))
        }

        // MARK: Update

        func update(with parent: ItineraryReorderCollection) {
            self.parent = parent
            // 拖拽进行中不 apply（否则覆盖 UIKit 正在做的 interactive movement → 弹回）。
            guard !isDragging else { return }
            applySnapshot(animated: true)
        }

        private func applySnapshot(animated: Bool) {
            guard let dataSource else { return }
            var snapshot = NSDiffableDataSourceSnapshot<UUID, ItineraryRowID>()
            for section in parent.sections {
                snapshot.appendSections([section.id])
                var rows: [ItineraryRowID] = section.stopIDs.map { .stop($0) }
                rows.append(.addStop(section.id))
                if section.showsOptimize { rows.append(.optimize(section.id)) }
                snapshot.appendItems(rows, toSection: section.id)
            }
            dataSource.apply(snapshot, animatingDifferences: animated)
            collectionView?.setNeedsLayout()
            collectionView?.layoutIfNeeded()
            DispatchQueue.main.async { [weak collectionView] in
                collectionView?.setNeedsLayout()
                collectionView?.layoutIfNeeded()
            }
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

        /// auto-scroll 期间手势不发 .changed：用手势实时位置持续推进目标位置（同样不夹断）。
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isDragging, let collectionView, let recognizer = longPressRecognizer else { return }
            collectionView.updateInteractiveMovementTargetPosition(recognizer.location(in: collectionView))
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
            let edit = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                self?.parent.onEdit(id)
                completion(true)
            }
            edit.image = UIImage(systemName: "pencil")
            edit.backgroundColor = CarryAccent.uiColor
            // 顺序：删除在最外侧（边缘），编辑紧邻其内。整滑不直接触发（需点按）。
            let config = UISwipeActionsConfiguration(actions: [delete, edit])
            config.performsFirstActionWithFullSwipe = false
            return config
        }
    }
}
