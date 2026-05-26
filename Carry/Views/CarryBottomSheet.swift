//
//  CarryBottomSheet.swift
//  Carry
//
//  High-performance bottom sheet driven entirely by UIKit.
//  UIViewPropertyAnimator + CALayer — SwiftUI body never re-evaluates
//  during spring animations.
//
//  View hierarchy inside SheetViewController.view (full-screen):
//
//    clippingView (clipsToBounds = true)  ← shrinks from bottom on collapse
//      └── outerView  (clipsToBounds = false)   ← moves up/down, scales
//            └── innerView  (clipsToBounds = true, mask = innerMaskLayer)
//                  └── hostingView              ← UIHostingController.view
//

import UIKit
import SwiftUI

// MARK: - SwiftUI interface

struct CarryBottomSheet<Content: View>: UIViewControllerRepresentable {

    let expandedHeight: CGFloat
    let collapsedOffset: CGFloat
    @Binding var mapCityOpacity: Double
    /// Set to `true` externally (Siri shortcut, map button) to collapse.
    @Binding var collapseRequest: Bool
    /// Whether the list is empty — affects which gesture zones are active.
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
        context.coordinator.sheetVC  = vc
        // Store the binding so the snap callback can write to it from UIKit.
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

    // MARK: Configuration

    private(set) var expandedHeight: CGFloat
    private(set) var collapsedOffset: CGFloat
    var isListEmpty: Bool = false

    // MARK: Visual metrics (1:1 from Tripsy measurement, iPhone 17 Pro @3x)

    /// Corner radius when fully expanded (all 4 corners).
    private let expandedRadius:        CGFloat = 37
    /// Top-left / top-right radius when fully collapsed.
    private let collapsedTopRadius:    CGFloat = 36
    /// Bottom-left / bottom-right radius when fully collapsed.
    private let collapsedBottomRadius: CGFloat = 49
    /// Horizontal inset on each side when collapsed.
    private let collapsedSideMargin:   CGFloat = 8
    /// Gap between sheet bottom and screen bottom when collapsed.
    private let collapsedBottomMargin: CGFloat = 8

    // MARK: Effect progress

    /// Visual effects (side margins, bottom lift, corner radii) only activate in the
    /// last 35% of the collapse travel, so the sheet slides down at full size and
    /// snaps into the pill shape near the end — matching Tripsy / Flighty behaviour.
    /// During expand the pill dissolves in the first 35% of travel, then the sheet
    /// rises at full width for the remaining 65%.
    private func effectProgress(_ p: CGFloat) -> CGFloat {
        let threshold: CGFloat = 0.65
        guard p > threshold else { return 0 }
        return (p - threshold) / (1 - threshold)
    }

    // Corner radii change linearly with progress so they stay in sync with the
    // gesture at all times — matching Tripsy / Flighty behaviour.
    // effectProgress is intentionally NOT used here: concentrating the change in
    // the last 35% makes corners appear to jump when a fast snap passes through
    // that window. Pill margins and bottom lift still use effectProgress.
    private func topRadius(_ p: CGFloat)    -> CGFloat { expandedRadius + p * (collapsedTopRadius    - expandedRadius) }
    private func bottomRadius(_ p: CGFloat) -> CGFloat { expandedRadius + p * (collapsedBottomRadius - expandedRadius) }

    /// Called on main thread when a snap animation begins.
    var onSnapChanged: ((Bool) -> Void)?

    // MARK: State

    /// 0 = expanded, collapsedOffset = collapsed.
    private var snappedOffset: CGFloat = 0
    /// Live drag delta on top of snappedOffset (non-zero only during gesture).
    private var liveDelta: CGFloat = 0

    private var isCollapsedState: Bool { snappedOffset >= collapsedOffset - 1 }
    private var runningAnimator: UIViewPropertyAnimator?

    // MARK: View hierarchy

    /// Clips the sheet from below: height = screenHeight - bottomLift.
    /// As the sheet collapses, this shrinks and reveals background, creating
    /// the "ship leaving dock" gap at the bottom.
    /// PassthroughView so touches outside the sheet reach MapKit behind it.
    private let clippingView = PassthroughView()
    /// Moves and scales; clipsToBounds = false.
    private let outerView = UIView()
    /// Stays within outerView bounds; clips content to rounded corners.
    private let innerView = UIView()
    /// Reused mask layer on innerView — path is updated in place so
    /// UIViewPropertyAnimator can spring-animate it automatically.
    private let innerMaskLayer = CAShapeLayer()

    // MARK: Scroll coordination

    private var sheetPan: UIPanGestureRecognizer!
    private weak var listScrollView: UIScrollView?
    private var delegateProxy: DecelerationCanceller?
    private var delegateObservation: NSKeyValueObservation?

    /// Pre-allocated so the Taptic Engine is warm before the first snap.
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .soft)

    private var capturedTranslationAtTop: CGFloat?
    private var wasAtTop = false
    private var isExpandingFromCollapsed = false
    private var savedScrollOffsetY: CGFloat = 0

    // MARK: Init

    init(expandedHeight: CGFloat, collapsedOffset: CGFloat, isListEmpty: Bool) {
        self.expandedHeight = expandedHeight
        self.collapsedOffset = collapsedOffset
        self.isListEmpty = isListEmpty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    /// Use PassthroughView as the root so touches outside the sheet panel
    /// fall through to MapKit (or any other view behind the sheet).
    override func loadView() {
        view = PassthroughView()
        view.backgroundColor = .clear
        view.clipsToBounds = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // clippingView: sits full-screen but shrinks from the bottom as the
        // sheet collapses, creating a transparent strip between sheet and screen edge.
        // Corner rounding is handled entirely by innerMaskLayer (not clippingView.cornerRadius),
        // which lets us place bottom corners exactly at the visual clip line.
        clippingView.clipsToBounds = true
        clippingView.backgroundColor = .clear
        view.addSubview(clippingView)

        // outerView: moves, scales; does NOT clip (lives inside clippingView)
        outerView.clipsToBounds = false
        clippingView.addSubview(outerView)

        // innerView: clips SwiftUI content to the animated corner radius.
        // Use autoresizingMask so its frame tracks outerView.bounds automatically —
        // this avoids setting innerView.frame directly while a transform is active
        // (which is undefined behavior per UIKit docs).
        innerView.clipsToBounds = true
        innerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Mask handles all corner rounding; set once, path updated in place.
        innerView.layer.mask = innerMaskLayer
        outerView.addSubview(innerView)

        // Pan gesture on the full view; shouldReceive limits it to sheet zone.
        sheetPan = UIPanGestureRecognizer(target: self, action: #selector(handleSheetPan(_:)))
        sheetPan.delegate = self
        view.addGestureRecognizer(sheetPan)

        // Sync initial visual state
        setProgress(0, animated: false)
        placeSheet(at: snappedOffset)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard runningAnimator == nil else { return }
        let raw = snappedOffset + liveDelta
        placeSheet(at: raw)
        // Re-apply mask and transform with correct bounds.
        // setProgress() in viewDidLoad often skips (bounds are zero at that point),
        // so we always refresh here, wrapped in disableActions to avoid implicit animations.
        let progress = clampedProgress(raw)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(progress), bottom: bottomRadius(progress), progress: progress)
        innerView.transform = .identity
        CATransaction.commit()
    }

    // MARK: Hit-test passthrough outside sheet panel

    // view is full-screen; touches outside outerView should fall through.
    // We handle this in gestureRecognizer shouldReceive rather than hitTest
    // so that subviews (e.g. SwiftUI buttons) still receive taps normally.

    // MARK: External API

    func installContent(_ hosting: UIViewController) {
        addChild(hosting)
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        innerView.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.attachScrollView(in: hosting.view)
        }
    }

    func updateLayout(expandedHeight h: CGFloat, collapsedOffset c: CGFloat) {
        guard h != expandedHeight || c != collapsedOffset else { return }
        let wasCollapsed = isCollapsedState
        expandedHeight = h
        collapsedOffset = c
        // Animate the repositioning to match SwiftUI's spring on isEffectivelyEmpty
        UIView.animate(withDuration: 0.68, delay: 0,
                       usingSpringWithDamping: 0.88, initialSpringVelocity: 0) {
            self.snappedOffset = wasCollapsed ? c : 0
            self.placeSheet(at: self.snappedOffset)
        }
    }

    func snap(toCollapsed: Bool, velocity: CGFloat) {
        let target: CGFloat = toCollapsed ? collapsedOffset : 0
        commitSnap(to: target, velocity: velocity)
    }

    // MARK: Layout helpers

    private func placeSheet(at rawOffset: CGFloat) {
        let banded   = rubberBand(rawOffset)
        let progress = clampedProgress(rawOffset)
        let lift     = bottomLift(progress)
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }

        // clippingView: full width, shrinks from the bottom by `lift` (bottom margin).
        clippingView.frame = CGRect(x: 0, y: 0, width: w, height: h - lift)

        // outerView: side margins only appear in the last 35% of travel (effectProgress),
        // so the sheet slides down at full width before snapping into the pill shape.
        let sideMargin = collapsedSideMargin * effectProgress(progress)
        let y = h - expandedHeight + banded
        outerView.frame = CGRect(x: sideMargin, y: y,
                                 width: w - 2 * sideMargin, height: expandedHeight)
        // innerView fills outerView via autoresizingMask — never set .frame directly
        // while a transform may be active (undefined behavior in UIKit).
    }

    /// Called inside UIViewPropertyAnimator.addAnimations — the animator drives
    /// the implicit CALayer animations on the mask path and transform.
    private func setProgress(_ progress: CGFloat, animated: Bool) {
        applyCornerMask(top: topRadius(progress), bottom: bottomRadius(progress), progress: progress)
    }

    /// Updates `innerMaskLayer.path` in place with per-corner radii.
    /// Uses `visibleH` — the portion of innerView actually visible above
    /// clippingView's bottom edge — so bottom corners sit exactly at the
    /// visual clip line (matching the top corner radius).
    /// `progress` (0 = expanded, 1 = collapsed) drives a safe-area subtraction
    /// so bottom corners float above the home indicator when collapsed,
    /// Caller is responsible for wrapping in CATransaction.setDisableActions(true)
    /// when an implicit animation should be suppressed.
    private func applyCornerMask(top: CGFloat, bottom: CGFloat, progress: CGFloat) {
        let w     = innerView.bounds.width
        let fullH = innerView.bounds.height
        guard w > 0, fullH > 0 else { return }

        // During most of the descent the bottom corners stay off-screen (mask at fullH),
        // so the screen edge acts as a natural clip — no visible compression.
        // Only in the last 35% of travel (effectProgress) does visibleH transition
        // toward rawVisible, letting the pill's bottom corners float up into view.
        let rawVisible = clippingView.frame.height - outerView.frame.origin.y
        let ep         = effectProgress(progress)
        let visibleH   = max(0, min(fullH, fullH + ep * (rawVisible - fullH)))

        // True circular arcs — addArc produces the same geometry as CALayer
        // corner rounding, unlike the quadBezier approximation.
        let path = UIBezierPath()
        let tl = top, tr = top, bl = bottom, br = bottom
        path.move(to: CGPoint(x: tl, y: 0))
        // Top edge → top-right arc
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addArc(withCenter: CGPoint(x: w - tr, y: tr),
                    radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        // Right edge → bottom-right arc
        path.addLine(to: CGPoint(x: w, y: visibleH - br))
        path.addArc(withCenter: CGPoint(x: w - br, y: visibleH - br),
                    radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        // Bottom edge → bottom-left arc
        path.addLine(to: CGPoint(x: bl, y: visibleH))
        path.addArc(withCenter: CGPoint(x: bl, y: visibleH - bl),
                    radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        // Left edge → top-left arc
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(withCenter: CGPoint(x: tl, y: tl),
                    radius: tl, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()

        // Updating `.path` on the existing layer (not replacing the layer) lets
        // UIViewPropertyAnimator interpolate it as a CALayer animatable property.
        innerMaskLayer.path = path.cgPath
    }

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

    /// How much to shrink clippingView from the bottom (only in last 35% of travel).
    private func bottomLift(_ progress: CGFloat) -> CGFloat {
        effectProgress(progress) * collapsedBottomMargin
    }

    // MARK: Snap animation

    private func commitSnap(to target: CGFloat, velocity: CGFloat) {
        // ── Step 1: capture current VISUAL (presentation) offset ──────────────────
        // stopAnimation(true) snaps the model layer to the animation's end-state, not
        // the current visual position. Capturing the presentation frame first lets us
        // restore the model after stopping so the new animation starts from the correct
        // position — preventing the "sheet jumps to collapsed then re-expands" glitch.
        let h = view.bounds.height
        let visualOffset: CGFloat
        if runningAnimator != nil,
           let pf = outerView.layer.presentation()?.frame {
            // Invert placeSheet's formula: outerView.y = h − expandedHeight + offset
            visualOffset = pf.origin.y - (h - expandedHeight)
        } else {
            visualOffset = snappedOffset + liveDelta
        }
        let clampedVisual = min(max(0, visualOffset), collapsedOffset)

        // ── Step 2: stop running animation and reset model to visual position ─────
        runningAnimator?.stopAnimation(true)
        runningAnimator = nil   // nil immediately so viewDidLayoutSubviews won't skip
        snappedOffset = clampedVisual
        liveDelta = 0
        placeSheet(at: clampedVisual)
        let visualProgress = clampedProgress(clampedVisual)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(visualProgress),
                        bottom: bottomRadius(visualProgress),
                        progress: visualProgress)
        CATransaction.commit()

        // ── Step 3: velocity normalisation (signed travel so expand ≡ collapse) ───
        // Using abs(travel) gave expand a negative normV (spring fights itself at start)
        // while collapse had positive normV — making collapse feel snappier. Fix: keep
        // the sign so normV is always positive when velocity points toward target.
        let travel = target - clampedVisual
        let normV  = abs(travel) < 1 ? 0 : max(-30, min(30, velocity / travel))

        onSnapChanged?(target >= collapsedOffset)
        feedbackGenerator.impactOccurred()

        // ── Step 4: lock scroll at top during collapse to prevent content bounce ──
        // Released in addCompletion regardless of direction.
        if target == collapsedOffset, let sv = listScrollView {
            let topInset = -sv.adjustedContentInset.top
            delegateProxy?.lockedOffsetY = topInset
            delegateProxy?.cancelNext = true
        }

        // ── Step 5: start new spring animation ────────────────────────────────────
        let params = UISpringTimingParameters(
            dampingRatio: 0.88,
            initialVelocity: CGVector(dx: 0, dy: normV)
        )
        let anim = UIViewPropertyAnimator(duration: 0.68, timingParameters: params)

        anim.addAnimations { [weak self] in
            guard let self else { return }
            let progress = self.clampedProgress(target)
            self.placeSheet(at: target)
            self.setProgress(progress, animated: true)
        }

        anim.addCompletion { [weak self] _ in
            guard let self else { return }
            self.snappedOffset = target
            self.liveDelta = 0
            self.runningAnimator = nil
            let p = self.clampedProgress(target)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.applyCornerMask(top: self.topRadius(p), bottom: self.bottomRadius(p), progress: p)
            CATransaction.commit()
            // Release scroll lock (set for both collapse and expand-from-collapsed paths).
            if let sv = self.listScrollView, self.delegateProxy?.lockedOffsetY != nil {
                self.delegateProxy?.lockedOffsetY = nil
                sv.isScrollEnabled = true
            }
        }

        runningAnimator = anim
        anim.startAnimation()
    }

    // MARK: Snap decision

    private func resolveSnap(velocity: CGFloat, translation: CGFloat,
                              clamped: CGFloat) -> Bool {
        if velocity > 650  || translation > collapsedOffset * 0.50 { return true }
        if velocity < -350 || translation < -70 { return false }
        return clamped > collapsedOffset * 0.68
    }

    // MARK: Live drag visual update (during gesture, no animator)

    private func applyLiveDelta(_ delta: CGFloat) {
        liveDelta = delta
        let raw      = snappedOffset + delta
        let progress = clampedProgress(raw)
        placeSheet(at: raw)
        // Disable CALayer implicit animations for immediate response
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(progress), bottom: bottomRadius(progress), progress: progress)
        innerView.transform = .identity
        CATransaction.commit()
    }

    // MARK: Sheet pan gesture (capsule handle + empty state area)

    @objc private func handleSheetPan(_ pan: UIPanGestureRecognizer) {
        // If the list scroll pan is active, defer to it
        if let sv = listScrollView,
           sv.panGestureRecognizer.state == .changed || sv.panGestureRecognizer.state == .began {
            if !isListEmpty { return }
        }

        let translation = pan.translation(in: view).y
        let velocity    = pan.velocity(in: view).y

        switch pan.state {
        case .began:
            feedbackGenerator.prepare()

        case .changed:
            applyLiveDelta(translation)

        case .ended, .cancelled, .failed:
            let rawOffset = snappedOffset + translation
            let clamped   = min(max(0, rawOffset), collapsedOffset)
            let should    = resolveSnap(velocity: velocity,
                                        translation: translation,
                                        clamped: clamped)
            liveDelta = 0
            commitSnap(to: should ? collapsedOffset : 0, velocity: velocity)

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

    @objc private func handleListPan(_ pan: UIPanGestureRecognizer) {
        guard let sv = listScrollView else { return }
        let topInset    = -sv.adjustedContentInset.top
        let translation = pan.translation(in: sv).y
        let velocity    = pan.velocity(in: sv).y
        let atTop       = sv.contentOffset.y <= topInset + 1

        switch pan.state {
        case .began:
            feedbackGenerator.prepare()

        case .changed:
            // ── Collapse: at list top, pulling down ──
            if atTop && velocity > 0 {
                if !wasAtTop { capturedTranslationAtTop = translation }
                if let captured = capturedTranslationAtTop {
                    applyLiveDelta(max(0, translation - captured))
                    sv.contentOffset.y = topInset
                }
            } else if capturedTranslationAtTop != nil && !atTop {
                capturedTranslationAtTop = nil
                applyLiveDelta(0)
            }

            // ── Expand: sheet collapsed, pulling up ──
            if isCollapsedState && translation < 0 {
                if !isExpandingFromCollapsed {
                    savedScrollOffsetY = topInset
                    isExpandingFromCollapsed = true
                    sv.isScrollEnabled = false
                }
                applyLiveDelta(translation)
                delegateProxy?.cancelNext = true
            }

            // Block list scroll while collapsed and not yet expanding
            if isCollapsedState && !isExpandingFromCollapsed {
                sv.contentOffset.y = topInset
            }

            wasAtTop = atTop

        case .ended, .cancelled, .failed:
            let drag = liveDelta
            capturedTranslationAtTop = nil
            wasAtTop = false

            guard drag != 0 else {
                sv.isScrollEnabled = true
                isExpandingFromCollapsed = false
                return
            }

            if isExpandingFromCollapsed {
                isExpandingFromCollapsed = false
                delegateProxy?.cancelNext = true
                // Pin the content offset and keep isScrollEnabled = false.
                // Both are released inside commitSnap's addCompletion, which fires
                // exactly when the spring animation settles — no timer needed.
                delegateProxy?.lockedOffsetY = savedScrollOffsetY
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: savedScrollOffsetY),
                                    animated: false)
            } else {
                // Collapsing gesture, or any other case: re-enable scroll immediately.
                sv.isScrollEnabled = true
                if drag > 0 && !atTop {
                    delegateProxy?.cancelNext = true
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: topInset), animated: false)
                }
            }

            let rawOffset = snappedOffset + drag
            let clamped   = min(max(0, rawOffset), collapsedOffset)
            let should    = resolveSnap(velocity: velocity,
                                        translation: drag, clamped: clamped)
            liveDelta = 0
            commitSnap(to: should ? collapsedOffset : 0, velocity: velocity)

        default: break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension SheetViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gr === sheetPan else { return true }
        // Must be inside the sheet panel
        guard outerView.frame.contains(touch.location(in: view)) else { return false }
        // When list is present, let UIScrollView handle touches inside it
        // (handleListPan drives the sheet from there). Exception: collapsed state,
        // where we need sheetPan to respond for the expand gesture as well.
        if !isListEmpty, let sv = listScrollView, !isCollapsedState {
            let pointInSV = touch.location(in: sv)
            if sv.bounds.contains(pointInSV) { return false }
        }
        return true
    }
}

// MARK: - PassthroughView

/// A UIView that returns nil from hitTest when no subview claims the touch,
/// allowing gestures (e.g. MapKit pinch/pan) on views behind it to pass through.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - DecelerationCanceller

/// Intercepts UIScrollViewDelegate to cancel momentum scroll when the
/// sheet pan gesture takes over.
private final class DecelerationCanceller: NSObject, UIScrollViewDelegate {
    weak var original: AnyObject?
    var cancelNext  = false
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
