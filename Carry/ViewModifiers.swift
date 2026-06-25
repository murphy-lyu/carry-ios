//
//  ViewModifiers.swift
//  Carry
//

import SwiftUI
import UIKit

/// 放进系统工具栏（`ToolbarItem`）的 sheet 关闭按钮。
/// iOS 26+ 用原生 `Button(role: .close)`——系统提供单层 Liquid Glass 圆形 X
/// + 无障碍标签，不在工具栏自带玻璃之上再叠一层；iOS 17–25 工具栏不自动加玻璃，
/// 回退为裸 `xmark` + 显式无障碍标签。
/// 注意：仅用于工具栏；自定义头部（非 toolbar）的关闭按钮用 `glassCircleButton()`。
/// 颜色：按按钮颜色规范 Tier 3（chrome 工具图标）走中性 `.secondary` 灰——显式盖掉
/// sheet 的 `.tint(CarryAccent)`，让关闭 X 与设置齿轮、Apple 原生关闭按钮一致（不染强调色）。
struct SheetCloseButton: View {
    var action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .tint(Color(.secondaryLabel))
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("common.close"))
        }
    }
}

struct CarryAtmosphereBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.08, blue: 0.10),
                        Color(red: 0.11, green: 0.11, blue: 0.13),
                        Color(red: 0.14, green: 0.14, blue: 0.16)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(Color(red: 0.28, green: 0.31, blue: 0.35).opacity(0.18))
                    .frame(width: 280, height: 280)
                    .blur(radius: 32)
                    .offset(x: -130, y: -250)

                Circle()
                    .fill(Color(red: 0.20, green: 0.27, blue: 0.35).opacity(0.14))
                    .frame(width: 220, height: 220)
                    .blur(radius: 34)
                    .offset(x: 150, y: 260)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.97, blue: 0.95),
                        Color(red: 0.96, green: 0.95, blue: 0.92),
                        Color(UIColor.systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(Color(red: 0.95, green: 0.92, blue: 0.84).opacity(0.28))
                    .frame(width: 280, height: 280)
                    .blur(radius: 26)
                    .offset(x: -120, y: -240)

                Circle()
                    .fill(Color(red: 0.83, green: 0.90, blue: 0.96).opacity(0.22))
                    .frame(width: 220, height: 220)
                    .blur(radius: 28)
                    .offset(x: 160, y: 260)
            }
        }
        .ignoresSafeArea()
    }
}

struct CarrySubtleBackground: View {
    /// 与背景渐变**底端**同色（明暗自适应，动态 UIColor）。供悬浮在背景上的底部条做"内容淡出到背景"
    /// 的渐隐、避免底部色带接缝（如 OptimizeRouteView 钉底 CTA）；也供 FX Sheet 卡片做不透明兜底背景
    /// （`CarryBottomSheetFX` innerView，吸附过冲时卡片底部不漏出后面的 MapKit）。
    static let baseUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)   // 暗：渐变底端
            : UIColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1)   // 浅：渐变底端
    }
    static let baseColor = Color(baseUIColor)

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.05, blue: 0.06),
                        Color(red: 0.08, green: 0.08, blue: 0.09)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(Color(red: 0.32, green: 0.33, blue: 0.36).opacity(0.08))
                    .frame(width: 180, height: 180)
                    .blur(radius: 22)
                    .offset(x: -110, y: -180)

                Circle()
                    .fill(Color(red: 0.18, green: 0.25, blue: 0.32).opacity(0.07))
                    .frame(width: 160, height: 160)
                    .blur(radius: 24)
                    .offset(x: 140, y: 220)
            } else {
                LinearGradient(
                    colors: [
                        Color(UIColor.systemBackground),
                        Color(red: 0.98, green: 0.98, blue: 0.97)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(Color(red: 0.95, green: 0.92, blue: 0.84).opacity(0.10))
                    .frame(width: 180, height: 180)
                    .blur(radius: 18)
                    .offset(x: -110, y: -180)

                Circle()
                    .fill(Color(red: 0.83, green: 0.90, blue: 0.96).opacity(0.08))
                    .frame(width: 160, height: 160)
                    .blur(radius: 20)
                    .offset(x: 140, y: 220)
            }
        }
        .ignoresSafeArea()
    }
}

struct CarrySurfaceCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    // 暗：卡填充比近黑背景明显亮 → 靠填充对比分界。
                    // 浅：背景已近白、卡片无法「更亮」，改用 iOS 标准 elevation —— 纯白不透明填充 + 柔和投影抬升。
                    .fill(dark ? Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.84)
                               : Color(UIColor.systemBackground))
                    .overlay(   // 0.5px 描边 crisp 边缘（投影最弱的上沿也有明确分界）
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
                                          lineWidth: 0.5)
                    )
                    // 浅色柔和投影；暗色背景吃投影 → 不投，靠填充对比即可。
                    .shadow(color: dark ? .clear : Color.black.opacity(0.08),
                            radius: dark ? 0 : 16, x: 0, y: dark ? 0 : 6)
            )
    }
}

struct CarryHeroCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(heroFill)
        )
    }

    private var heroFill: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.14, blue: 0.15),
                    Color(red: 0.17, green: 0.17, blue: 0.18),
                    Color(red: 0.19, green: 0.19, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.96, blue: 0.93),
                    Color(UIColor.secondarySystemBackground).opacity(0.82),
                    Color(UIColor.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

extension PresentationDetent {
    /// 「按内容自算高度」的 sheet detent，**钳在屏幕高 0.90 以下**（单一真源）。
    /// 根因（斜向滚动 bug）：内容超屏时 `.height(自算值)` ≈ 满屏 → 触发 iOS 26 把弹层「脱离成带两侧边距、
    /// 可 2D 拖动的浮动卡片」。钳到屏高以下后弹层永远是正常 sheet，超长内容改内部竖直滚动。
    /// **任何按内容自算高度的 sheet 一律走此入口，禁止裸用 `.height(动态值)`。** 固定小常量高度不在此限。
    static func cappedContentHeight(_ ideal: CGFloat) -> PresentationDetent {
        .height(min(ideal, UIScreen.main.bounds.height * 0.90))
    }
}

extension View {
    // MARK: Carry Elevation System（canonical · 单一真源 · design-system.md §Elevation）

    /// 【canonical】标准卡片：浮在 `carryCanvas` 上的信息卡——白底 / 深色提亮填充 + 0.5px 描边 +
    /// 阴影 `黑0.08 / r16 / y6`（浅）· 深色不投影。**全 App 卡片唯一标准**，新代码一律用它。
    func carryCard(cornerRadius: CGFloat = CarryRadius.card) -> some View {
        modifier(CarrySurfaceCardBackground(cornerRadius: cornerRadius))
    }

    /// 【canonical】Hero 卡：主角卡（首页行程卡）渐变填充，无描边/阴影；默认 28 圆角。
    func carryHeroCard(cornerRadius: CGFloat = CarryRadius.hero) -> some View {
        modifier(CarryHeroCardBackground(cornerRadius: cornerRadius))
    }

    /// 旧名 · 渐废（等各屏拉齐到 `carryCard` 后移除）。现委托到 canonical，保证单一实现。
    func carrySurfaceCardBackground(cornerRadius: CGFloat = CarryRadius.card) -> some View {
        carryCard(cornerRadius: cornerRadius)
    }

    /// 旧名 · 渐废（用 `carryHeroCard`）。现委托到 canonical。
    func carryHeroCardBackground(cornerRadius: CGFloat = CarryRadius.hero) -> some View {
        carryHeroCard(cornerRadius: cornerRadius)
    }
}

struct SolidPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(duration: 0.2, bounce: 0.1), value: configuration.isPressed)
    }
}

/// 全 App「空状态」主操作的统一胶囊样式：contained、`primary` 渐变、continuous 16 圆角、
/// `systemBackground` 文字、轻阴影、按压缩放（与 PressableScaleButtonStyle 同一 spring）。
/// 首页空态 / 行程空态共用，杜绝两份内联样式漂移；新增空状态直接套用本样式。
/// 用法：`Button { … } label: { HStack(spacing: 8) { Image(systemName:).font(.system(size: 14, weight: .semibold)); Text("…") } }.buttonStyle(CarryEmptyStatePrimaryButtonStyle())`
/// 文字默认继承下方 rounded subheadline；图标如需固定尺寸，在 label 内对 Image 单独 `.font(...)`。
struct CarryEmptyStatePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration)
    }

    private struct Pill: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color(UIColor.systemBackground))
                .padding(.horizontal, 28)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.90), Color.primary.opacity(0.76)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 10, x: 0, y: 5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .brightness(configuration.isPressed ? -0.02 : 0)
                .opacity(configuration.isPressed ? 0.95 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// 末项拉伸填满当前行剩余宽度（用于 chip 输入框：让 TextField 成大命中区、填满行尾）。
    /// 默认 false → 行为与原 FlowLayout 完全一致（既有调用方零影响）。
    var stretchLastSubview: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                height += rowHeight + lineSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lastIndex = subviews.count - 1
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            if stretchLastSubview && index == lastIndex {
                let placeWidth = max(size.width, bounds.maxX - x)
                subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: placeWidth, height: size.height))
                x += placeWidth + spacing
            } else {
                subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    /// Applies Liquid Glass on iOS 26+; falls back to a plain circle background on older systems.
    @ViewBuilder
    func glassCircleButton() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(Circle().fill(Color(.secondarySystemFill)))
        }
    }
}

// MARK: - CarrySearchField

/// 全 App 统一的搜索框，单一形态。规格收成唯一真源：12pt 圆角 / 44pt 高 / body 字号 /
/// 放大镜 + 清除按钮 + 无障碍——杜绝各页各写一份导致圆角等规格漂移（曾出现首页 24pt、
/// 其余 12pt 不一致）。
///
/// 表面采用 design-system「描边主导」输入容器规范：半透明系统底 `systemBackground.opacity(0.84)`
/// + 细描边。描边让它在**任何底色**上都立得住——灰底是白底+描边、白底是描边定界、暗色是深底+描边，
/// 故不需要按上下文分多种填充（描边是通吃的关键，纯实心填充才会有「同灰隐形」问题）。
struct CarrySearchField<Trailing: View>: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    var focus: FocusState<Bool>.Binding
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            // 输入法安全字段（替代原生 TextField）：修复微信输入法选词上屏后不触发搜索（见 IMESafeTextField）。
            // 占位符由 SwiftUI overlay 渲染（空文本时显示），保持 placeholder 的 LocalizedStringKey 形参不变。
            IMESafeTextField(
                text: $text,
                returnKeyType: .search,
                isFocused: Binding(get: { focus.wrappedValue }, set: { focus.wrappedValue = $0 })
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.clear"))
                .transition(.opacity)
            }

            trailing()
        }
        .animation(.spring(duration: 0.2, bounce: 0.1), value: text.isEmpty)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground).opacity(0.84))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension CarrySearchField where Trailing == EmptyView {
    init(
        text: Binding<String>,
        placeholder: LocalizedStringKey,
        focus: FocusState<Bool>.Binding
    ) {
        self.init(
            text: text,
            placeholder: placeholder,
            focus: focus,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - IMESafeTextField（输入法安全的文本输入）
//
// 为什么存在：SwiftUI 原生 `TextField` 在**第三方中文输入法（微信输入法等）选词上屏**那一刻，
// 不可靠地把新值推进 binding——它依赖 UIKit 的 editing-changed 事件，而这些输入法的候选词「提交」路径
// 常不触发它（系统拼音输入法会触发，故无此问题）。后果：「打字即检索/过滤」类字段在选词后**不触发**
// 搜索，要再补一个字符才恢复。直接拥有一个 `UITextField`、监听 UIKit 层可靠的 `.editingChanged`
// （选词上屏会触发），即可从根上绕开该缺陷。
//
// 仅用于「文字变化要实时驱动副作用（搜索/补全/过滤）」的字段；纯表单字段不需要（值在 Save/失焦时读、
// binding 那时已追平，不受影响）。占位符由外层 SwiftUI 渲染（避免 LocalizedStringKey→String 解析）。
struct IMESafeTextField: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var returnKeyType: UIReturnKeyType = .default
    /// 可选：与 SwiftUI `@FocusState` / `Bool` 焦点双向桥接（UIViewRepresentable 无法直接用 `.focused`）。
    var isFocused: Binding<Bool>? = nil
    var onSubmit: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.borderStyle = .none
        tf.font = font
        tf.adjustsFontForContentSizeCategory = true
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.returnKeyType = returnKeyType
        tf.textColor = .label
        tf.tintColor = .label                 // 对齐原 .tint(.primary)
        tf.clearButtonMode = .never            // 清除按钮由外层 SwiftUI 提供
        // 在 HStack/FlowLayout 里可被压缩、由外层 frame 决定宽度，不靠内在宽度抢空间。
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.parent = self      // 始终持有最新 binding，避免 Coordinator 用到陈旧闭包
        if tf.text != text {
            if text.isEmpty {
                // 清空总是安全的，并主动结束可能存在的预编辑态（× 清除 / 选中后清空走这里）。
                tf.text = ""
                tf.unmarkText()
            } else if tf.markedTextRange == nil {
                // 关键：组字（marked text）期间绝不反写 text，否则会清掉输入法预编辑态。
                tf.text = text
            }
        }
        if let isFocused {
            if isFocused.wrappedValue, !tf.isFirstResponder {
                DispatchQueue.main.async { tf.becomeFirstResponder() }
            } else if !isFocused.wrappedValue, tf.isFirstResponder {
                DispatchQueue.main.async { tf.resignFirstResponder() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IMESafeTextField
        init(_ parent: IMESafeTextField) { self.parent = parent }

        // UIKit 层的文字变化（含输入法选词上屏）都会触发——这正是 SwiftUI binding 漏掉的那一下。
        @objc func editingChanged(_ tf: UITextField) {
            let new = tf.text ?? ""
            if parent.text != new { parent.text = new }
        }
        func textFieldDidBeginEditing(_ tf: UITextField) {
            guard let f = parent.isFocused, !f.wrappedValue else { return }
            DispatchQueue.main.async { f.wrappedValue = true }
        }
        func textFieldDidEndEditing(_ tf: UITextField) {
            guard let f = parent.isFocused, f.wrappedValue else { return }
            DispatchQueue.main.async { f.wrappedValue = false }
        }
        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            parent.onSubmit?()
            tf.resignFirstResponder()
            return true
        }
    }
}

// MARK: - BottomBarScrim

/// 底部浮动栏 / CTA 的「渐变垫底」——全 App 统一：滚动内容在栏的上沿**柔和淡出**（而非硬切），
/// 栏本身坐在实心底色上、不透出列表内容。用作底部 `safeAreaInset(.bottom)` 内容的修饰器，单一真源
/// （替代各页各写一段 LinearGradient）。
///
/// 实现：内容上方留出 `fadeHeight` 淡入带；背景 = 顶部 `fadeHeight` 高的「透明→实心」渐变条 + 其下
/// 实心 `color` 填满。与按钮高度无关（定高淡出带 + 实心兜底），故各页观感一致、不需按高度调比例。
///
/// - color: 淡出到的底色 = **该页背景色**（一级页 `systemBackground`；二级弹层用 chrome 同色系），
///   故渐变底端与页面无缝。
/// - fadeHeight: 上沿淡出带高度（亦即按钮上方留白），默认 22。
struct BottomBarScrim: ViewModifier {
    let color: Color
    var fadeHeight: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .padding(.top, fadeHeight)
            .background(
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [color.opacity(0), color],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: fadeHeight)
                    color
                }
                // 实心兜底延伸到屏幕底边，盖住 home indicator 条，避免底缘露出页面接缝。
                .ignoresSafeArea(edges: .bottom)
            )
    }
}

extension View {
    /// 见 `BottomBarScrim`。把底部栏的实心背景替换为「上沿渐变淡出 + 实心兜底」。
    func bottomBarScrim(_ color: Color, fadeHeight: CGFloat = 22) -> some View {
        modifier(BottomBarScrim(color: color, fadeHeight: fadeHeight))
    }
}

// MARK: - BottomContentFade

extension View {
    /// **浮动元素**（glass 胶囊栏 / 圆角浮卡）下的内容消隐：在底部叠一段「透明 → 页面底色」渐变，
    /// 让滚动内容向背景**柔和消隐**（浮动元素仍浮于其上、不在其后垫整块实心）。
    /// 区别于 `BottomBarScrim`（那是**整宽实心底栏**的垫底）；这里用于不该被实心遮挡的浮动控件。
    /// 纯渐变 overlay、`allowsHitTesting(false)`、无 mask/blur → 不触发离屏渲染、不挡点击、开销极低。
    /// - color: 消隐到的底色 = 该页背景色（与背景无缝）。
    /// - height: 消隐带高度。
    /// - peakOpacity: 最底端（最实处）的不透明度上限。默认 1.0 = 原行为（底端全实）；
    ///   调小让整条消隐带更通透（浮动栏后内容透出更多）。渐变形状不变，仅整体按此缩放。
    func bottomContentFade(_ color: Color, height: CGFloat = 120, peakOpacity: Double = 1) -> some View {
        overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: color.opacity(0),                  location: 0),
                    .init(color: color.opacity(0.92 * peakOpacity), location: 0.5),
                    .init(color: color.opacity(peakOpacity),        location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - BottomBarFade

/// 浮动栏（glass 胶囊切换器 / 圆角浮卡）的**通透**垫底——与 `bottomContentFade` 同源思路，
/// 但作为底部 `safeAreaInset` 内容的**背景**：上沿透明 → 底端半透（`peakOpacity < 1`），
/// 让滚动内容在栏后柔和消隐却**仍透出背景/卡片**，而非被整块实心遮死。
///
/// 与 `BottomBarScrim` 的取舍（同一底栏槽位、两种垫底）：
/// - `bottomBarScrim`（实心兜底）：用于**主操作 CTA**（保存 / 采用 / Continue），按钮需要实底背书、对比度与点击区清晰。
/// - `bottomBarFade`（通透消隐）：用于**浮动切换/导航胶囊**——栏本身是半透 glass，下方不应再垫整块实心，
///   否则在较高的栏区里实心会把「可视内容区」视觉上压短。
///
/// 结构与 `BottomBarScrim` 完全一致（`.padding(.top, fadeHeight)` + 背景 `.ignoresSafeArea(.bottom)`），
/// 故布局/安全区行为不变；唯一差别是填充由「实心」改为「透明→半透」渐变。
///
/// - color: 消隐到的底色 = 页面背景**底端**色（用 `CarrySubtleBackground.baseColor` 与背景无缝）。
/// - fadeHeight: 顶部渐变淡入带高度（亦即栏上方留白）。
/// - peakOpacity: 底端最实处不透明度上限（< 1 即整体通透；默认 0.92——胶囊周围内容柔和消隐却仍轻透，
///   保持可视区不被压短。胶囊**正后方**的清晰文字由磨砂玻璃材质模糊掉，不靠这条蒙层去盖）。
struct BottomBarFade: ViewModifier {
    let color: Color
    var fadeHeight: CGFloat = 28
    var peakOpacity: Double = 0.92

    func body(content: Content) -> some View {
        content
            .padding(.top, fadeHeight)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0),                  location: 0),
                        .init(color: color.opacity(0.92 * peakOpacity), location: 0.5),
                        .init(color: color.opacity(peakOpacity),        location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // 与 BottomBarScrim 同：延伸到屏幕底边盖住 home indicator 条，避免底缘接缝。
                .ignoresSafeArea(edges: .bottom)
            )
    }
}

extension View {
    /// 见 `BottomBarFade`。浮动栏的通透垫底（替代 `bottomBarScrim` 的实心兜底）。
    func bottomBarFade(_ color: Color, fadeHeight: CGFloat = 28, peakOpacity: Double = 0.92) -> some View {
        modifier(BottomBarFade(color: color, fadeHeight: fadeHeight, peakOpacity: peakOpacity))
    }
}

/// 底栏悬浮玻璃背景（首页底栏 + 行程规划底部「行程/打包」切换器共用，单一真源）：
/// iOS 26 用原生 Liquid Glass；iOS 17–25 回退为 ultraThinMaterial 自定义玻璃面（通透发白、不发灰）。
/// 用 `.ultraThinMaterial`（比 regularMaterial 更通透）+ 叠白（亮 0.20 / 暗 0.02）往白里提 + 白描边，
/// 故「通透而不脏」；切勿改回 regularMaterial + 黑色叠层（会在亮底上发灰显脏）。
struct BottomBarGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.02 : 0.20)))
                        .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.34), lineWidth: 1))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.13), radius: 20, x: 0, y: 7)
                )
                .clipShape(shape)
        }
    }
}
