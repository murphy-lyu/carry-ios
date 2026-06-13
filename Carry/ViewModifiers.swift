//
//  ViewModifiers.swift
//  Carry
//

import SwiftUI

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
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.84) : Color(UIColor.systemBackground).opacity(0.50))
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

extension View {
    func carrySurfaceCardBackground(cornerRadius: CGFloat = 24) -> some View {
        modifier(CarrySurfaceCardBackground(cornerRadius: cornerRadius))
    }

    func carryPageBackground() -> some View {
        background(CarryAtmosphereBackground())
    }

    func carrySubtlePageBackground() -> some View {
        background(CarrySubtleBackground())
    }

    func carryHeroCardBackground(cornerRadius: CGFloat = 28) -> some View {
        modifier(CarryHeroCardBackground(cornerRadius: cornerRadius))
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
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
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

// MARK: - CarryConfirmationDialog

/// App-styled confirmation dialog — replaces system .alert where visual consistency matters.
/// Shows a dimmed overlay with a card matching the Settings/card design language.
struct CarryConfirmationDialog: View {
    let title: LocalizedStringKey
    let message: String
    let confirmLabel: LocalizedStringKey
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 22) {
                VStack(spacing: 7) {
                    Text(title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 9) {
                    Button(action: onConfirm) {
                        Text(confirmLabel)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.label))
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color(UIColor.secondarySystemGroupedBackground)
                          : Color(UIColor.systemBackground))
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.48 : 0.14),
                        radius: 28, y: 10
                    )
            )
            .padding(.horizontal, 28)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
    }
}
