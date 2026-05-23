//
//  ViewModifiers.swift
//  Carry
//

import SwiftUI

struct CarryAtmosphereBackground: View {
    var body: some View {
        ZStack {
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
        .ignoresSafeArea()
    }
}

struct CarrySubtleBackground: View {
    var body: some View {
        ZStack {
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
        .ignoresSafeArea()
    }
}

struct CarrySurfaceCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(UIColor.systemBackground).opacity(0.50))
            )
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
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.96, blue: 0.93),
                            Color(UIColor.secondarySystemBackground).opacity(0.82),
                            Color(UIColor.systemBackground)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
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
