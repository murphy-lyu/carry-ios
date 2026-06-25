//
//  CarryBottomSheetFX.swift
//  Carry
//
//  High-performance bottom sheet driven entirely by UIKit.
//  UIViewPropertyAnimator + CALayer — SwiftUI body never re-evaluates
//  during spring animations.nag
//
//  View hierarchy inside FXSheetViewController.view (full-screen):
//
//    outerView (clipsToBounds, cornerRadius = bottom corners)  ← card: slides (center),
//      │                                                          uniform-SCALES to narrow,
//      │                                                          bounds.height = collapse clip
//      └── innerView (clipsToBounds, cornerRadius = top corners)
//            └── hostingView  ← UIHostingController.view, FIXED full size
//
//  Width narrowing is a uniform scale TRANSFORM on the card — content + padding scale
//  together (constant ratio, like Flighty/Tripsy), and the host is never resized so
//  SwiftUI never re-lays-out mid-gesture. Corners use two nested single-radius layers
//  (independent top/bottom radii, GPU-native — no CAShapeLayer path / mask rasterisation).
//

import UIKit
import SwiftUI

// MARK: - SwiftUI interface

struct CarryBottomSheetFX<Content: View, Bar: View>: UIViewControllerRepresentable {

    let expandedHeight: CGFloat
    let collapsedOffset: CGFloat
    @Binding var mapCityOpacity: Double
    /// Set to `true` externally (Siri shortcut, map button) to collapse.
    @Binding var collapseRequest: Bool
    /// Whether the list is empty — affects which gesture zones are active.
    let isListEmpty: Bool
    @ViewBuilder let content: () -> Content
    /// 首页底栏（搜索行程 / 我的行程册 / 创建）。底栏被「移进控制器」、与卡片由**同一个**
    /// `UIViewPropertyAnimator` 驱动 → 拖拽逐帧跟手、吸附同曲线同初速度，缩放像素级一致。
    /// 详见 `placeSheet` 里对 `barView` 施加的 transform。
    @ViewBuilder let bottomBar: () -> Bar

    func makeUIViewController(context: Context) -> FXSheetViewController {
        let vc = FXSheetViewController(
            expandedHeight: expandedHeight,
            collapsedOffset: collapsedOffset,
            isListEmpty: isListEmpty
        )
        let hosting = UIHostingController(rootView: AnyView(content()))
        hosting.view.backgroundColor = .clear
        vc.installContent(hosting)
        // 底栏宿主：clear 背景，空白区域不吃 touch（让 pan 穿透到下方列表/卡片，仅按钮吃 tap）。
        let barHosting = UIHostingController(rootView: AnyView(bottomBar()))
        barHosting.view.backgroundColor = .clear
        // 🔴 底栏高度无显式约束、纯靠内容固有尺寸撑（见 installBottomBar）。UIHostingController **默认不会**
        // 在 rootView 变化时重新发布固有尺寸 → 空态启动（底栏内容空、固有高 0）后导入数据，底栏内容变三按钮、
        // 但 frame 高度停在 0 → FXPassthroughView 的「不放行区」(barView.bounds) ≈0 → 点击穿到下层行程卡、误开行程
        // （只在「空态启动→导入」出现、重启即好、还时好时坏=偶有无关布局 pass 救场）。
        // `.intrinsicContentSize` 让 hosting 在内容变化时自动同步固有高度 → 不放行区永远跟上真实高度。见 playbook §33。
        barHosting.sizingOptions = .intrinsicContentSize
        vc.installBottomBar(barHosting)
        context.coordinator.hostingVC = hosting
        context.coordinator.barHostingVC = barHosting
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

    func updateUIViewController(_ vc: FXSheetViewController, context: Context) {
        context.coordinator.mapCityOpacityBinding = $mapCityOpacity
        context.coordinator.hostingVC?.rootView = AnyView(content())
        context.coordinator.barHostingVC?.rootView = AnyView(bottomBar())
        vc.isListEmpty = isListEmpty
        vc.updateLayout(expandedHeight: expandedHeight, collapsedOffset: collapsedOffset)
        if collapseRequest {
            vc.snap(toCollapsed: true, velocity: 0)
            DispatchQueue.main.async { collapseRequest = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var sheetVC: FXSheetViewController?
        var hostingVC: UIHostingController<AnyView>?
        var barHostingVC: UIHostingController<AnyView>?
        var mapCityOpacityBinding: Binding<Double>?

        // Swift 6.3.2 优化器 bug：EarlyPerfInliner 在内联本类(合成) deinit 时，
        // isCallerAndCalleeLayoutConstraintsCompatible 无限递归 → 栈溢出，Release(-O)
        // 构建崩溃（DEBUG 不触发）。根因在编译器、无法修复；用最小作用域把这个 deinit
        // 排除出该优化 pass。deinit 非性能热点，关其优化零运行时代价。
        // 显式空 deinit 让 @_optimize(none) 有可标注的声明（合成 ivar 释放仍受此约束）。
        @_optimize(none)
        deinit {}
    }
}

// MARK: - FXSheetViewController

final class FXSheetViewController: UIViewController {
    private enum PanDriver {
        case none
        case sheet
        case list
    }

    // MARK: Configuration

    private(set) var expandedHeight: CGFloat
    private(set) var collapsedOffset: CGFloat
    var isListEmpty: Bool = false {
        didSet {
            // 空↔有行程切换时切换卡片背板（空+深=磨砂玻璃 / 否则=不透明）。init 期 view 未载入，
            // 跳过；viewDidLoad 里会做首次设置。
            guard isViewLoaded, oldValue != isListEmpty else { return }
            updateEmptyStateSurface()
        }
    }

    // MARK: Visual metrics (1:1 from Tripsy measurement, iPhone 17 Pro @3x)

    /// Top-left / top-right radius when fully expanded.
    private let expandedRadius:        CGFloat = 36
    /// Bottom-left / bottom-right radius when fully expanded (sheet bottom flush + full-width,
    /// so its bottom corners sit on the device's screen corners).
    /// At the flush-expanded rest state the bottom corners sit on the screen's physical corners,
    /// so this MUST stay ≤ the screen radius or a faint crescent of map leaks in the corner.
    /// 40 over-fills into the screen's corner so the display's hardware mask clips it cleanly
    /// (the corner still LOOKS like the screen's ~55 radius). It's a SEPARATE knob from
    /// collapsedBottomRadius on purpose: the flush state needs a small radius for no-leak, the
    /// floating collapsed card wants a large one (56). They can't be unified to one constant
    /// without either a leak (constant 56) or a flatter collapsed card (constant ~44).
    private let expandedBottomRadius:  CGFloat = 40
    /// Top-left / top-right radius when fully collapsed.
    private let collapsedTopRadius:    CGFloat = 36
    /// Bottom-left / bottom-right radius when fully collapsed (rounder than the top for a
    /// softer floating-card bottom). Tune on-device.
    private let collapsedBottomRadius: CGFloat = 56
    /// Horizontal inset on each side when collapsed.
    /// Restrained scaling target (≈Tripsy/Flighty). Tune on-device.
    private let collapsedSideMargin:   CGFloat = 8
    /// Gap between sheet bottom and screen bottom when collapsed.
    private let collapsedBottomMargin: CGFloat = 8

    // MARK: Effect progress

    /// Position-driven progress (0...1). Used by side/bottom insets so they change
    /// continuously with drag, matching Tripsy/Flighty's "always-following" feel.
    private func effectProgress(_ p: CGFloat) -> CGFloat {
        min(max(0, p), 1)
    }

    // Corner radii change linearly with progress so they stay in sync with the
    // gesture at all times — matching Tripsy / Flighty behaviour.
    // effectProgress is intentionally NOT used here: concentrating the change in
    // the last 35% makes corners appear to jump when a fast snap passes through
    // that window. Pill margins and bottom lift still use effectProgress.
    private func topRadius(_ p: CGFloat)    -> CGFloat { expandedRadius       + p * (collapsedTopRadius    - expandedRadius)       }
    private func bottomRadius(_ p: CGFloat) -> CGFloat { expandedBottomRadius + p * (collapsedBottomRadius - expandedBottomRadius) }

    /// Called on main thread when a snap animation begins.
    var onSnapChanged: ((Bool) -> Void)?

    // MARK: State

    /// 0 = expanded, collapsedOffset = collapsed.
    private var snappedOffset: CGFloat = 0
    /// Live drag delta on top of snappedOffset (non-zero only during gesture).
    private var liveDelta: CGFloat = 0
    /// Shape state decoupled from position to prevent high-velocity jump shrink.
    private var shapeProgressState: CGFloat = 0

    private var isCollapsedState: Bool { snappedOffset >= collapsedOffset - 8 }
    private var runningAnimator: UIViewPropertyAnimator?
    /// Monotonic token for snap animations; stale completions must not mutate state.
    private var animationGeneration: Int = 0
    /// Ensures only one gesture source drives liveDelta/snap at a time.
    private var activePanDriver: PanDriver = .none
    private var lastGestureSource: String = "none"

    // MARK: View hierarchy

    /// Outer card layer: positions/slides the sheet, rounds the BOTTOM two corners,
    /// and its bounds HEIGHT performs the bottom clip (creating the "ship leaving dock"
    /// gap). Rounded purely via `layer.cornerRadius` — GPU-native, so nothing is
    /// re-rasterised per frame (the old design rebuilt a CAShapeLayer mask path every
    /// frame, forcing a full-layer mask re-raster — the main residual per-frame cost).
    private let outerView = UIView()
    /// Inner layer: fills outerView and rounds the TOP two corners. Nesting two
    /// single-radius corner layers gives independent top/bottom radii with no path mask.
    private let innerView = UIView()
    /// 卡片磨砂玻璃背板（仅「空态 + 深色」启用）：让身后的 MapKit 地球从卡片透/糊上来，
    /// 使卡片成为场景的一部分、有真实景深——而非给近黑卡片加假光（试过：灰盒子/脏斜面，皆廉价）。
    /// 加在 `innerView` 最底层（hostingView 之下），随卡片同 transform 缩放、被顶角裁切。
    /// 只在空态用：空态是固定缩放浮卡、无拖拽/吸附 → 零性能风险、无过冲漏图；有行程的展开态仍走
    /// 不透明背板（保可读性 + 拖拽性能）。浅色不动（白卡本就立体）。
    private let backdropBlurView = UIVisualEffectView(effect: nil)
    /// SwiftUI hosting view — kept at a FIXED full size and only re-centred per frame
    /// (origin-only shift), so it is never resized during a drag and SwiftUI never
    /// re-lays-out the sheet content mid-gesture.
    private weak var hostingView: UIView?
    /// 底部消隐渐变：盖在内容之上、钉在 `innerView`（卡片可视窗口）底边，随收起裁短自动跟到
    /// 可视底边 → 展开/收起两态都在可视底部把内容向 Sheet 底色柔和消隐。取代原 SwiftUI
    /// `bottomContentFade`（锚在内容底部、收起态被裁到屏外不可见）。不吃点击。
    private let bottomFadeView = FXBottomFadeView()
    private let bottomFadeHeight: CGFloat = 120
    /// 首页底栏的宿主 view（搜索/行程册/创建）。钉在 `view` 底部、z 序在卡片之上，**不**放进
    /// outerView（否则会随卡片一起滑走、改变定位）。缩放在 `placeSheet` 里与卡片**同一 animator**
    /// 施加 `transform`（底边锚定）→ 与卡片像素级同步。
    private weak var barView: UIView?
    /// 底栏左右边距 / 底边距（替代旧 HomeView 里的 `.padding(.horizontal/.bottom, 18)`）。
    private let barSideInset:   CGFloat = 18
    private let barBottomInset: CGFloat = 18

    // MARK: Scroll coordination

    private var sheetPan: UIPanGestureRecognizer!
    private weak var listScrollView: UIScrollView?
    private var delegateProxy: FXDecelerationCanceller?
    private var delegateObservation: NSKeyValueObservation?
    /// 不依赖 delegate 的滚动锁（与 fallback CarryBottomSheet 对齐，见 playbook §16.1）：
    /// 锁定期间直接 KVO 观察 contentOffset，无论谁顶替了 delegate 都能把 offset 拉回，
    /// 绕开 "DecelerationCanceller 代理被 SwiftUI 临时顶替 → scrollViewDidScroll 漏帧" 的时序窗。
    private var contentOffsetObservation: NSKeyValueObservation?

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

    /// Use FXPassthroughView as the root so touches outside the sheet panel
    /// fall through to MapKit (or any other view behind the sheet).
    override func loadView() {
        view = FXPassthroughView()
        view.backgroundColor = .clear
        view.clipsToBounds = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Two nested single-radius corner layers replace the old CAShapeLayer mask:
        //   outerView → rounds the BOTTOM corners + clips the bottom edge (its bounds
        //               height is the visible-window clip line);
        //   innerView → rounds the TOP corners.
        // Both use the continuous (squircle) curve. cornerRadius is GPU-native, so there
        // is no per-frame path construction and no per-frame mask rasterisation.
        outerView.clipsToBounds = true
        outerView.layer.cornerCurve = .continuous
        outerView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // bottom-left, bottom-right
        view.addSubview(outerView)

        innerView.clipsToBounds = true
        innerView.layer.cornerCurve = .continuous
        innerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // top-left, top-right
        // 卡片不透明兜底背景 = Sheet 渐变底端色。根因修复「展开吸附过冲时底部漏 MapKit」：
        // SwiftUI 内容（连同它的 CarrySubtleBackground）固定 = expandedHeight 且钉在 innerView 顶部；
        // 吸附 spring 会把 innerView.bounds 瞬间撑过 expandedHeight，底部多出一条「无内容」的带。
        // 过去这条带是透明的 → 露出后面的地图。给 innerView 自身一层 baseColor（= 内容底端同色），
        // 这条带露出的就是与 Sheet 底端无缝同色，而非地图。正常态被内容完全盖住、不可见。
        // 纯渲染兜底，不碰几何/吸附/手势/内容尺寸（内容固定尺寸的性能不变量保持）。
        innerView.backgroundColor = CarrySubtleBackground.baseUIColor
        outerView.addSubview(innerView)

        // 磨砂玻璃背板必须在 innerView 最底层（内容/消隐渐变都盖在它上面）。
        // 注意 z 序：`installContent`（加 hostingView）在 `makeUIViewController` 里先于本 `viewDidLoad`
        // 执行，故此处用 insert(at: 0) 把磨砂压到最底，而非 addSubview（会盖住已存在的内容）。
        // 是否启用由 updateEmptyStateSurface() 按「空态 + 深色」决定。
        backdropBlurView.isUserInteractionEnabled = false
        innerView.insertSubview(backdropBlurView, at: 0)
        updateEmptyStateSurface()
        // 明暗切换时刷新空态磨砂表面（registerForTraitChanges 替代 iOS 17 已弃用的 traitCollectionDidChange）。
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: FXSheetViewController, _) in
            vc.updateEmptyStateSurface()
        }

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

        // Fallback scroll-view attach: the one-shot 0.15s timer in installContent
        // can miss when the sheet is recreated (e.g. toggling the Dev Options
        // "Enable Scaling Effects" switch rebuilds the whole sheet) and SwiftUI's
        // List hasn't materialised its UIScrollView yet — leaving handleListPan
        // unwired and the scroll lock dead. Re-attempt here, but ONLY when we've
        // never attached (listScrollView == nil), so this does NOT re-attach on
        // mid-session SwiftUI rebuilds (that broader self-heal was tried and
        // reverted, see playbook §16). attachScrollView is idempotent.
        if listScrollView == nil, let hv = hostingView {
            attachScrollView(in: hv)
        }

        guard runningAnimator == nil else { return }
        let raw = snappedOffset + liveDelta
        placeSheet(at: raw)
        // Re-apply mask and transform with correct bounds.
        // setProgress() in viewDidLoad often skips (bounds are zero at that point),
        // so we always refresh here, wrapped in disableActions to avoid implicit animations.
        // 空态固定缩放浮卡 → 圆角用折叠值（progress=1），与 geometry 的空态分支一致。
        let progress = isListEmpty ? 1 : clampedProgress(raw)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(progress), bottom: bottomRadius(progress), progress: progress)
        CATransaction.commit()
    }

    // MARK: Hit-test passthrough outside sheet panel

    // view is full-screen; touches outside outerView should fall through.
    // We handle this in gestureRecognizer shouldReceive rather than hitTest
    // so that subviews (e.g. SwiftUI buttons) still receive taps normally.

    /// 卡片背板：仅「空态 + 深色」用磨砂玻璃（地球透/糊上来），否则用不透明兜底色。
    /// - 空态固定浮卡、无拖拽/吸附 → 磨砂零性能风险，且无过冲 → 可安全把 innerView 透明化让地图透出；
    /// - 有行程的展开态 / 浅色：保持不透明（可读性、拖拽性能、白卡本就立体）。
    private func updateEmptyStateSurface() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if isListEmpty && isDark {
            backdropBlurView.effect = UIBlurEffect(style: .systemThinMaterial)
            innerView.backgroundColor = .clear   // 让地球透过磨砂显出，而非被不透明兜底盖掉
        } else {
            backdropBlurView.effect = nil
            innerView.backgroundColor = CarrySubtleBackground.baseUIColor   // 过冲漏图兜底（见 viewDidLoad）
        }
    }

    // MARK: External API

    func installContent(_ hosting: UIViewController) {
        if #available(iOS 16.0, *) {
            (hosting as? UIHostingController<AnyView>)?.safeAreaRegions = []
        } else {
            hosting.additionalSafeAreaInsets = .zero
        }

        addChild(hosting)
        innerView.addSubview(hosting.view)
        hostingView = hosting.view
        hosting.didMove(toParent: self)

        // 底部消隐渐变盖在内容之上（在 hostingView 之后加入 → z 序在前）；不吃点击，让列表照常滚动/点击。
        bottomFadeView.isUserInteractionEnabled = false
        bottomFadeView.configure(baseColor: CarrySubtleBackground.baseUIColor, peakOpacity: 0.9)
        innerView.addSubview(bottomFadeView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.attachScrollView(in: hosting.view)
        }
    }

    /// 把首页底栏移进控制器：钉在 `view` 底部（leading/trailing/bottom 约束 = 旧的 18pt padding），
    /// z 序在卡片之上。高度由 SwiftUI 内容的固有尺寸决定。缩放不在这里——在 `placeSheet` 里与卡片
    /// 同 animator 施加 `transform`。访问 `self.view` 会触发 `viewDidLoad`（先建好 outerView），
    /// 故底栏 addSubview 必在卡片之后 → 天然在上层。
    func installBottomBar(_ hosting: UIViewController) {
        if #available(iOS 16.0, *) {
            (hosting as? UIHostingController<AnyView>)?.safeAreaRegions = []
        } else {
            hosting.additionalSafeAreaInsets = .zero
        }
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        barView = hosting.view
        // 把底栏交给根视图做「不放行区」防穿透（结构性，见 FXPassthroughView.hitTest）。
        (view as? FXPassthroughView)?.barView = hosting.view
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: barSideInset),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -barSideInset),
            hosting.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -barBottomInset),
        ])
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
            // 空↔有行程切换会改 expandedHeight 走到这里：同步把圆角动到对应态
            // （空态=折叠圆角 progress 1；有行程=按位置）。cornerRadius 可随 UIView.animate 插值。
            let progress = self.isListEmpty ? 1 : self.clampedProgress(self.snappedOffset)
            self.applyCornerMask(top: self.topRadius(progress), bottom: self.bottomRadius(progress), progress: progress)
        }
    }

    func snap(toCollapsed: Bool, velocity: CGFloat) {
        let target: CGFloat = toCollapsed ? collapsedOffset : 0
        commitSnap(to: target, velocity: velocity)
    }

    // MARK: Layout helpers

    private struct SheetGeometry {
        /// Uniform scale that narrows the whole card (content + padding together), so the
        /// inner padding stays a constant RATIO of the card width — matching Flighty/Tripsy,
        /// instead of the content drifting to the edge as an absolute clip would cause.
        let scale: CGFloat
        /// outerView.bounds (pre-scale). Width = full width; height = visibleHeight / scale
        /// so the post-scale visual height equals the intended visible window.
        let boundsSize: CGSize
        /// outerView.center (default anchor 0.5,0.5). Chosen so the post-scale visual frame
        /// is exactly (sideMargin, topY, w-2M, visibleHeight) — keeps the card top pinned at
        /// topY and `presentation().frame.origin.y == topY`, so snap reads are unchanged.
        let center: CGPoint
        let positionProgress: CGFloat
        let shapeProgress: CGFloat
    }

    /// Current uniform scale (1 = expanded). Used to divide cornerRadius so the VISUAL
    /// radius (after the scale) hits the intended value.
    private var currentScale: CGFloat = 1

    private func geometry(for rawOffset: CGFloat, shapeProgressOverride: CGFloat? = nil) -> SheetGeometry? {
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return nil }

        // 空态：固定「缩放浮卡」——满缩放效果（侧/缩放/底 lift = 折叠值）+ 不下滑（banded=0），
        // 但可视高度 = 内容全高（不缩到折叠的 ~188pt）。即把折叠态的视觉效果定格在内容高度上：
        // 左右各 collapsedSideMargin、底部 collapsedBottomMargin 间距、统一 scale、圆角折叠值。
        // 空态无拖拽（见 shouldReceive），故这是它唯一的静止位姿。
        if isListEmpty {
            let sideMargin = collapsedSideMargin
            let scale = max(0.01, (w - 2 * sideMargin) / w)
            // 底部浮距复用折叠态同一常量（与有行程折叠卡逐项一致：侧距/缩放/底距/圆角同源）。
            let lift = collapsedBottomMargin
            let topY = h - expandedHeight
            let visibleHeight = max(1, expandedHeight - lift)
            return SheetGeometry(
                scale: scale,
                boundsSize: CGSize(width: w, height: visibleHeight / scale),
                center: CGPoint(x: w / 2, y: topY + visibleHeight / 2),
                positionProgress: 1,
                shapeProgress: 1
            )
        }

        let banded = rubberBand(rawOffset)
        let positionProgress = clampedProgress(rawOffset)
        let shapeProgress = shapeProgressOverride ?? shapeProgressState
        let lift = bottomLift(positionProgress)

        // All scaling quantities are continuous (no pixel snapping). They can be:
        // the SwiftUI content is laid out ONCE at full size and never resized during a
        // drag (see placeSheet), so a varying width no longer triggers per-frame
        // relayout — the narrowing is a pure clip + GPU-cheap origin shift. Continuous
        // values therefore cost nothing extra and avoid the stair-step that pixel
        // snapping caused on the slowly-varying margins.
        let sideMargin = collapsedSideMargin * effectProgress(positionProgress)
        // Uniform scale narrows the card (and its content + padding, proportionally) —
        // the content is NOT resized, so SwiftUI never re-lays-out; the narrowing is a
        // GPU transform. s = (w - 2·sideMargin) / w.
        let scale = max(0.01, (w - 2 * sideMargin) / w)
        let topY = h - expandedHeight + banded
        // Visible window height: full content height minus how far it has slid down
        // (banded) minus the bottom-edge lift. A pure function of position, so the card's
        // height is ALWAYS locked to its position — the "shrink-before-fall" race is
        // structurally impossible. The card's bottom sits at `topY + visibleHeight = h - lift`.
        let visibleHeight = max(1, expandedHeight - lift - banded)

        // bounds height is divided by scale so the post-scale visual height == visibleHeight;
        // center is placed so the post-scale visual frame is exactly
        // (sideMargin, topY, w-2·sideMargin, visibleHeight) — see SheetGeometry.center.
        return SheetGeometry(
            scale: scale,
            boundsSize: CGSize(width: w, height: visibleHeight / scale),
            center: CGPoint(x: w / 2, y: topY + visibleHeight / 2),
            positionProgress: positionProgress,
            shapeProgress: shapeProgress
        )
    }

    private func setShapeProgress(_ value: CGFloat) {
        shapeProgressState = min(max(0, value), 1)
    }


    private func placeSheet(at rawOffset: CGFloat, shapeProgressOverride: CGFloat? = nil) {
        guard let g = geometry(for: rawOffset, shapeProgressOverride: shapeProgressOverride) else { return }
        // All UIView APIs (bounds/transform/center) — they suppress implicit CALayer
        // animations, so these are immediate during a drag. The uniform scale narrows the
        // card AND its content+padding together (constant ratio = Flighty's "padding stays
        // fixed" look); the bounds height performs the vertical collapse clip.
        currentScale = g.scale
        // 底栏与卡片**同一 scale、底边锚定**缩放。此处对 barView 施加 transform：
        //  · 拖拽：placeSheet 每帧被调 → 底栏逐帧跟手（UIView transform 直接 set，无隐式动画）。
        //  · 吸附：placeSheet(at: target) 在 snap 的 UIViewPropertyAnimator 块内被调 → 底栏 transform
        //    被**同一个 animator** 插值 → 与卡片同曲线、同初速度、逐帧一致（frame-perfect）。
        // 不引入第二驱动源（playbook §5）——底栏就搭在卡片同一条 CA 时间线上。
        // 底边锚定公式：默认 anchor=(0.5,0.5)，先按 scale 缩、再下移 (1-s)·h/2 把底边钉回原处，
        // 等价于 SwiftUI 的 `.scaleEffect(s, anchor: .bottom)`，且不与 Auto Layout 冲突（transform 独立于 frame）。
        if let bar = barView {
            let s = g.scale
            let h = bar.bounds.height
            bar.transform = h > 0
                ? CGAffineTransform(translationX: 0, y: (1 - s) * h / 2).scaledBy(x: s, y: s)
                : CGAffineTransform(scaleX: s, y: s)
        }
        outerView.bounds = CGRect(origin: .zero, size: g.boundsSize)
        outerView.transform = CGAffineTransform(scaleX: g.scale, y: g.scale)
        outerView.center = g.center
        innerView.frame = outerView.bounds      // fills the card (pre-scale); rounds top corners
        backdropBlurView.frame = innerView.bounds   // 磨砂背板填满卡片可视窗口，随顶角裁切
        // 消隐渐变钉在 innerView（= 卡片可视窗口）底边：收起裁短时自动跟到可视底边、两态都可见。
        // 空态不铺（空态卡片是内容自适应的固定缩放浮卡，无需在底部消隐）。
        let fadeH = isListEmpty ? 0 : bottomFadeHeight
        bottomFadeView.frame = CGRect(x: 0, y: max(0, innerView.bounds.height - fadeH),
                                      width: innerView.bounds.width, height: fadeH)

        // ROOT-CAUSE PERFORMANCE INVARIANT: the SwiftUI content is laid out exactly ONCE,
        // at full size, and is NEVER resized during a drag/snap (resizing forced SwiftUI to
        // re-layout the whole list every frame — the jank). The host fills the card's full
        // (pre-scale) width and is pinned to its top; the visual narrowing comes from the
        // parent's scale transform, not from changing the host's size. Its bottom is clipped
        // by the card's bounds height.
        hostingView?.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: expandedHeight)
    }

    /// Applies the corner radii for a given progress (0 = expanded, 1 = collapsed).
    private func setProgress(_ progress: CGFloat, animated: Bool) {
        applyCornerMask(top: topRadius(progress), bottom: bottomRadius(progress), progress: progress)
    }

    /// Applies the corner radii. With the nested-layer hierarchy this is just two
    /// GPU-native `cornerRadius` scalars — no path, no per-frame mask rasterisation:
    ///   innerView → top corners, outerView → bottom corners.
    /// The bottom clip (the visible-window height) is the card's bounds height, set in
    /// `placeSheet`. `progress` is unused now but kept for call-site compatibility.
    /// Caller wraps in CATransaction.setDisableActions(true) to suppress implicit
    /// animation during interactive drag; during a snap the animator/displayLink drives it.
    private func applyCornerMask(top: CGFloat, bottom: CGFloat, progress: CGFloat) {
        // Divide by the current scale so the VISUAL radius (after the uniform card scale)
        // equals the intended value.
        let s = currentScale > 0 ? currentScale : 1
        innerView.layer.cornerRadius = top / s
        outerView.layer.cornerRadius = bottom / s
    }

    private func rubberBand(_ raw: CGFloat) -> CGFloat {
        let lo: CGFloat = 0, hi = collapsedOffset
        guard hi > lo else { return raw }
        if raw < lo {
            return lo
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

    /// How far the card's bottom edge floats above the screen bottom (the gap), driven
    /// continuously by position so it opens in lockstep with the side margins.
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

    /// Caches the SwiftUI content (blurred background + card shadows) into a single bitmap
    /// while the card is being scaled, so the per-frame scale transform just composites the
    /// cached texture on the GPU instead of re-rendering the scale-dependent blur/shadow
    /// filters each frame. Only enabled during sheet motion (never during a live list
    /// scroll, which would otherwise be frozen in the cached bitmap). Scale is set to the
    /// display scale and we only ever scale DOWN, so the cached bitmap stays crisp.
    private func setContentRasterized(_ on: Bool) {
        guard let layer = hostingView?.layer else { return }
        if on {
            layer.rasterizationScale = view.window?.screen.scale ?? UIScreen.main.scale
        }
        if layer.shouldRasterize != on { layer.shouldRasterize = on }
    }

    /// When user starts dragging, immediately take over from any running snap animation
    /// so the sheet can follow finger 1:1 without fighting background animators.
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

        // Cache the content so the snap animates a bitmap, not per-frame blur/shadow renders.
        setContentRasterized(true)

        let isCollapsing = target >= collapsedOffset - 1
        // Fast handle-down release should be one-way and non-bouncy.
        let isDirectHandleCollapse = (source == "sheetPanDirectCollapse")
        let isDirectExpand = (source == "sheetPanDirectExpand" || source == "listPanUp")
        if isDirectHandleCollapse || isDirectExpand {
            let targetProgress = clampedProgress(target)
            // Hand the snap to Core Animation (render-server / GPU driven), NOT a hand-rolled
            // CADisplayLink. The displayLink juddered even at 60Hz — where Tripsy is perfectly
            // smooth — proving the METHOD was wrong, not the refresh rate: a per-frame
            // main-thread position update (with step-clamping) can't match a GPU-interpolated
            // animation. The content is rasterised, so the animated transform just composites a
            // cached bitmap → smooth at any refresh rate.
            //
            // 「克制果冻」回弹：dampingRatio < 1 给一个受控的轻微过冲再落位。当年禁回弹（§5/§13）
            // 是为消除「多驱动竞争」的失控伪影（先上弹/中段跳变，§4）——那个根因已随单一 CA 通道 +
            // 内容固定尺寸 + 删 mask 重构消除。如今过冲由这条**唯一** animator 在 transform 上干净插值、
            // 且只经唯一漏斗 placeSheet，是设计效果而非伪影。几何上展开过冲把底缘推出屏幕下方、收起过冲
            // 让浮动间隙短暂变大，**都不漏 MapKit**（见 specs/home-sheet-snap-spring.md）。底栏搭同一
            // animator → 一起弹，免费同步。阻尼不对称：展开到顶给多一点「到位」精神气；收起贴底缘更收敛。
            let dampingRatio: CGFloat = isCollapsing ? 0.82 : 0.74
            let duration: TimeInterval = isCollapsing ? 0.46 : 0.52
            let anim = UIViewPropertyAnimator(duration: duration, dampingRatio: dampingRatio) { [weak self] in
                guard let self else { return }
                self.placeSheet(at: target)
                self.applyCornerMask(top: self.topRadius(targetProgress),
                                     bottom: self.bottomRadius(targetProgress),
                                     progress: targetProgress)
                self.setShapeProgress(targetProgress)
            }
            anim.addCompletion { [weak self] _ in
                guard let self else { return }
                guard generation == self.animationGeneration else { return }
                self.snappedOffset = target
                self.liveDelta = 0
                self.runningAnimator = nil
                self.setShapeProgress(targetProgress)
                self.setContentRasterized(false)   // settled — restore live rendering (scrolling)
                if let sv = self.listScrollView, self.delegateProxy?.lockedOffsetY != nil {
                    self.delegateProxy?.lockedOffsetY = nil
                    sv.isScrollEnabled = true
                }
            }
            runningAnimator = anim
            // 底栏缩放由本 animator 块内的 placeSheet(at: target) 同步插值（见 placeSheet）。
            anim.startAnimation()
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
        anim.addAnimations { [weak self] in
            guard let self else { return }
            // Single Core Animation channel: position (bounds/center/transform) AND corner
            // radius animate together on the same curve — no separate shape displayLink.
            self.placeSheet(at: target)
            self.applyCornerMask(top: self.topRadius(targetShapeProgress),
                                 bottom: self.bottomRadius(targetShapeProgress),
                                 progress: targetShapeProgress)
            self.setShapeProgress(targetShapeProgress)
        }
        anim.addCompletion { [weak self] _ in
            guard let self else { return }
            guard generation == self.animationGeneration else { return }
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
            self.setContentRasterized(false)   // settled — restore live rendering (scrolling)
            if let sv = self.listScrollView, self.delegateProxy?.lockedOffsetY != nil {
                self.delegateProxy?.lockedOffsetY = nil
                sv.isScrollEnabled = true
            }
        }

        runningAnimator = anim
        // 底栏缩放由本 animator 块内的 placeSheet(at: target) 同步插值（见 placeSheet）。
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
        liveDelta = 0
        let p = clampedProgress(visual)
        setShapeProgress(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSheet(at: visual, shapeProgressOverride: p)
        applyCornerMask(top: topRadius(p), bottom: bottomRadius(p), progress: p)
        CATransaction.commit()
        setContentRasterized(false)   // settled mid-position — restore live rendering
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
        // Rasterise the content while the sheet is actually being driven (delta != 0), so
        // the per-frame scale transform composites a cached bitmap instead of re-rendering
        // the blurred background + ~10 card shadows every frame (the real-device jank,
        // confirmed by A/B: fallback w/o scale is smooth, FX w/ scale is not). delta == 0
        // means Rule 2 (normal list scroll) or a no-op — must stay un-rasterised so the
        // live list scroll isn't frozen in a cached bitmap.
        setContentRasterized(delta != 0)
        liveDelta = delta
        let raw      = snappedOffset + delta
        let progress = clampedProgress(raw)
        setShapeProgress(progress)
        placeSheet(at: raw)
        // Disable CALayer implicit animations for immediate response
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCornerMask(top: topRadius(shapeProgressState), bottom: bottomRadius(shapeProgressState), progress: shapeProgressState)
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
        // STATE-DRIVEN 内容锁（根因修复"偶现内容区自由滚动"）：
        // 锁的真正不变量是——"只要 Sheet 不在完全展开态，内容就必须钉在顶部"（规则 1/3 的本质）。
        // 旧实现把锁绑在易失的每手势标志（.began 里设的 lockedOffsetY / activePanDriver）上，
        // 存在时序窗：delegate 被 SwiftUI 顶替那一帧、或 activePanDriver 在 .cancelled/.failed 未复位，
        // 都会让锁没设上 → 整段手势内容自由滚动（playbook §16 的偶现）。
        // 改为直接由 Sheet 位置状态判定，且用 delegate-无关的 contentOffset KVO 强制：
        // KVO 在 offset 任何变化时都触发，不受 delegate/标志位时序影响，确定性消除时序窗。
        contentOffsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self, weak sv] _, _ in
            guard let self, let sv else { return }
            // 完全展开（snappedOffset+liveDelta ≈ 0）→ 允许自由滚动（规则 2）；否则钉顶。
            guard (self.snappedOffset + self.liveDelta) > 0.5 else { return }
            let topInset = -sv.adjustedContentInset.top
            guard abs(sv.contentOffset.y - topInset) > 0.5 else { return }
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: topInset), animated: false)
        }
    }

    private func installProxy(on sv: UIScrollView) {
        let proxy = delegateProxy ?? FXDecelerationCanceller()
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
                // No sheet movement this gesture. If fully expanded (snappedOffset == 0)
                // it's a normal list touch — release the lock. But if snappedOffset > 0
                // the sheet is stranded mid-way (a new list gesture interrupted a running
                // collapse), and releasing the lock here would let content scroll on a
                // half-open sheet (violates Rule 3). Snap to the nearest extreme instead.
                // (Aligned with fallback CarryBottomSheet, playbook §17.)
                if snappedOffset > 0 && !isCollapsedState {
                    let target: CGFloat = snappedOffset >= collapsedOffset * 0.5 ? collapsedOffset : 0
                    if target == 0 { delegateProxy?.lockedOffsetY = nil }
                    lastGestureSource = "listPanInterruptedSettle"
                    commitSnap(to: target, velocity: 0, source: "listPanInterruptedSettle")
                } else {
                    delegateProxy?.lockedOffsetY = nil
                }
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
                        // Mid-way after partial list drag: snap to nearest extreme rather
                        // than settling here — a stranded intermediate position would
                        // release the scroll lock on a half-open sheet (same bug as above).
                        let target: CGFloat = currentPos >= collapsedOffset * 0.5 ? collapsedOffset : 0
                        if target == 0 { delegateProxy?.lockedOffsetY = nil }
                        lastGestureSource = "listPanMidwaySettle"
                        commitSnap(to: target, velocity: velocity, source: "listPanMidwaySettle")
                    }
                }
            }
            activePanDriver = .none

        default: break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension FXSheetViewController: UIGestureRecognizerDelegate {

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
        // 空态：Sheet 锁成固定缩放浮卡、禁止下拉 —— 不接收任何拖拽（capsule 把手在空态纯装饰）。
        if isListEmpty { return false }
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

// MARK: - FXBottomFadeView

/// 底部消隐渐变（透明 → Sheet 底色），盖在内容之上、钉卡片可视底边。layer 本身即 CAGradientLayer，
/// frame 随 placeSheet 设定（无 SwiftUI relayout、GPU 廉价）。UIView 的 frame 变更在动画块外不带隐式
/// 动画（跟手），在 snap animator 块内则被动画器插值（与卡片同步）。
private final class FXBottomFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    // 配置参数留存：CGColor 不随 light/dark trait 自适应（CAGradientLayer.colors 存的是解析死的 CGColor），
    // 故须在 trait 变化时用当前 trait 重新解析、重设——否则切换深色后渐变仍停在配置时那套颜色（白底渐变）。
    private var baseColor: UIColor = .clear
    private var peakOpacity: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FXBottomFadeView, _) in
            view.applyColors()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(baseColor: UIColor, peakOpacity: CGFloat) {
        self.baseColor = baseColor
        self.peakOpacity = peakOpacity
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        applyColors()
    }

    /// 用当前 traitCollection 解析动态色后重设 CGColor。configure 时与每次 light/dark 切换时都调用。
    private func applyColors() {
        let resolved = baseColor.resolvedColor(with: traitCollection)
        gradient.colors = [
            resolved.withAlphaComponent(0).cgColor,
            resolved.withAlphaComponent(0.92 * peakOpacity).cgColor,
            resolved.withAlphaComponent(peakOpacity).cgColor,
        ]
    }
}

// MARK: - FXPassthroughView

/// A UIView that returns nil from hitTest when no subview claims the touch,
/// allowing gestures (e.g. MapKit pinch/pan) on views behind it to pass through.
private final class FXPassthroughView: UIView {
    /// 底栏（搜索/Trip Book/+）的 hosting view。它的 frame 是一个**「不放行区」**：见下 hitTest。
    weak var barView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 🔒 底栏「不放行区」（**结构性防穿透，别在 SwiftUI 层补**，见 home-sheet-debug-playbook §33）：
        // 底栏是与行程卡片同级、叠在其上的 UIKit 兄弟视图。底栏内的 SwiftUI 命中测试只认领有内容/
        // contentShape 的区域 → 按钮间空隙/padding/玻璃边角等**透明区会放行** → 根视图继续下探撞到
        // 背后卡片 Button → 误开行程。**根治**：凡落在底栏 frame 内的点，一律由底栏认领（命中按钮→按钮；
        // 落空隙→底栏自身吸掉），**永不下传卡片**——与底栏 SwiftUI 内容是否透明无关，故底栏 UI 怎么改都不复发。
        // convert 用 UIView API（自动处理底栏的缩放 transform，见 placeSheet 对 barView 施加的 transform）。
        if let bar = barView, bar.window != nil, !bar.isHidden, bar.alpha > 0.01 {
            let pInBar = bar.convert(point, from: self)
            if bar.bounds.contains(pInBar) {
                return bar.hitTest(pInBar, with: event) ?? bar
            }
        }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - FXDecelerationCanceller

/// Intercepts UIScrollViewDelegate to cancel momentum scroll when the
/// sheet pan gesture takes over.
private final class FXDecelerationCanceller: NSObject, UIScrollViewDelegate {
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
