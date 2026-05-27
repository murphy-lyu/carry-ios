//
//  CoffeeStore.swift
//  Carry

import Combine
import StoreKit

@MainActor
final class CoffeeStore: ObservableObject {

    static let productIDs = [
        "com.murphy.carry.water",
        "com.murphy.carry.americano",
        "com.murphy.carry.latte",
        "com.murphy.carry.cappuccino",
        "com.murphy.carry.beer"
    ]

    @Published var products: [Product] = []
    @Published var isPurchasing = false
    @Published var lastPurchasedID: String?
    @Published var lastFetchErrorMessage: String?
    @Published var supportCount: Int = 0
    private let supportCountKey = "support_count"
    private let defaults = UserDefaults.standard

    init() {
        supportCount = defaults.integer(forKey: supportCountKey)
        Task { await fetchProducts() }
    }

    func fetchProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            lastFetchErrorMessage = nil
        } catch {
            lastFetchErrorMessage = error.localizedDescription
            CarryLogger.shared.log(.coffeeProductsFetchFailed,
                context: "error=\(error.localizedDescription)")
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
                    supportCount += 1
                    defaults.set(supportCount, forKey: supportCountKey)
                    CarryLogger.shared.log(.coffeePurchased,
                        context: "product=\(productID) totalCount=\(supportCount)")
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            CarryLogger.shared.log(.coffeePurchaseFailed,
                context: "product=\(productID) error=\(error.localizedDescription)")
        }
    }

#if DEBUG
    func debugMockPurchase(productID: String) {
        lastPurchasedID = productID
        supportCount += 1
        defaults.set(supportCount, forKey: supportCountKey)
    }

    func debugResetSupportCount() {
        supportCount = 0
        defaults.set(0, forKey: supportCountKey)
        lastPurchasedID = nil
    }
#endif
}
