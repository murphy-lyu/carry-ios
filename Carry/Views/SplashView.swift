//
//  SplashView.swift
//  Carry
//

import SwiftUI

struct SplashView: View {

    @State private var showSplash = true
    @State private var splashOpacity: Double = 1
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            ContentView()
                .opacity(contentOpacity)

            if showSplash {
                splashContent
                    .opacity(splashOpacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { scheduleTransition() }
    }

    // MARK: Splash content

    private var splashContent: some View {
        ZStack {
            CarryAtmosphereBackground()

            VStack(spacing: 14) {
                Image("LaunchIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)

                VStack(spacing: 6) {
                    Text("Carry")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("Everything ready. Let's go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Animation

    private func scheduleTransition() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            withAnimation(.easeInOut(duration: 0.26)) {
                contentOpacity = 1
                splashOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                showSplash = false
            }
        }
    }
}

#Preview {
    SplashView()
}

