// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import os.log

private let phraseLog = OSLog(subsystem: "com.pylux.stream", category: "DonationPhrasePicker")

enum DonationPhrasePicker {
    static let paywallBulletShowsBeforePhrases = 3

    private static let defaultCategoryOrder = ["mild", "playful", "mean"]

    private static var cachedFlat: [String]?

    static func clearCache() {
        cachedFlat = nil
    }

    /// 1-based call id: first phrase uses callId == 1, wraps over the flattened list.
    static func phrase(forCallId callId: Int) -> String? {
        guard callId >= 1 else { return nil }
        let flat = cachedFlat ?? loadFlat()
        guard !flat.isEmpty else { return nil }
        let i = floorMod(callId - 1, flat.count)
        return flat[i]
    }

    /// showCount = total paywall opens (1-based). First 3 -> nil (show bullets).
    /// From the 4th open, returns a rotating phrase.
    static func phrase(forPaywallShowCount showCount: Int) -> String? {
        guard showCount > paywallBulletShowsBeforePhrases else { return nil }
        let phraseCallId = showCount - paywallBulletShowsBeforePhrases
        return phrase(forCallId: phraseCallId)
    }

    // MARK: - Private

    private static func loadFlat() -> [String] {
        guard let url = Bundle.main.url(forResource: "donation_prompt_phrases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = root["categories"] as? [String: Any] else {
            os_log(.error, log: phraseLog, "Failed to load donation_prompt_phrases.json from bundle")
            return []
        }

        let order: [String]
        if let arr = root["category_order"] as? [String] {
            order = arr
        } else {
            order = defaultCategoryOrder
        }

        var out: [String] = []
        for key in order {
            guard let cat = categories[key] as? [String: Any],
                  let phrases = cat["phrases"] as? [String] else { continue }
            out.append(contentsOf: phrases)
        }
        cachedFlat = out
        return out
    }

    private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let m = a % b
        return m < 0 ? m + b : m
    }
}
