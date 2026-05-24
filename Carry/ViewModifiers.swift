//
//  ViewModifiers.swift
//  Carry
//

import SwiftUI

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
