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
            LinearGradient(
                colors: [
                    Color(UIColor.systemBackground),
                    Color.accentColor.opacity(0.08),
                    Color(UIColor.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
                .ignoresSafeArea()

            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 28)
                .offset(x: -36, y: -72)

            VStack(spacing: 14) {
                Image("LaunchIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Carry")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
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
