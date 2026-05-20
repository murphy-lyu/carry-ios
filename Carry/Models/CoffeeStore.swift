//
//  CoffeeStore.swift
//  Carry

import Combine
import StoreKit

@MainActor
final class CoffeeStore: ObservableObject {

    static let productIDs = [
        "com.lumastudio.carry.water",
        "com.lumastudio.carry.americano",
        "com.lumastudio.carry.latte",
        "com.lumastudio.carry.cappuccino",
        "com.lumastudio.carry.beer"
    ]

    @Published var products: [Product] = []
    @Published var isPurchasing = false
    @Published var lastPurchasedID: String?
    @Published var lastFetchErrorMessage: String?

    init() {
        Task { await fetchProducts() }
    }

    func fetchProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            lastFetchErrorMessage = nil
        } catch {
            lastFetchErrorMessage = error.localizedDescription
        }
    }

    func hasProduct(_ productID: String) -> Bool {
        products.contains { $0.id == productID }
    }

    func displayPrice(for productID: String, fallback: String) -> String {
        products.first { $0.id == productID }?.displayPrice ?? fallback
    }

    func buy(productID: String) async {
        guard let product = products.first(where: { $0.id == productID }) else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    lastPurchasedID = productID
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            // Purchase failed silently — StoreKit surfaces its own error UI
        }
    }

#if DEBUG
    func debugMockPurchase(productID: String) {
        lastPurchasedID = productID
    }
#endif
}
