//
//  CoffeeSheetView.swift
//  Carry

import SwiftUI
import UIKit
import StoreKit

struct CoffeeSheetView: View {

    @StateObject private var coffeeStore = CoffeeStore()
    @State private var showCelebration = false
    @State private var hasPurchasedInSession = false
    @State private var showStoreKitNotReadyAlert = false
    @State private var storeKitDebugMessage = ""
    @State private var pendingMockProductID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {

                    // — Big emoji
                    Text("☕️")
                        .font(.system(size: 60))
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    VStack(spacing: 0) {
                        // — Title
                        Text(hasPurchasedInSession ? LocalizedStringKey("support.thanks.title") : LocalizedStringKey("support.sheet.heading"))
                            .font(.system(size: 36, weight: .semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)

                        // — Subtitle
                        Text(hasPurchasedInSession ? LocalizedStringKey("support.thanks.message") : LocalizedStringKey("support.sheet.subtitle"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(minHeight: 100, alignment: .top)
                    .padding(.bottom, 8)

                    // — Coffee cards
                    VStack(spacing: 12) {
                        coffeeCard(emoji: "🥤", nameKey: "support.drink.water",
                                   id: "com.lumastudio.carry.water",      fallback: "$0.99")
                        coffeeCard(emoji: "☕️", nameKey: "support.drink.americano",
                                   id: "com.lumastudio.carry.americano",  fallback: "$1.99")
                        coffeeCard(emoji: "🥛", nameKey: "support.drink.latte",
                                   id: "com.lumastudio.carry.latte",      fallback: "$2.99")
                        coffeeCard(emoji: "🫧", nameKey: "support.drink.cappuccino",
                                   id: "com.lumastudio.carry.cappuccino", fallback: "$3.99")
                        coffeeCard(emoji: "🍻", nameKey: "support.drink.beer",
                                   id: "com.lumastudio.carry.beer",       fallback: "$4.99")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 2)

                    // — Secondary actions
                    VStack(alignment: .leading, spacing: 6) {
                        Text("support.sheet.moreActions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .kerning(1.3)
                            .textCase(.uppercase)
                            .padding(.leading, 16)
                            .padding(.bottom, 2)

                        VStack(spacing: 0) {
                            secondaryButton(title: "Share with Friends", icon: "square.and.arrow.up") {
                                shareApp()
                            }
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 0.67)
                                .padding(.leading, 50)
                            secondaryButton(title: "support.sheet.rateApp", icon: "star") {
                                requestReview()
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
                        .padding(.top, 5)
                        .padding(.bottom, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    Text("support.sheet.footer")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)
                        .padding(.bottom, 26)
                }
            }
            .overlay {
                if showCelebration {
                    CoffeeParticleOverlay(isVisible: $showCelebration) { }
                }
            }
            .alert("StoreKit not ready", isPresented: $showStoreKitNotReadyAlert) {
#if DEBUG
                if let pendingMockProductID {
                    Button("Mock success") {
                        coffeeStore.debugMockPurchase(productID: pendingMockProductID)
                        self.pendingMockProductID = nil
                    }
                }
#endif
                Button("OK", role: .cancel) {
                    pendingMockProductID = nil
                }
            } message: {
                Text(storeKitDebugMessage)
            }
            .onChange(of: coffeeStore.lastPurchasedID) { _, id in
                guard id != nil else { return }
                hasPurchasedInSession = true
                showCelebration = true
            }
            .navigationTitle("settings.section.support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        hasPurchasedInSession = false
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
            Task { await attemptPurchase(productID: id) }
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

    private func attemptPurchase(productID: String) async {
        if !coffeeStore.hasProduct(productID) {
            await coffeeStore.fetchProducts()
        }
        if coffeeStore.hasProduct(productID) {
            await coffeeStore.buy(productID: productID)
        } else {
            pendingMockProductID = productID
            let loadedIDs = coffeeStore.products.map(\.id).sorted()
            let loadedSummary = loadedIDs.isEmpty
                ? "none"
                : loadedIDs.joined(separator: ", ")
            let err = coffeeStore.lastFetchErrorMessage ?? "none"
            storeKitDebugMessage =
                """
                Products are not loaded.
                expected=\(CoffeeStore.productIDs.count), loaded=\(coffeeStore.products.count)
                loadedIDs=\(loadedSummary)
                fetchError=\(err)
                """
            showStoreKitNotReadyAlert = true
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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

    private func requestReview() {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            SKStoreReviewController.requestReview(in: scene)
            return
        }

        // Fallback: open App Store review page if in-app prompt is unavailable.
        if let url = URL(string: "https://apps.apple.com/app/id0000000000?action=write-review") {
            UIApplication.shared.open(url)
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
