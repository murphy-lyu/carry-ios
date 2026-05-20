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
        "com.lumastudio.carry.cappuccino"
    ]

    @Published var products: [Product] = []
    @Published var isPurchasing = false
    @Published var lastPurchasedID: String?

    init() {
        Task { await fetchProducts() }
    }

    func fetchProducts() async {
        guard let loaded = try? await Product.products(for: Self.productIDs) else { return }
        products = loaded.sorted { $0.price < $1.price }
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
}
