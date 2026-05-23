//
//  CoffeeParticleView.swift
//  Carry

import SwiftUI

// MARK: - Particle data

private struct ParticleData: Identifiable {
    let id = UUID()
    let isEmoji: Bool
    let size: CGFloat
    let color: Color
    let normalizedX: CGFloat   // 0…1 across screen width
    let drift: CGFloat         // normalised horizontal drift
    let delay: Double
    let duration: Double
    let endRotation: Double
}

// MARK: - Single particle

private struct CoffeeParticle: View {

    let data: ParticleData
    let screenSize: CGSize

    @State private var offsetY: CGFloat = 0
    @State private var offsetX: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var rotation: Double = 0

    private var startX: CGFloat { data.normalizedX * screenSize.width }

    var body: some View {
        Group {
            if data.isEmoji {
                Text("☕️")
                    .font(.system(size: data.size))
            } else {
                Circle()
                    .fill(data.color)
                    .frame(width: data.size, height: data.size)
            }
        }
        .rotationEffect(.degrees(rotation))
        .opacity(opacity)
        .position(
            x: startX + offsetX,
            y: -30 + offsetY
        )
        .onAppear {
            withAnimation(.easeIn(duration: data.duration).delay(data.delay)) {
                offsetY = screenSize.height + 120
                offsetX = data.drift * screenSize.width
                rotation = data.endRotation
                opacity = 0.92
            }
            // Fade out over the last ~40% of the fall
            withAnimation(
                .easeIn(duration: data.duration * 0.40)
                .delay(data.delay + data.duration * 0.60)
            ) {
                opacity = 0
            }
        }
    }
}

// MARK: - Overlay

struct CoffeeParticleOverlay: View {

    @Binding var isVisible: Bool
    let onComplete: () -> Void

    @State private var particles: [ParticleData] = []

    private static let warmColors: [Color] = [
        Color(red: 111/255, green:  78/255, blue:  55/255),  // #6F4E37 espresso
        Color(red: 139/255, green:  99/255, blue:  64/255),  // #8B6340 dark roast
        Color(red: 196/255, green: 168/255, blue: 130/255),  // #C4A882 latte
        Color(red: 212/255, green: 165/255, blue: 116/255),  // #D4A574 caramel
        Color(red: 245/255, green: 222/255, blue: 179/255),  // #F5DEB3 wheat cream
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { p in
                    CoffeeParticle(data: p, screenSize: geo.size)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            particles = Self.makeParticles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    onComplete()
                }
            }
        }
    }

    private static func makeParticles() -> [ParticleData] {
        (0..<32).map { i in
            ParticleData(
                isEmoji: i % 4 == 0,
                size: CGFloat.random(in: 6...20),
                color: warmColors.randomElement()!,
                normalizedX: CGFloat.random(in: 0.04...0.96),
                drift: CGFloat.random(in: -0.08...0.08),
                delay: Double.random(in: 0...1.4),
                duration: Double.random(in: 1.0...2.1),
                endRotation: Double.random(in: -540...540)
            )
        }
    }
}

#Preview {
    @Previewable @State var visible = true
    CoffeeParticleOverlay(isVisible: $visible) { }
}
