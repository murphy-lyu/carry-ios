//
//  ViewModifiers.swift
//  Carry
//

import SwiftUI

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
