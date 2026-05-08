// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import StoreKit
import os.log

private let donationLog = OSLog(subsystem: "com.pylux.stream", category: "DonationStore")

@MainActor
final class DonationStore: ObservableObject {
    static let shared = DonationStore()

    static let productIDs: [String] = [
        "pylux_support_bronze",
        "pylux_support_silver",
        "pylux_support_gold",
        "pylux_support_platinum",
    ]

    @Published private(set) var tiers: [Product] = []
    @Published private(set) var ownsDonation = false
    @Published private(set) var loadFailed = false

    private var transactionListenerTask: Task<Void, Never>?

    private init() {
        transactionListenerTask = listenForTransactions()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.productIDs)
            let ordered = Self.productIDs.compactMap { id in
                products.first { $0.id == id }
            }
            tiers = ordered
            loadFailed = ordered.isEmpty
            os_log(.info, log: donationLog, "Loaded %d donation tiers", ordered.count)
        } catch {
            os_log(.error, log: donationLog, "Failed to load products: %{public}@", error.localizedDescription)
            tiers = []
            loadFailed = true
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                ownsDonation = true
                os_log(.info, log: donationLog, "Purchase succeeded: %{public}@", product.id)
                return true
            case .userCancelled:
                os_log(.info, log: donationLog, "Purchase cancelled by user")
                return false
            case .pending:
                os_log(.info, log: donationLog, "Purchase pending")
                return false
            @unknown default:
                return false
            }
        } catch {
            os_log(.error, log: donationLog, "Purchase failed: %{public}@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Restore

    enum RestoreResult {
        case none
        case alreadyOnDevice
        case restored
        case unavailable
    }

    func restorePurchases() async -> RestoreResult {
        do {
            try await AppStore.sync()
        } catch {
            os_log(.error, log: donationLog, "AppStore.sync failed: %{public}@", error.localizedDescription)
            return .unavailable
        }

        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if Self.productIDs.contains(transaction.productID) {
                found = true
                ownsDonation = true
            }
        }

        if !found {
            return .none
        }
        return .alreadyOnDevice
    }

    // MARK: - Ownership Check

    func checkOwnership() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if Self.productIDs.contains(transaction.productID) {
                ownsDonation = true
                return
            }
        }
        ownsDonation = false
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let strongSelf = self else { return }
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                if DonationStore.productIDs.contains(transaction.productID) {
                    await MainActor.run {
                        strongSelf.ownsDonation = true
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    // MARK: - Tier Metadata

    static func tierDisplayName(for productID: String) -> String {
        switch productID {
        case "pylux_support_bronze":   return "Bronze donation"
        case "pylux_support_silver":   return "Silver donation"
        case "pylux_support_gold":     return "Gold donation"
        case "pylux_support_platinum": return "Platinum donation"
        default:
            return productID.split(separator: "_").last.map { String($0).capitalized } ?? productID
        }
    }

    static func tierBlurb(for productID: String) -> String {
        switch productID {
        case "pylux_support_bronze":   return "Every donation counts."
        case "pylux_support_silver":   return "A bit more support."
        case "pylux_support_gold":     return "When you want to give more."
        case "pylux_support_platinum": return "If you want to give the most."
        default:                       return "Thank you for supporting Pylux."
        }
    }
}
