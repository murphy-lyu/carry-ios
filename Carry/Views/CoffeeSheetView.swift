//
//  CoffeeSheetView.swift
//  Carry

import SwiftUI
import UIKit

struct CoffeeSheetView: View {

    @StateObject private var coffeeStore = CoffeeStore()
    @State private var showCelebration = false
    @State private var showThankYou = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {

                    // — Big emoji
                    Text("☕️")
                        .font(.system(size: 60))
                        .padding(.top, 20)
                        .padding(.bottom, 16)

                    // — Title
                    Text("support.sheet.heading")
                        .font(.system(size: 36, weight: .semibold))
                        .padding(.bottom, 8)

                    // — Subtitle
                    Text("support.sheet.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 22)

                    // — Coffee cards
                    VStack(spacing: 12) {
                        coffeeCard(emoji: "💧", nameKey: "support.drink.water",
                                   id: "com.lumastudio.carry.water",      fallback: "$0.99")
                        coffeeCard(emoji: "☕️", nameKey: "support.drink.americano",
                                   id: "com.lumastudio.carry.americano",  fallback: "$1.99")
                        coffeeCard(emoji: "🥛", nameKey: "support.drink.latte",
                                   id: "com.lumastudio.carry.latte",      fallback: "$2.99")
                        coffeeCard(emoji: "🫧", nameKey: "support.drink.cappuccino",
                                   id: "com.lumastudio.carry.cappuccino", fallback: "$4.99")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 2)

                    // — Secondary actions
                    VStack(alignment: .leading, spacing: 10) {
                        Text("support.sheet.moreActions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .kerning(1.3)
                            .textCase(.uppercase)
                            .padding(.leading, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)

                        VStack(spacing: 0) {
                            secondaryButton(title: "Share with Friends", icon: "square.and.arrow.up") {
                                shareApp()
                            }
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 0.67)
                                .padding(.leading, 50)
                            secondaryButton(title: "settings.feedback", icon: "envelope") {
                                openFeedbackMail()
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                    Text("support.sheet.footer")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 32)
                }
            }
            .overlay {
                if showCelebration {
                    CoffeeParticleOverlay(isVisible: $showCelebration) {
                        showThankYou = true
                    }
                }
            }
            .alert(Text("support.thanks.title"), isPresented: $showThankYou) {
                Button("support.thanks.button") { }
            } message: {
                Text("support.thanks.message")
            }
            .onChange(of: coffeeStore.lastPurchasedID) { _, id in
                guard id != nil else { return }
                showCelebration = true
            }
            .navigationTitle("settings.section.support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private func coffeeCard(emoji: String, nameKey: LocalizedStringKey,
                            id: String, fallback: String) -> some View {
        Button {
            Task { await coffeeStore.buy(productID: id) }
        } label: {
            HStack(spacing: 12) {
                Text(emoji)
                    .font(.system(size: 24))
                    .frame(width: 28, alignment: .center)
                Text(nameKey)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if coffeeStore.isPurchasing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text(coffeeStore.displayPrice(for: id, fallback: fallback))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(coffeeStore.isPurchasing)
    }

    private func secondaryButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    private func openFeedbackMail() {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        let device = UIDevice.current.model
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"

        let to = "murphy.lyu@icloud.com"
        let subject = "Carry Feedback"
        let body = """


        ---
        Carry \(version) (\(build))
        \(device) · \(system)
        """

        var components = URLComponents(string: "mailto:\(to)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components?.url {
            UIApplication.shared.open(url)
        }
    }

    private func shareApp() {
        let url = URL(string: "https://apps.apple.com/app/carry")!
        let activityVC = UIActivityViewController(
            activityItems: ["Check out Carry – a minimal packing list app!", url],
            applicationActivities: nil
        )
        if let presenter = topMostViewController() {
            presenter.present(activityVC, animated: true)
        }
    }

    private func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

#Preview {
    CoffeeSheetView()
}
