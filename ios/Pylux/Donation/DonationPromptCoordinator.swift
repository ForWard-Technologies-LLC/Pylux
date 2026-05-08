// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import os.log

private let coordLog = OSLog(subsystem: "com.pylux.stream", category: "DonationPrompt")

@MainActor
final class DonationPromptCoordinator: ObservableObject {
    static let shared = DonationPromptCoordinator()

    static let minStreamMs: Int64 = 3_600_000
    static let autoPromptMinIntervalMs: Int64 = 3_600_000
    static let showDelaySeconds: TimeInterval = 5.0

    @Published var showPaywall = false

    private var scheduledTask: Task<Void, Never>?
    private var connectedAt: Date?

    private init() {}

    // MARK: - Stream Auto-Prompt

    func scheduleOfferIfEligible() {
        guard !DonationStore.productIDs.isEmpty else {
            os_log(.info, log: coordLog, "Donation: skipped — no product IDs")
            return
        }
        let store = SecureStore.shared
        let total = store.totalStreamTimeMs
        let last = store.lastDonationPromptWallClockMs
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        os_log(.info, log: coordLog, "Donation: totalStreamMs=%lld (need %lld), lastPrompt=%lld, now=%lld, cooldownLeft=%llds",
               total, Self.minStreamMs, last, now, last > 0 ? max(0, Self.autoPromptMinIntervalMs - (now - last)) / 1000 : 0)
        guard total >= Self.minStreamMs else { return }
        if last > 0, now - last < Self.autoPromptMinIntervalMs { return }

        cancelScheduledOffer()
        scheduledTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.showDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await DonationStore.shared.checkOwnership()
            guard !Task.isCancelled else { return }

            if DonationStore.shared.ownsDonation {
                SecureStore.shared.lastDonationPromptWallClockMs = Int64(Date().timeIntervalSince1970 * 1000)
                return
            }

            await DonationStore.shared.loadProducts()
            guard !Task.isCancelled else { return }

            SecureStore.shared.lastDonationPromptWallClockMs = Int64(Date().timeIntervalSince1970 * 1000)
            showPaywall = true
        }
    }

    func cancelScheduledOffer() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    // MARK: - Settings Entry (no gates)

    func openSupportFromSettings() {
        guard !DonationStore.productIDs.isEmpty else { return }
        cancelScheduledOffer()
        scheduledTask = Task { @MainActor in
            await DonationStore.shared.loadProducts()
            guard !Task.isCancelled else { return }
            showPaywall = true
        }
    }

    // MARK: - Stream Time Tracking

    func markConnected() {
        if connectedAt == nil {
            connectedAt = Date()
        }
    }

    func flushStreamTime() {
        guard let start = connectedAt else { return }
        let delta = Int64(Date().timeIntervalSince(start) * 1000)
        if delta > 0 {
            SecureStore.shared.addTotalStreamTimeMs(delta)
        }
        connectedAt = nil
    }
}
