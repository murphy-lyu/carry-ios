//
//  CoffeeStore.swift
//  Carry

import Combine
import StoreKit

@MainActor
final class CoffeeStore: ObservableObject {

    static let productIDs = [
        "com.murphy.carry.juice",
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
    private var transactionListenerTask: Task<Void, Never>?

    init() {
        supportCount = defaults.integer(forKey: supportCountKey)
        // 唯一确权入口：不仅接收 buy() 直接发起的购买，也覆盖购买过程中 App 被系统中断、
        // Face ID / Ask to Buy 延迟导致验证结果在 buy() 的 Task 结束后才到达等场景
        // （StoreKit 2 官方推荐做法）。buy() 本身不再直接记账，避免同一笔交易被计两次。
        transactionListenerTask = Task { [weak self] in await self?.observeTransactionUpdates() }
        Task { await fetchProducts() }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            await handle(result)
        }
    }

    /// 统一处理入口：`.verified` 才记账+计数；`.unverified` 不记账，但仍要 `finish()`——
    /// 否则交易会一直卡在队列里反复投递（原实现两者都不处理，静默丢弃已付费但未验证的交易）。
    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard Self.productIDs.contains(transaction.productID) else {
                await transaction.finish()
                return
            }
            lastPurchasedID = transaction.productID
            supportCount += 1
            defaults.set(supportCount, forKey: supportCountKey)
            CarryLogger.shared.log(.coffeePurchased,
                context: "product=\(transaction.productID) totalCount=\(supportCount)")
            await transaction.finish()
        case .unverified(let transaction, let error):
            CarryLogger.shared.log(.coffeePurchaseFailed,
                context: "product=\(transaction.productID) unverified error=\(error.localizedDescription)")
            await transaction.finish()
        }
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
            // 记账/计数统一交给 observeTransactionUpdates()（唯一确权入口）：`Transaction.updates`
            // 也会收到这次 purchase() 产生的交易，这里如果再直接记一遍就会把同一笔交易计两次。
            _ = try await product.purchase()
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
