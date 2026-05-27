//
//  CarryBottomSheet.swift
//  Carry
//
//  Fallback bottom sheet — full gesture/snap parity with CarryBottomSheet,
//  without side-margin scaling or bottom-lift clipping effects.
//
//  View hierarchy inside SheetViewController.view (full-screen):
//
//    view (PassthroughView)           ← touch pass-through outside sheet
//      └── containerView (UIView)     ← moves up/down, fixed corner radius
//            └── hostingView          ← UIHostingController.view
//
//  Delete checklist (when ultimate is stable):
//    - Delete this file
//    - Delete SheetFeatureFlag.swift
//    - Restore HomeView to call CarryBottomSheet directly
//    - Remove Sheet Implementation section in DeveloperModeView
//

import UIKit
import SwiftUI

// MARK: - SwiftUI interface

/// Identical public surface to CarryBottomSheet.
struct CarryBottomSheet<Content: View>: UIViewControllerRepresentable {

    let expandedHeight: CGFloat
    let collapsedOffset: CGFloat
    @Binding var mapCityOpacity: Double
    @Binding var collapseRequest: Bool
    let isListEmpty: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SheetViewController {
        let vc = SheetViewController(
            expandedHeight: expandedHeight,
            collapsedOffset: collapsedOffset,
            isListEmpty: isListEmpty
        )
        let hosting = UIHostingController(rootView: AnyView(content()))
        hosting.view.backgroundColor = .clear
        vc.installContent(hosting)
        context.coordinator.hostingVC = hosting
        context.coordinator.sheetVC = vc
        context.coordinator.mapCityOpacityBinding = $mapCityOpacity
        vc.onSnapChanged = { [weak coordinator = context.coordinator] isCollapsed in
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.18)) {
                    coordinator?.mapCityOpacityBinding?.wrappedValue = isCollapsed ? 1 : 0
                }
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: SheetViewController, context: Context) {
        context.coordinator.mapCityOpacityBinding = $mapCityOpacity
        context.coordinator.hostingVC?.rootView = AnyView(content())
        vc.isListEmpty = isListEmpty
        vc.updateLayout(expandedHeight: expandedHeight, collapsedOffset: collapsedOffset)
        if collapseRequest {
            vc.snap(toCollapsed: true, velocity: 0)
            DispatchQueue.main.async { collapseRequest = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var sheetVC: SheetViewController?
        var hostingVC: UIHostingController<AnyView>?
        var mapCityOpacityBinding: Binding<Double>?
    }
}

// MARK: - SheetViewController

final class SheetViewController: UIViewController {

    private enum PanDriver { case none, sheet, list }

    // MARK: Configuration

    private(set) var expandedHeight: CGFloat
    private(set) var collapsedOffset: CGFloat
    var isListEmpty: Bool = false

    /// Fixed corner radius for the sheet panel (measured from Tripsy @3x: collapsed top = 108px ÷ 3).
    /// No interpolation needed — the fallback keeps a consistent rounded-rect at all positions.
    private let cornerRadius: CGFloat = 36

    var onSnapChanged: ((Bool) -> Void)?

    // MARK: State

    /// 0 = expanded, collapsedOffset = collapsed.
    private var snappedOffset: CGFloat = 0
    /// Live drag delta on top of snappedOffset (non-zero only during gesture).
    private var liveDelta: CGFloat = 0
    private var isCollapsedState: Bool { snappedOffset >= collapsedOffset - 8 }
    private var runningAnimator: UIViewPropertyAnimator?
    /// Monotonic token so stale completion closures are silently dropped.
    private var animationGeneration: Int = 0
    /// Ensures only one gesture source drives liveDelta/snap at a time.
    private var activePanDriver: PanDriver = .none

    // MARK: View hierarchy

    /// The sheet panel itself. Moves up/down; clips content to corner radius.
    private let containerView = UIView()
    private weak var hostingView: UIView?

    // MARK: Scroll coordination

    private var sheetPan: UIPanGestureRecognizer!
    private weak var listScrollView: UIScrollView?
    private var delegateProxy: DecelerationCanceller?
    private var delegateObservation: NSKeyValueObservation?

    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .soft)

    private var capturedTranslationAtTop: CGFloat?
    private var wasAtTop = false
    private let expandSnapMinTranslation: CGFloat = 26
    private let expandSnapMinVelocity:    CGFloat = -260

    // MARK: Init

    init(expandedHeight: CGFloat, collapsedOffset: CGFloat, isListEmpty: Bool) {
        self.expandedHeight  = expandedHeight
        self.collapsedOffset = collapsedOffset
        self.isListEmpty     = isListEmpty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func loadView() {
        view = PassthroughView()
        view.backgroundColor = .clear
        view.clipsToBounds = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.backgroundColor = .clear
        containerView.clipsToBounds = true
        containerView.layer.cornerRadius = cornerRadius
        containerView.layer.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner
        ]
        view.addSubview(containerView)

        sheetPan = UIPanGestureRecognizer(target: self, action: #selector(handleSheetPan(_:)))
        sheetPan.delegate = self
        view.addGestureRecognizer(sheetPan)

        placeSheet(at: snappedOffset)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard runningAnimator == nil else { return }
        placeSheet(at: snappedOffset + liveDelta)
    }

    // MARK: External API

    func installContent(_ hosting: UIViewController) {
        // Prevent navigation bar / tab bar safe area insets from propagating into
        // the sheet's hosting controller — the sheet manages its own layout geometry.
        if #available(iOS 16.0, *) {
            (hosting as? UIHostingController<AnyView>)?.safeAreaRegions = []
        } else {
            hosting.additionalSafeAreaInsets = .zero
        }

        addChild(hosting)
        containerView.addSubview(hosting.view)
        hostingView = hosting.view
        hosting.didMove(toParent: self)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.attachScrollView(in: hosting.view)
        }
    }

    func updateLayout(expandedHeight h: CGFloat, collapsedOffset c: CGFloat) {
        guard h != expandedHeight || c != collapsedOffset else { return }
        let wasCollapsed = isCollapsedState
        expandedHeight  = h
        collapsedOffset = c
        UIView.animate(withDuration: 0.68, delay: 0,
                       usingSpringWithDamping: 0.88, initialSpringVelocity: 0) {
            self.snappedOffset = wasCollapsed ? c : 0
            self.placeSheet(at: self.snappedOffset)
        }
    }

    func snap(toCollapsed: Bool, velocity: CGFloat) {
        commitSnap(to: toCollapsed ? collapsedOffset : 0,
                   velocity: velocity,
                   source: "external")
    }

    // MARK: Layout

    private func placeSheet(at rawOffset: CGFloat) {
        let banded = rubberBand(rawOffset)
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }

        let y      = h - expandedHeight + banded
        let width  = w
        let height = expandedHeight

        containerView.frame = CGRect(x: 0, y: y, width: width, height: height)
        let bounds = containerView.bounds
        hostingView?.frame = bounds
    }

    // MARK: Physics helpers

    private func rubberBand(_ raw: CGFloat) -> CGFloat {
        let lo: CGFloat = 0, hi = collapsedOffset
        guard hi > lo else { return raw }
        if raw < lo {
            let over = lo - raw
            return lo - over * 0.55 / (1 + over / hi)
        } else if raw > hi {
            let over = raw - hi
            return hi + over * 0.55 / (1 + over / hi)
        }
        return raw
    }

    private func clampedProgress(_ raw: CGFloat) -> CGFloat {
        guard collapsedOffset > 0 else { return 0 }
        return min(max(0, raw), collapsedOffset) / collapsedOffset
    }

    private func currentVisualOffset() -> CGFloat {
        let h = view.bounds.height
        if let pf = containerView.layer.presentation()?.frame {
            return pf.origin.y - (h - expandedHeight)
        }
        return snappedOffset + liveDelta
    }

    // MARK: Snap decision

    private func resolveSnap(velocity: CGFloat, translation: CGFloat, clamped: CGFloat) -> Bool {
        if snappedOffset >= collapsedOffset - 1, translation < 0 {
            if velocity < -220 || translation < -34 { return false }
        }
        if velocity > 650  || translation > collapsedOffset * 0.50 { return true }
        if velocity < -350 || translation < -70 { return false }
        return clamped > collapsedOffset * 0.68
    }

    // MARK: Interactive drag

    private func beginInteractiveControl() {
        if let animator = runningAnimator {
            animationGeneration += 1  // invalidate stale completion before stopping
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
            runningAnimator = nil
        }
        var visual = min(max(0, currentVisualOffset()), collapsedOffset)
        if visual >= collapsedOffset - expandSnapMinTranslation {
            visual = collapsedOffset
        } else if visual <= expandSnapMinTranslation {
            visual = 0
        }
        snappedOffset = visual
        liveDelta = 0
        placeSheet(at: visual)
    }

    private func applyLiveDelta(_ delta: CGFloat) {
        liveDelta = delta
        placeSheet(at: snappedOffset + delta)
    }

    // MARK: Snap animation

    private func commitSnap(to target: CGFloat, velocity: CGFloat, source: String = "unknown") {
        let clampedVisual = min(max(0, currentVisualOffset()), collapsedOffset)

        animationGeneration += 1
        let generation = animationGeneration

        if let animator = runningAnimator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        runningAnimator = nil

        snappedOffset = clampedVisual
        liveDelta = 0
        placeSheet(at: clampedVisual)

        onSnapChanged?(target >= collapsedOffset)
        feedbackGenerator.impactOccurred()

        if target == collapsedOffset, let sv = listScrollView {
            let topInset = -sv.adjustedContentInset.top
            delegateProxy?.lockedOffsetY = topInset
            delegateProxy?.cancelNext = true
        }

        let travel   = target - clampedVisual
        let normV    = abs(travel) < 1 ? 0 : max(-30, min(30, velocity / travel))
        let isCollapsing = target >= collapsedOffset - 1

        // Direct handle-down/up and content-area-up: faster, no overshoot.
        let isDirect = (source == "sheetPanDirectCollapse"
                        || source == "sheetPanDirectExpand"
                        || source == "listPanUp")
        let dampingRatio: CGFloat = isDirect ? 0.97 : (isCollapsing ? 0.95 : 0.88)
        let scaledNormV   = isCollapsing ? normV * 0.5 : normV
        let params = UISpringTimingParameters(
            dampingRatio: dampingRatio,
            initialVelocity: CGVector(dx: 0, dy: scaledNormV)
        )

        let anim = UIViewPropertyAnimator(duration: 0.62, timingParameters: params)
        anim.addAnimations { [weak self] in
            self?.placeSheet(at: target)
        }
        anim.addCompletion { [weak self] _ in
            guard let self, generation == self.animationGeneration else { return }
            self.snappedOffset = target
            self.liveDelta     = 0
            self.runningAnimator = nil
            self.placeSheet(at: target)
            if let sv = self.listScrollView, self.delegateProxy?.lockedOffsetY != nil {
                self.delegateProxy?.lockedOffsetY = nil
                sv.isScrollEnabled = true
            }
        }

        runningAnimator = anim
        anim.startAnimation()
    }

    private func settleAtCurrentPositionWithoutSnap() {
        if let animator = runningAnimator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
            runningAnimator = nil
        }
        let visual = min(max(0, currentVisualOffset()), collapsedOffset)
        snappedOffset = visual
        liveDelta     = 0
        placeSheet(at: visual)
    }

    // MARK: Sheet pan gesture (capsule handle + empty-state area)

    @objc private func handleSheetPan(_ pan: UIPanGestureRecognizer) {
        if let sv = listScrollView,
           sv.panGestureRecognizer.state == .changed || sv.panGestureRecognizer.state == .began {
            if !isListEmpty { return }
        }

        let translation = pan.translation(in: view).y
        let velocity    = pan.velocity(in: view).y

        switch pan.state {
        case .began:
            if activePanDriver == .list {
                pan.state = .failed
                return
            }
            beginInteractiveControl()
            activePanDriver = .sheet
            feedbackGenerator.prepare()

        case .changed:
            guard activePanDriver == .sheet else { return }
            applyLiveDelta(translation)

        case .ended, .cancelled, .failed:
            guard activePanDriver == .sheet else { return }
            if translation > 0 || velocity > 0 {
                commitSnap(to: collapsedOffset, velocity: velocity, source: "sheetPanDirectCollapse")
            } else {
                let shouldExpand = (translation <= -expandSnapMinTranslation) || (velocity <= expandSnapMinVelocity)
                if shouldExpand {
                    commitSnap(to: 0, velocity: velocity, source: "sheetPanDirectExpand")
                } else {
                    // Near-collapsed micro-drag: snap back to collapsed rather than
                    // leaving a floating sub-pixel position that looks identical to
                    // collapsed but breaks isCollapsedState on the next gesture.
                    let currentPos = snappedOffset + translation
                    if currentPos >= collapsedOffset - expandSnapMinTranslation {
                        commitSnap(to: collapsedOffset, velocity: velocity, source: "sheetPanDirectCollapse")
                    } else {
                        settleAtCurrentPositionWithoutSnap()
                    }
                }
            }
            activePanDriver = .none

        default: break
        }
    }

    // MARK: UIScrollView coordination

    private func attachScrollView(in root: UIView) {
        guard let sv = findScrollView(in: root), sv !== listScrollView else { return }
        listScrollView = sv
        sv.panGestureRecognizer.addTarget(self, action: #selector(handleListPan(_:)))
        installProxy(on: sv)
        delegateObservation = sv.observe(\.delegate, options: []) { [weak self, weak sv] _, _ in
            guard let self, let sv, sv.delegate !== self.delegateProxy else { return }
            self.installProxy(on: sv)
        }
    }

    private func installProxy(on sv: UIScrollView) {
        let proxy = delegateProxy ?? DecelerationCanceller()
        proxy.original = sv.delegate
        sv.delegate = proxy
        delegateProxy = proxy
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView { return sv }
        for child in view.subviews {
            if let found = findScrollView(in: child) { return found }
        }
        return nil
    }

    // MARK: List pan (three gesture rules)

    @objc private func handleListPan(_ pan: UIPanGestureRecognizer) {
        guard let sv = listScrollView else { return }
        let topInset    = -sv.adjustedContentInset.top
        let translation = pan.translation(in: sv).y
        let velocity    = pan.velocity(in: sv).y
        let atTop       = sv.contentOffset.y <= topInset + 1

        switch pan.state {
        case .began:
            if activePanDriver == .sheet { return }
            beginInteractiveControl()
            activePanDriver = .list
            if sheetPan.state == .possible || sheetPan.state == .began || sheetPan.state == .changed {
                sheetPan.isEnabled = false
                sheetPan.isEnabled = true
            }
            // Lock scroll via proxy before UIScrollView processes any touch delta.
            // Overriding contentOffset in .changed is not enough — UIScrollView can
            // re-apply its own offset update in the same runloop turn, causing a race.
            // Condition: any position other than fully expanded (snappedOffset == 0)
            // should block content scroll — sheet position takes priority.
            if snappedOffset > 0 {
                delegateProxy?.lockedOffsetY = topInset
            }
            feedbackGenerator.prepare()

        case .changed:
            guard activePanDriver == .list else { return }
            if isCollapsedState {
                // Rule 3: sheet at bottom → block scroll, drive sheet position.
                // Proxy lock (set in .began) handles UIScrollView's internal updates;
                // the direct assignment here is a first-pass guard for the same frame.
                sv.contentOffset.y = topInset
                if translation < 0 {
                    applyLiveDelta(translation)
                } else {
                    applyLiveDelta(0)
                }
                wasAtTop = true
                break
            }

            // Rule 1: at list top + downward pull → drive sheet collapse.
            if atTop && translation > 0 {
                if !wasAtTop { capturedTranslationAtTop = translation }
                if let captured = capturedTranslationAtTop {
                    applyLiveDelta(max(0, translation - captured))
                    sv.contentOffset.y = topInset
                }
            } else {
                // Rule 2: normal list scroll.
                capturedTranslationAtTop = nil
                if liveDelta != 0 { applyLiveDelta(0) }
            }

            wasAtTop = atTop

        case .ended, .cancelled, .failed:
            guard activePanDriver == .list else { return }
            let drag = liveDelta
            capturedTranslationAtTop = nil
            wasAtTop = false

            guard drag != 0 else {
                // No sheet movement — release any collapsed-state scroll lock
                // so subsequent gestures are not permanently blocked.
                delegateProxy?.lockedOffsetY = nil
                activePanDriver = .none
                return
            }

            if drag > 0 || velocity > 0 {
                commitSnap(to: collapsedOffset, velocity: velocity, source: "sheetPanDirectCollapse")
            } else {
                let shouldExpand = (drag <= -expandSnapMinTranslation) || (velocity <= expandSnapMinVelocity)
                if shouldExpand {
                    // Lock remains; commitSnap completion will clear it once expanded.
                    commitSnap(to: 0, velocity: velocity, source: "listPanUp")
                } else {
                    let currentPos = snappedOffset + drag
                    if currentPos >= collapsedOffset - expandSnapMinTranslation {
                        // Near-collapsed micro-drag: snap back to collapsed.
                        commitSnap(to: collapsedOffset, velocity: velocity, source: "sheetPanDirectCollapse")
                    } else {
                        // Genuinely mid-way: settle and release the scroll lock.
                        delegateProxy?.lockedOffsetY = nil
                        settleAtCurrentPositionWithoutSnap()
                    }
                }
            }
            activePanDriver = .none

        default: break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension SheetViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gr === sheetPan, other === listScrollView?.panGestureRecognizer { return false }
        if other === sheetPan, gr === listScrollView?.panGestureRecognizer { return false }
        return true
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gr === sheetPan else { return true }
        guard containerView.frame.contains(touch.location(in: view)) else { return false }
        if !isListEmpty, let sv = listScrollView {
            if sv.bounds.contains(touch.location(in: sv)) { return false }
        }
        return true
    }
}

// MARK: - PassthroughView

private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - DecelerationCanceller

private final class DecelerationCanceller: NSObject, UIScrollViewDelegate {
    weak var original: AnyObject?
    var cancelNext    = false
    var lockedOffsetY: CGFloat?

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        if cancelNext {
            cancelNext = false
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        (original as? UIScrollViewDelegate)?.scrollViewWillBeginDecelerating?(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let locked = lockedOffsetY,
           abs(scrollView.contentOffset.y - locked) > 0.5 {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: locked), animated: false)
        }
        (original as? UIScrollViewDelegate)?.scrollViewDidScroll?(scrollView)
    }

    override func responds(to sel: Selector!) -> Bool {
        sel == #selector(UIScrollViewDelegate.scrollViewWillBeginDecelerating(_:))
        || sel == #selector(UIScrollViewDelegate.scrollViewDidScroll(_:))
        || (original?.responds(to: sel) ?? false)
    }

    override func forwardingTarget(for sel: Selector!) -> Any? {
        guard sel != #selector(UIScrollViewDelegate.scrollViewWillBeginDecelerating(_:)),
              sel != #selector(UIScrollViewDelegate.scrollViewDidScroll(_:)) else { return nil }
        return (original?.responds(to: sel) == true) ? original : nil
    }
}
