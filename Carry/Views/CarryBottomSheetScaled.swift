//
//  CarryBottomSheetScaled.swift
//  Carry
//
//  High-performance bottom sheet driven entirely by UIKit.
//  UIViewPropertyAnimator + CALayer — SwiftUI body never re-evaluates
//  during spring animations.
//
//  View hierarchy inside ScaledSheetViewController.view (full-screen):
//
//    clippingView (clipsToBounds = true)  ← shrinks from bottom on collapse
//      └── outerView  (clipsToBounds = false)   ← moves up/down, scales
//            └── innerView  (clipsToBounds = true, mask = innerMaskLayer)
//                  └── hostingView              ← UIHostingController.view
//

import UIKit
import SwiftUI

// MARK: - SwiftUI interface

struct CarryBottomSheetScaled<Content: View>: UIViewControllerRepresentable {

    let expandedHeight: CGFloat
    let collapsedOffset: CGFloat
    @Binding var mapCityOpacity: Double
    /// Set to `true` externally (Siri shortcut, map button) to collapse.
    @Binding var collapseRequest: Bool
    /// Whether the list is empty — affects which gesture zones are active.
    let isListEmpty: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> ScaledSheetViewController {
        let vc = ScaledSheetViewController(
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

    func updateUIViewController(_ vc: ScaledSheetViewController, context: Context) {
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
        weak var sheetVC: ScaledSheetViewController?
        var hostingVC: UIHostingController<AnyView>?
        var mapCityOpacityBinding: Binding<Double>?
    }
}

// MARK: - ScaledSheetViewController

final class ScaledSheetViewController: UIViewController {
    private enum PanDriver {
        case none
        case sheet
        case list
    }

    // MARK: Configuration

    private(set) var expandedHeight: CGFloat
    private(set) var collapsedOffset: CGFloat
    var isListEmpty: Bool = false

    // MARK: Visual metrics (1:1 from Tripsy measurement, iPhone 17 Pro @3x)

    /// Corner radius when fully expanded (all 4 corners).
    private let expandedRadius:        CGFloat = 36
    /// Top-left / top-right radius when fully collapsed.
    private let collapsedTopRadius:    CGFloat = 36
    /// Bottom-left / bottom-right radius when fully collapsed.
    private let collapsedBottomRadius: CGFloat = 48
    /// Horizontal inset on each side when collapsed.
    private let collapsedSideMargin:   CGFloat = 8
    /// Gap between sheet bottom and screen bottom when collapsed.
    private let collapsedBottomMargin: CGFloat = 8

    // MARK: Effect progress

    /// Position-driven progress (0...1). Used by side/bottom insets so they change
    /// continuously with drag, matching Tripsy/Flighty's "always-following" feel.
    private func effectProgress(_ p: CGFloat) -> CGFloat {
        min(max(0, p), 1)
    }

    /// Bottom clipping/reveal only happens in the final tail of collapse to avoid
    /// the "sheet gets short first, then falls" artifact on fast downward auto-snap.
    private func bottomRevealProgress(_ p: CGFloat) -> CGFloat {
        let threshold: CGFloat = 0.97
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
    /// Shape state decoupled from position to prevent high-velocity jump shrink.
    private var shapeProgressState: CGFloat = 0
    private var shapeDisplayLink: CADisplayLink?
    private var directMaskSyncDisplayLink: CADisplayLink?
    private var directMaskSyncProgress: CGFloat = 0
    private var directPositionDisplayLink: CADisplayLink?
    private var directPositionStartOffset: CGFloat = 0
    private var directPositionTargetOffset: CGFloat = 0
    private var directPositionDuration: CFTimeInterval = 0
    private var directPositionStartTime: CFTimeInterval = 0
    private var directPositionFixedProgress: CGFloat = 0
    private var directPositionCompletion: (() -> Void)?
    private var directPositionTickCount: Int = 0
    private var directPositionCurrentOffset: CGFloat = 0
    private var snapShapeStart: CGFloat = 0
    private var snapShapeTarget: CGFloat = 0

    private var isCollapsedState: Bool { snappedOffset >= collapsedOffset - 8 }
    private var runningAnimator: UIViewPropertyAnimator?
    /// Monotonic token for snap animations; stale completions must not mutate state.
    private var animationGeneration: Int = 0
    /// Ensures only one gesture source drives liveDelta/snap at a time.
    private var activePanDriver: PanDriver = .none
    private var lastGestureSource: String = "none"
    /// Temporary switch: disable gesture-end auto snap to isolate pure manual drag behavior.
    private let disableGestureAutoSnap: Bool = true

    // MARK: View hierarchy

    /// Clips the sheet from below: height = screenHeight - bottomLift.
    /// As the sheet collapses, this shrinks and reveals background, creating
    /// the "ship leaving dock" gap at the bottom.
    /// ScaledPassthroughView so touches outside the sheet reach MapKit behind it.
    private let clippingView = ScaledPassthroughView()
    /// Moves and scales; clipsToBounds = false.
    private let outerView = UIView()
    /// Stays within outerView bounds; clips content to rounded corners.
    private let innerView = UIView()
    /// Reused mask layer on innerView — path is updated in place so
    /// UIViewPropertyAnimator can spring-animate it automatically.
    private let innerMaskLayer = CAShapeLayer()
    private var lastMaskW: CGFloat = -1
    private var lastMaskTop: CGFloat = -1
    private var lastMaskBottom: CGFloat = -1
    private var lastMaskVisibleH: CGFloat = -1
    /// SwiftUI hosting view — referenced so placeSheet can keep its frame
    /// in lockstep with outerView/innerView. Relying on autoresizingMask
    /// alone caused SwiftUI content to drift right with each gesture: the
    /// mask propagates during the next layout pass (outside the animator's
    /// transaction), so the hosting view briefly saw an in-between width
    /// and accumulated tiny layout differences across iterations.
    private weak var hostingView: UIView?

    // MARK: Scroll coordination

    private var sheetPan: UIPanGestureRecognizer!
    private weak var listScrollView: UIScrollView?
    private var delegateProxy: ScaledDecelerationCanceller?
    private var delegateObservation: NSKeyValueObservation?

    /// Pre-allocated so the Taptic Engine is warm before the first snap.
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .soft)

    private var capturedTranslationAtTop: CGFloat?
    private var wasAtTop = false
    private let expandSnapMinTranslation: CGFloat = 26
    private let expandSnapMinVelocity: CGFloat = -260
    // Reserved for future snap-mode restoration.

    // MARK: Init

    init(expandedHeight: CGFloat, collapsedOffset: CGFloat, isListEmpty: Bool) {
        self.expandedHeight = expandedHeight
        self.collapsedOffset = collapsedOffset
        self.isListEmpty = isListEmpty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    /// Use ScaledPassthroughView as the root so touches outside the sheet panel
    /// fall through to MapKit (or any other view behind the sheet).
    override func loadView() {
        view = ScaledPassthroughView()
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
        innerView.clipsToBounds = true
        // Mask handles all corner rounding; set once, path updated in place.
        innerView.layer.mask = innerMaskLayer
        outerView.addSubview(innerView)

        // Pan gesture on the full view; shouldReceive limits it to sheet zone.
        sheetPan = UIPanGestureRecognizer(target: self, action: #selector(handleSheetPan(_:)))
        sheetPan.delegate = self
        view.addGestureRecognizer(sheetPan)

        // Sync initial visual state
        shapeProgressState = 0
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
        innerView.addSubview(hosting.view)
        hostingView = hosting.view
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

    private struct SheetGeometry {
        let clippingFrame: CGRect
        let outerFrame: CGRect
        let positionProgress: CGFloat
        let shapeProgress: CGFloat
    }

    private func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    private func geometry(for rawOffset: CGFloat, shapeProgressOverride: CGFloat? = nil) -> SheetGeometry? {
        let banded = rubberBand(rawOffset)
        let positionProgress = clampedProgress(rawOffset)
        let shapeProgress = shapeProgressOverride ?? shapeProgressState
        let lift = bottomLift(positionProgress)
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return nil }

        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let sideMargin = pixelAligned(collapsedSideMargin * effectProgress(positionProgress), scale: scale)
        let y = pixelAligned(h - expandedHeight + banded, scale: scale)
        let width = max(0, pixelAligned(w - 2 * sideMargin, scale: scale))
        let height = max(0, pixelAligned(expandedHeight, scale: scale))
        let clippingHeight = max(0, pixelAligned(h - lift, scale: scale))

        return SheetGeometry(
            clippingFrame: CGRect(x: 0, y: 0, width: w, height: clippingHeight),
            outerFrame: CGRect(x: sideMargin, y: y, width: width, height: height),
            positionProgress: positionProgress,
            shapeProgress: shapeProgress
        )
    }

    private func setShapeProgress(_ value: CGFloat) {
        shapeProgressState = min(max(0, value), 1)
    }

    private func stopShapeDisplayLink() {
        shapeDisplayLink?.invalidate()
        shapeDisplayLink = nil
    }

    private func stopDirectMaskSync() {
        directMaskSyncDisplayLink?.invalidate()
        directMaskSyncDisplayLink = nil
    }

    private func startDirectMaskSync(fixedProgress: CGFloat) {
        stopDirectMaskSync()
        directMaskSyncProgress = fixedProgress
        let link = CADisplayLink(target: self, selector: #selector(handleDirectMaskSyncTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        directMaskSyncDisplayLink = link
    }

    @objc private func handleDirectMaskSyncTick(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(directMaskSyncProgress),
                        bottom: bottomRadius(directMaskSyncProgress),
                        progress: directMaskSyncProgress)
        CATransaction.commit()
    }

    private func stopDirectPositionSync() {
        directPositionDisplayLink?.invalidate()
        directPositionDisplayLink = nil
        directPositionCompletion = nil
    }

    private func startDirectPositionSync(from start: CGFloat,
                                         to target: CGFloat,
                                         duration: CFTimeInterval,
                                         fixedProgress: CGFloat,
                                         completion: @escaping () -> Void) {
        stopDirectPositionSync()
        directPositionStartOffset = start
        directPositionTargetOffset = target
        directPositionDuration = max(0.001, duration)
        directPositionStartTime = CACurrentMediaTime()
        directPositionFixedProgress = fixedProgress
        directPositionCompletion = completion
        directPositionTickCount = 0
        directPositionCurrentOffset = start
        let link = CADisplayLink(target: self, selector: #selector(handleDirectPositionTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        directPositionDisplayLink = link
    }

    @objc private func handleDirectPositionTick(_ link: CADisplayLink) {
        let t = min(max((CACurrentMediaTime() - directPositionStartTime) / directPositionDuration, 0), 1)
        let idealRaw = directPositionStartOffset + CGFloat(t) * (directPositionTargetOffset - directPositionStartOffset)
        let dt = max(1.0 / 120.0, link.targetTimestamp - link.timestamp)
        let totalDistance = abs(directPositionTargetOffset - directPositionStartOffset)
        let expectedStep = totalDistance * CGFloat(dt / directPositionDuration)
        // Clamp per-frame travel to suppress dropped-frame "jump steps"
        // while keeping overall linear progression.
        let maxStep = max(2, min(18, expectedStep * 1.35))
        let delta = idealRaw - directPositionCurrentOffset
        let step = max(-maxStep, min(maxStep, delta))
        let raw = directPositionCurrentOffset + step
        directPositionCurrentOffset = raw
        directPositionTickCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSheet(at: raw, shapeProgressOverride: directPositionFixedProgress)
        // Keep position fully per-frame. Delay heavy mask path rebuilds to the
        // tail phase to reduce mid-path hitching on direct snap.
        if t >= 0.88 || t >= 1 {
            applyCornerMask(top: topRadius(directPositionFixedProgress),
                            bottom: bottomRadius(directPositionFixedProgress),
                            progress: directPositionFixedProgress)
        }
        CATransaction.commit()
        snappedOffset = raw
        liveDelta = 0

        if t >= 1, abs(directPositionTargetOffset - directPositionCurrentOffset) <= 0.5 {
            let completion = directPositionCompletion
            stopDirectPositionSync()
            completion?()
        }
    }

    private func startSnapShapeFollow(duration: CFTimeInterval) {
        stopShapeDisplayLink()
        guard duration > 0 else {
            setShapeProgress(snapShapeTarget)
            return
        }
        let startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(handleShapeDisplayLink(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.accessibilityLabel = "\(startTime)|\(duration)"
        shapeDisplayLink = link
    }

    @objc private func handleShapeDisplayLink(_ link: CADisplayLink) {
        guard let payload = link.accessibilityLabel else { return }
        let parts = payload.split(separator: "|")
        guard parts.count == 2,
              let start = CFTimeInterval(parts[0]),
              let duration = CFTimeInterval(parts[1]) else { return }

        let t = min(max((CACurrentMediaTime() - start) / duration, 0), 1)
        // Ease-out so shape follows continuously while avoiding abrupt late shrink.
        let eased = 1 - pow(1 - t, 2)
        let next = snapShapeStart + CGFloat(eased) * (snapShapeTarget - snapShapeStart)
        setShapeProgress(next)

        let raw: CGFloat
        if let pf = outerView.layer.presentation()?.frame {
            raw = pf.origin.y - (view.bounds.height - expandedHeight)
        } else {
            raw = snappedOffset + liveDelta
        }
        placeSheet(at: raw, shapeProgressOverride: shapeProgressState)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(shapeProgressState), bottom: bottomRadius(shapeProgressState), progress: shapeProgressState)
        CATransaction.commit()

        if t >= 1 {
            stopShapeDisplayLink()
        }
    }

    private func placeSheet(at rawOffset: CGFloat, shapeProgressOverride: CGFloat? = nil) {
        guard let g = geometry(for: rawOffset, shapeProgressOverride: shapeProgressOverride) else { return }
        clippingView.frame = g.clippingFrame
        outerView.frame = g.outerFrame

        // Explicitly sync innerView + hostingView frames in the SAME runloop turn
        // as outerView frame updates, so SwiftUI never consumes transient widths.
        let innerBounds = outerView.bounds
        innerView.frame = innerBounds
        hostingView?.frame = innerBounds
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

        // Keep full height for almost the whole descent.
        // Only reveal bottom clipping in the very final tail.
        let rawVisible = clippingView.frame.height - outerView.frame.origin.y
        let ep         = bottomRevealProgress(progress)
        let visibleH   = max(0, min(fullH, fullH + ep * (rawVisible - fullH)))

        // Path rebuild is expensive. Skip tiny deltas that are visually identical.
        if abs(w - lastMaskW) < 0.25,
           abs(top - lastMaskTop) < 0.25,
           abs(bottom - lastMaskBottom) < 0.25,
           abs(visibleH - lastMaskVisibleH) < 0.5 {
            return
        }

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
        lastMaskW = w
        lastMaskTop = top
        lastMaskBottom = bottom
        lastMaskVisibleH = visibleH
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

    private func currentVisualOffset() -> CGFloat {
        let h = view.bounds.height
        if let pf = outerView.layer.presentation()?.frame {
            return pf.origin.y - (h - expandedHeight)
        }
        return snappedOffset + liveDelta
    }

    /// When user starts dragging, immediately take over from any running snap animation
    /// so the sheet can follow finger 1:1 without fighting background animators.
    private func beginInteractiveControl() {
        stopShapeDisplayLink()
        if let animator = runningAnimator {
            animationGeneration += 1  // invalidate stale completion before stopping
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
            runningAnimator = nil
        }
        stopDirectMaskSync()
        stopDirectPositionSync()
        var visual = min(max(0, currentVisualOffset()), collapsedOffset)
        if visual >= collapsedOffset - expandSnapMinTranslation {
            visual = collapsedOffset
        } else if visual <= expandSnapMinTranslation {
            visual = 0
        }
        snappedOffset = visual
        liveDelta = 0
        let p = clampedProgress(visual)
        setShapeProgress(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSheet(at: visual, shapeProgressOverride: p)
        applyCornerMask(top: topRadius(p), bottom: bottomRadius(p), progress: p)
        CATransaction.commit()
    }

    private func commitSnap(to target: CGFloat, velocity: CGFloat, source: String = "unknown") {
        let clampedVisual = min(max(0, currentVisualOffset()), collapsedOffset)

        // Invalidate older completions before stopping the current animation.
        animationGeneration += 1
        let generation = animationGeneration
        stopShapeDisplayLink()
        if let animator = runningAnimator {
            // Freeze exactly at current visual state; do not jump to end-state.
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        runningAnimator = nil

        // Converge model state to current visual state first.
        snappedOffset = clampedVisual
        liveDelta = 0
        let visualProgress = clampedProgress(clampedVisual)
        setShapeProgress(visualProgress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSheet(at: clampedVisual)
        applyCornerMask(top: topRadius(visualProgress),
                        bottom: bottomRadius(visualProgress),
                        progress: visualProgress)
        CATransaction.commit()

        let travel = target - clampedVisual
        let normV  = abs(travel) < 1 ? 0 : max(-30, min(30, velocity / travel))

        onSnapChanged?(target >= collapsedOffset)
        feedbackGenerator.impactOccurred()

        if target == collapsedOffset, let sv = listScrollView {
            let topInset = -sv.adjustedContentInset.top
            delegateProxy?.lockedOffsetY = topInset
            delegateProxy?.cancelNext = true
        }

        let isCollapsing = target >= collapsedOffset - 1
        // Fast handle-down release should be one-way and non-bouncy.
        let isDirectHandleCollapse = (source == "sheetPanDirectCollapse")
        let isDirectExpand = (source == "sheetPanDirectExpand" || source == "listPanUp")
        if isDirectHandleCollapse || isDirectExpand {
            stopShapeDisplayLink()
            stopDirectMaskSync()
            stopDirectPositionSync()
            startDirectPositionSync(
                from: clampedVisual,
                to: target,
                duration: 0.48,
                fixedProgress: visualProgress
            ) { [weak self] in
                guard let self else { return }
                guard generation == self.animationGeneration else { return }
                self.snappedOffset = target
                self.liveDelta = 0
                self.runningAnimator = nil
                let p = self.clampedProgress(target)
                self.setShapeProgress(p)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.placeSheet(at: target)
                self.applyCornerMask(top: self.topRadius(p), bottom: self.bottomRadius(p), progress: p)
                CATransaction.commit()
                if let sv = self.listScrollView, self.delegateProxy?.lockedOffsetY != nil {
                    self.delegateProxy?.lockedOffsetY = nil
                    sv.isScrollEnabled = true
                }
            }
            return
        }
        let anim: UIViewPropertyAnimator
        let dampingRatio: CGFloat = isCollapsing ? 0.95 : 0.88
        let scaledNormV = isCollapsing ? normV * 0.5 : normV
        let params = UISpringTimingParameters(
            dampingRatio: dampingRatio,
            initialVelocity: CGVector(dx: 0, dy: scaledNormV)
        )
        anim = UIViewPropertyAnimator(duration: 0.68, timingParameters: params)
        let targetShapeProgress = clampedProgress(target)
        stopDirectMaskSync()
        snapShapeStart = shapeProgressState
        snapShapeTarget = targetShapeProgress
        startSnapShapeFollow(duration: 0.68)
        anim.addAnimations { [weak self] in
            guard let self else { return }
            // Position channel only; shape follows via displayLink.
            self.placeSheet(at: target)
        }
        anim.addCompletion { [weak self] _ in
            guard let self else { return }
            guard generation == self.animationGeneration else { return }
            self.stopShapeDisplayLink()
            self.stopDirectMaskSync()
            self.stopDirectPositionSync()
            self.snappedOffset = target
            self.liveDelta = 0
            self.runningAnimator = nil
            let p = self.clampedProgress(target)
            self.setShapeProgress(p)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.applyCornerMask(top: self.topRadius(self.shapeProgressState), bottom: self.bottomRadius(self.shapeProgressState), progress: self.shapeProgressState)
            CATransaction.commit()
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
        stopShapeDisplayLink()
        if let animator = runningAnimator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
            runningAnimator = nil
        }
        let visual = min(max(0, currentVisualOffset()), collapsedOffset)
        snappedOffset = visual
        liveDelta = 0
        let p = clampedProgress(visual)
        setShapeProgress(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSheet(at: visual, shapeProgressOverride: p)
        applyCornerMask(top: topRadius(p), bottom: bottomRadius(p), progress: p)
        CATransaction.commit()
    }

    private func finalizeGestureAndSnap(source: String, velocity: CGFloat, translation: CGFloat, rawOffset: CGFloat) {
        let clamped = min(max(0, rawOffset), collapsedOffset)
        let shouldCollapse = resolveSnap(velocity: velocity, translation: translation, clamped: clamped)
        lastGestureSource = source
        commitSnap(to: shouldCollapse ? collapsedOffset : 0, velocity: velocity, source: source)
    }

    // MARK: Snap decision

    private func resolveSnap(velocity: CGFloat, translation: CGFloat,
                              clamped: CGFloat) -> Bool {
        // Special-case: when starting from collapsed, allow light upward pull
        // to commit an expand instead of immediately snapping back down.
        if snappedOffset >= collapsedOffset - 1, translation < 0 {
            if velocity < -220 || translation < -34 { return false }
        }
        if velocity > 650  || translation > collapsedOffset * 0.50 { return true }
        if velocity < -350 || translation < -70 { return false }
        return clamped > collapsedOffset * 0.68
    }

    // MARK: Live drag visual update (during gesture, no animator)

    private func applyLiveDelta(_ delta: CGFloat) {
        stopShapeDisplayLink()
        liveDelta = delta
        let raw      = snappedOffset + delta
        let progress = clampedProgress(raw)
        setShapeProgress(progress)
        placeSheet(at: raw)
        // Disable CALayer implicit animations for immediate response
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(shapeProgressState), bottom: bottomRadius(shapeProgressState), progress: shapeProgressState)
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
                lastGestureSource = "sheetPanDirectCollapse"
                commitSnap(to: collapsedOffset, velocity: velocity, source: "sheetPanDirectCollapse")
            } else {
                let shouldExpand = (translation <= -expandSnapMinTranslation) || (velocity <= expandSnapMinVelocity)
                if shouldExpand {
                    // Handle upward release explicitly so handle-up uses the same
                    // controlled snap pipeline as direct collapse.
                    lastGestureSource = "sheetPanDirectExpand"
                    commitSnap(to: 0, velocity: velocity, source: "sheetPanDirectExpand")
                } else {
                    // Near-collapsed micro-drag: snap back to collapsed rather than
                    // leaving a floating sub-pixel position that looks identical to
                    // collapsed but breaks isCollapsedState on the next gesture.
                    let currentPos = snappedOffset + translation
                    if currentPos >= collapsedOffset - expandSnapMinTranslation {
                        lastGestureSource = "sheetPanDirectCollapse"
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
        let proxy = delegateProxy ?? ScaledDecelerationCanceller()
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

    deinit {
        stopShapeDisplayLink()
        stopDirectMaskSync()
        stopDirectPositionSync()
    }

    @objc private func handleListPan(_ pan: UIPanGestureRecognizer) {
        guard let sv = listScrollView else { return }
        let topInset    = -sv.adjustedContentInset.top
        let translation = pan.translation(in: sv).y
        let velocity    = pan.velocity(in: sv).y
        let atTop       = sv.contentOffset.y <= topInset + 1

        switch pan.state {
        case .began:
            if activePanDriver == .sheet {
                return
            }
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
                // Rule 3: collapsed state ignores content scrolling.
                sv.contentOffset.y = topInset
                if translation < 0 {
                    // Upward pull always acts like pulling the handle up.
                    applyLiveDelta(translation)
                } else {
                    applyLiveDelta(0)
                }
                wasAtTop = true
                break
            }

            // Rule 1: at list top, downward pull hands off to sheet collapse.
            if atTop && translation > 0 {
                if !wasAtTop { capturedTranslationAtTop = translation }
                if let captured = capturedTranslationAtTop {
                    applyLiveDelta(max(0, translation - captured))
                    sv.contentOffset.y = topInset
                }
            } else {
                // Rule 2: otherwise keep normal list scroll behavior.
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
                // Content-area downward release must be behavior-identical to
                // handle-down direct collapse.
                lastGestureSource = "sheetPanDirectCollapse"
                commitSnap(to: collapsedOffset, velocity: velocity, source: "sheetPanDirectCollapse")
            } else {
                let shouldExpand = (drag <= -expandSnapMinTranslation) || (velocity <= expandSnapMinVelocity)
                if shouldExpand {
                    // Lock remains; commitSnap completion will clear it once expanded.
                    lastGestureSource = "listPanUp"
                    commitSnap(to: 0, velocity: velocity, source: "listPanUp")
                } else {
                    let currentPos = snappedOffset + drag
                    if currentPos >= collapsedOffset - expandSnapMinTranslation {
                        // Near-collapsed micro-drag: snap back to collapsed.
                        lastGestureSource = "sheetPanDirectCollapse"
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

extension ScaledSheetViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Critical: prevent the sheet pan and list pan from driving the sheet
        // at the same time. Concurrent recognition can trigger two gesture-end
        // paths close together, causing a transient "hide then expand" flash.
        if gr === sheetPan, other === listScrollView?.panGestureRecognizer { return false }
        if other === sheetPan, gr === listScrollView?.panGestureRecognizer { return false }
        return true
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gr === sheetPan else { return true }
        // Must be inside the sheet panel
        guard outerView.frame.contains(touch.location(in: view)) else { return false }
        // When list is present, always let UIScrollView handle touches inside it.
        // The list pan is the single source of truth for expand/collapse gestures
        // in non-empty state, including collapsed -> expand.
        if !isListEmpty, let sv = listScrollView {
            let pointInSV = touch.location(in: sv)
            if sv.bounds.contains(pointInSV) { return false }
        }
        return true
    }
}

// MARK: - ScaledPassthroughView

/// A UIView that returns nil from hitTest when no subview claims the touch,
/// allowing gestures (e.g. MapKit pinch/pan) on views behind it to pass through.
private final class ScaledPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - ScaledDecelerationCanceller

/// Intercepts UIScrollViewDelegate to cancel momentum scroll when the
/// sheet pan gesture takes over.
private final class ScaledDecelerationCanceller: NSObject, UIScrollViewDelegate {
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
