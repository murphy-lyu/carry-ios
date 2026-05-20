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
                    Text("support.sheet.title")
                        .font(.title2.bold())
                        .padding(.bottom, 10)

                    // — Subtitle
                    Text("support.sheet.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)

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

                    // — Secondary actions
                    VStack(spacing: 10) {
                        secondaryButton(title: "settings.feedback", icon: "envelope") {
                            openFeedbackMail()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // — Footer
                    Text("support.sheet.footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
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
                    .frame(width: 32, alignment: .center)
                Text(nameKey)
                    .font(.body.bold())
                    .foregroundColor(.primary)
                Spacer()
                if coffeeStore.isPurchasing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text(coffeeStore.displayPrice(for: id, fallback: fallback))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(coffeeStore.isPurchasing)
    }

    private func secondaryButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
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
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
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
}

#Preview {
    CoffeeSheetView()
}
