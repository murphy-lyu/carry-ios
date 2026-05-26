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
//    outerView  (clipsToBounds = false)   ← moves up/down, scales
//      ├── coverView  (y: expandedHeight) ← rubber-band gap filler
//      └── innerView  (clipsToBounds = true, cornerRadius animated)
//            └── hostingView              ← UIHostingController.view
//

import UIKit
import SwiftUI

// MARK: - SwiftUI interface

struct CarryBottomSheet<Content: View>: UIViewControllerRepresentable {

    let expandedHeight: CGFloat
    let collapsedOffset: CGFloat
    /// Colour used for the rubber-band gap cover below the sheet.
    let coverColor: UIColor
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
            coverColor: coverColor,
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
        vc.updateCoverColor(coverColor)
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

    /// Moves and scales; clipsToBounds = false so coverView is visible.
    private let outerView = UIView()
    /// Stays within outerView bounds; clips content to rounded corners.
    private let innerView = UIView()
    /// Sits below innerView inside outerView, fills rubber-band gap.
    private let coverView = UIView()

    // MARK: Scroll coordination

    private var sheetPan: UIPanGestureRecognizer!
    private weak var listScrollView: UIScrollView?
    private var delegateProxy: DecelerationCanceller?
    private var delegateObservation: NSKeyValueObservation?

    private var capturedTranslationAtTop: CGFloat?
    private var wasAtTop = false
    private var isExpandingFromCollapsed = false
    private var savedScrollOffsetY: CGFloat = 0

    // MARK: Init

    init(expandedHeight: CGFloat, collapsedOffset: CGFloat,
         coverColor: UIColor, isListEmpty: Bool) {
        self.expandedHeight = expandedHeight
        self.collapsedOffset = collapsedOffset
        self.isListEmpty = isListEmpty
        super.init(nibName: nil, bundle: nil)
        coverView.backgroundColor = coverColor
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        // outerView: moves, scales; does NOT clip
        outerView.clipsToBounds = false
        view.addSubview(outerView)

        // coverView: rubber-band gap filler (below innerView inside outerView)
        outerView.addSubview(coverView)

        // innerView: clips SwiftUI content to the animated corner radius.
        // Use autoresizingMask so its frame tracks outerView.bounds automatically —
        // this avoids setting innerView.frame directly while a transform is active
        // (which is undefined behavior per UIKit docs).
        innerView.clipsToBounds = true
        innerView.layer.cornerCurve = .continuous
        innerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
        applyCornerMask(to: innerView,
                        top: 36 + progress * 6,
                        bottom: progress * 20)
        innerView.transform = CGAffineTransform(scaleX: 1.0 - progress * 0.03, y: 1)
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

    func updateCoverColor(_ color: UIColor) {
        coverView.backgroundColor = color
    }

    func updateLayout(expandedHeight h: CGFloat, collapsedOffset c: CGFloat) {
        guard h != expandedHeight || c != collapsedOffset else { return }
        let wasCollapsed = isCollapsedState
        expandedHeight = h
        collapsedOffset = c
        // Animate the repositioning to match SwiftUI's spring on isEffectivelyEmpty
        UIView.animate(withDuration: 0.5, delay: 0,
                       usingSpringWithDamping: 0.82, initialSpringVelocity: 0) {
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

        let y = h - expandedHeight + banded - lift
        outerView.frame = CGRect(x: 0, y: y, width: w, height: expandedHeight)
        // innerView fills outerView via autoresizingMask — never set .frame directly
        // while a transform may be active (undefined behavior in UIKit).
        coverView.frame = CGRect(x: 0, y: expandedHeight, width: w, height: 200)
    }

    /// Called inside UIViewPropertyAnimator.addAnimations — the animator drives
    /// the implicit CALayer animations on the mask path and transform.
    private func setProgress(_ progress: CGFloat, animated: Bool) {
        let topRadius:    CGFloat = 36 + progress * 6      // 36 → 42
        let bottomRadius: CGFloat = progress * 20           // 0  → 20
        let scaleX:       CGFloat = 1.0 - progress * 0.03  // 1.0 → 0.97
        applyCornerMask(to: innerView, top: topRadius, bottom: bottomRadius)
        innerView.transform = CGAffineTransform(scaleX: scaleX, y: 1)
    }

    /// Per-corner rounded rect mask so top and bottom radii can differ.
    /// Caller is responsible for wrapping in CATransaction.setDisableActions(true)
    /// if an implicit animation should be suppressed.
    private func applyCornerMask(to targetView: UIView, top: CGFloat, bottom: CGFloat) {
        let w = targetView.bounds.width
        let h = targetView.bounds.height
        guard w > 0, h > 0 else { return }

        let path = UIBezierPath()
        let tl = top, tr = top, bl = bottom, br = bottom
        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: tr), controlPoint: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addQuadCurve(to: CGPoint(x: w - br, y: h), controlPoint: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: bl, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - bl), controlPoint: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addQuadCurve(to: CGPoint(x: tl, y: 0), controlPoint: CGPoint(x: 0, y: 0))
        path.close()

        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        targetView.layer.mask = maskLayer
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

    private func bottomLift(_ progress: CGFloat) -> CGFloat { progress * 12 }

    // MARK: Snap animation

    private func commitSnap(to target: CGFloat, velocity: CGFloat) {
        runningAnimator?.stopAnimation(true)

        let currentRaw = snappedOffset + liveDelta
        let travel     = target - min(max(0, currentRaw), collapsedOffset)
        let normV      = abs(travel) < 1 ? 0 : max(-30, min(30, velocity / max(abs(travel), 1)))
        let isCollapsing = target > snappedOffset + liveDelta / 2

        onSnapChanged?(isCollapsing)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        let params = UISpringTimingParameters(
            dampingRatio: 0.82,
            initialVelocity: CGVector(dx: 0, dy: normV)
        )
        let anim = UIViewPropertyAnimator(duration: 0.5, timingParameters: params)

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
            // Re-apply mask at final size (bounds may have changed during animation).
            // Disable implicit animations since we're outside any animator context.
            let p = self.clampedProgress(target)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.applyCornerMask(to: self.innerView,
                                 top: 36 + p * 6, bottom: p * 20)
            CATransaction.commit()
        }

        runningAnimator = anim
        anim.startAnimation()
    }

    // MARK: Snap decision

    private func resolveSnap(velocity: CGFloat, translation: CGFloat,
                              clamped: CGFloat) -> Bool {
        if velocity > 650  || translation > collapsedOffset * 0.46 { return true }
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
        applyCornerMask(to: innerView,
                        top: 36 + progress * 6, bottom: progress * 20)
        innerView.transform = CGAffineTransform(scaleX: 1.0 - progress * 0.03, y: 1)
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
            sv.isScrollEnabled = true
            let drag = liveDelta
            capturedTranslationAtTop = nil
            wasAtTop = false

            guard drag != 0 else {
                isExpandingFromCollapsed = false
                return
            }

            if isExpandingFromCollapsed {
                isExpandingFromCollapsed = false
                delegateProxy?.cancelNext = true
                delegateProxy?.lockedOffsetY = savedScrollOffsetY
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: savedScrollOffsetY),
                                    animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.delegateProxy?.lockedOffsetY = nil
                }
            } else if drag > 0 && !atTop {
                delegateProxy?.cancelNext = true
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: topInset), animated: false)
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
