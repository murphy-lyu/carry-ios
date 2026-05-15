//
//  SplashView.swift
//  Carry
//

import SwiftUI

struct SplashView: View {

    @State private var isActive = false
    @State private var scale: CGFloat = 0.82
    @State private var opacity: Double = 0

    var body: some View {
        if isActive {
            ContentView()
        } else {
            splashContent
                .onAppear { animateIn() }
        }
    }

    // MARK: Splash content

    private var splashContent: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image("LaunchIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)

                Text("Carry")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
    }

    // MARK: Animation

    private func animateIn() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
            scale = 1.0
            opacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            animateOut()
        }
    }

    private func animateOut() {
        withAnimation(.easeIn(duration: 0.25)) {
            opacity = 0
            scale = 1.08
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isActive = true
        }
    }
}

#Preview {
    SplashView()
}
