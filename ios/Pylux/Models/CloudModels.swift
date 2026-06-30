// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud gaming models matching Android's cloudplay/model/ package exactly

import Foundation
import os

// MARK: - CloudGame (matches Android CloudGame.kt)

/// One game from libchiaki's unified cloud catalog. EVERY field is precomputed by
/// the lib (chiaki/cloudcatalog.h) — category, serviceType, platform, ownership and
/// the stream routing values. iOS parses the contract and renders it; it must NOT
/// re-derive any of these (that logic now lives in one place: lib/src/cloudcatalog_*).
struct CloudGame: Identifiable, Hashable {
    let id: String           // canonical catalog productId + stable dedup key
    let name: String
    let imageUrl: String     // portrait / box art
    let landscapeImageUrl: String
    let platform: String     // "ps3" | "ps4" | "ps5" (badge; derived from device[])
    let serviceType: String  // "psnow" | "pscloud" (catalog routing)
    let conceptUrl: String   // purchase / add-to-library deep link
    let conceptId: String
    let isOwned: Bool
    let entitlementId: String
    let storeProductId: String
    let plusCatalog: Bool
    // Acquisition tag: "owned" (Stream) | "streamable" (Stream) | "purchaseable" (Add to Library).
    let category: String
    // Endpoint + exact id the stream action uses (lib-computed; PS3/PS4 -> Kamaji/psnow,
    // PS5 -> cronos/pscloud). The UI hands these straight to the streaming backend.
    let streamServiceType: String
    let streamIdentifier: String

    /// Build from one element of the lib unified-catalog "games" array.
    init?(contract g: [String: Any]) {
        guard let pid = g["productId"] as? String, !pid.isEmpty,
              let name = g["name"] as? String, !name.isEmpty else { return nil }
        self.id = pid
        self.name = name
        let cover = g["imageUrl"] as? String ?? ""
        self.imageUrl = cover
        let landscape = g["landscapeImageUrl"] as? String ?? ""
        self.landscapeImageUrl = landscape.isEmpty ? cover : landscape
        self.platform = g["platform"] as? String ?? "ps4"
        // Contract always sets serviceType; default matches Qt's getServiceType() ("pscloud").
        self.serviceType = g["serviceType"] as? String ?? "pscloud"
        self.conceptUrl = g["conceptUrl"] as? String ?? ""
        self.conceptId = g["conceptId"] as? String ?? ""
        self.isOwned = g["isOwned"] as? Bool ?? false
        self.entitlementId = g["entitlementId"] as? String ?? ""
        self.storeProductId = g["storeProductId"] as? String ?? ""
        self.plusCatalog = g["plusCatalog"] as? Bool ?? false
        self.category = g["category"] as? String ?? ""
        let sst = g["streamServiceType"] as? String ?? ""
        self.streamServiceType = sst.isEmpty ? self.serviceType : sst
        let sid = g["streamIdentifier"] as? String ?? ""
        self.streamIdentifier = sid.isEmpty ? pid : sid
    }
}

// MARK: - Cloud catalog acquisition categories (lib contract "category" values)

enum CloudCategory {
    static let owned = "owned"
    static let streamable = "streamable"
    static let purchaseable = "purchaseable"
}

// MARK: - CloudStreamSession (matches Android CloudStreamSession.kt)

/// Cloud stream session data returned after Gaikai allocation
struct CloudStreamSession {
    let serverIp: String
    let serverPort: Int
    let handshakeKey: String
    let launchSpec: String
    let sessionId: String
    let entitlementId: String
    let gameName: String
    let platform: String
    let psnWrapperType: Int
    let mtuIn: Int
    let mtuOut: Int
    let rttMs: Int
    let serviceType: String  // "psnow" or "pscloud"
}

// MARK: - Cloud Errors (matches Android CloudStreamingExceptions.kt)

/// PS Plus subscription required
struct PsPlusSubscriptionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// RTT > 80ms on auto datacenter (matches `gui/src/qml/Main.qml` ping dialog copy).
struct PingTimeoutError: Error, LocalizedError {
    static let alertTitle = "Ping Too High"
    static let alertMessage = """
Ping must be less than 80ms to start a cloud session.

To continue anyway, go to Settings → Cloud and manually select a datacenter for your service (Owned Games or Streamable Games).
"""
    var errorDescription: String? { Self.alertMessage }
}

/// Authorization failed
struct AuthorizationFailedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// PSN account privacy settings need updating before cloud streaming (the C flow's
/// "ACCOUNT_PRIVACY_SETTINGS:<url>" sentinel). iOS has no dedicated dialog for this,
/// so it surfaces through CloudPlayView's generic error alert. `upgradeUrl` may be
/// empty -- the message degrades gracefully when no URL is available.
struct AccountPrivacySettingsError: Error, LocalizedError {
    let upgradeUrl: String
    var errorDescription: String? {
        let base = "Your PlayStation account privacy settings need updating before you can use cloud streaming. Update them in your PSN account settings, then try again."
        return upgradeUrl.isEmpty ? base : base + "\n\n" + upgradeUrl
    }
}

/// General Gaikai allocation error
struct GaikaiAllocationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}


// Region-group / Classics-container logic now lives in libchiaki (lib/src/cloudcatalog_consts.c)
// and is reflected back to the client via the unified catalog's "fallbackRegion" field.

// MARK: - Gaikai Allocation Result

struct GaikaiAllocationResult {
    let success: Bool
    let message: String
    var serverIp: String = ""
    var serverPort: Int = 0
    var handshakeKey: String = ""
    var launchSpec: String = ""
    var sessionId: String = ""
    var psnWrapperType: Int = 0
    var mtuIn: Int = 0
    var mtuOut: Int = 0
    var rttMs: Int = 0
}

// MARK: - Kamaji Session Result

struct KamajiSessionResult {
    let success: Bool
    let message: String
    var entitlementId: String = ""
    var platform: String = ""
}

// MARK: - Cloud locale

private let cloudLocaleLog = OSLog(subsystem: "com.pylux.stream", category: "CloudLocale")

enum CloudLocaleSettings {
    private static let preferencesKey = "cloud_store_locale"
    private static let legacyPreferencesKey = "cloud_language_pscloud"
    static let defaultStored = "en-US"

    static var isConfigured: Bool {
        UserDefaults.standard.object(forKey: preferencesKey) != nil
            || UserDefaults.standard.object(forKey: legacyPreferencesKey) != nil
    }

    static var stored: String {
        if UserDefaults.standard.object(forKey: preferencesKey) != nil {
            return UserDefaults.standard.string(forKey: preferencesKey) ?? defaultStored
        }
        let legacy = UserDefaults.standard.string(forKey: legacyPreferencesKey) ?? defaultStored
        UserDefaults.standard.set(legacy, forKey: preferencesKey)
        return legacy
    }

    static func unconfiguredWarning() -> String {
        "Could not detect your PlayStation region. The catalog may not match your store."
    }

    static func parseStorePath(_ stored: String) -> (country: String, language: String) {
        let parts = stored.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let language = parts.first.map(String.init)?.lowercased()
        let lang = (language?.isEmpty == false) ? language! : "en"
        var country = parts.count > 1 ? String(parts[1]).uppercased() : "US"
        if country.isEmpty { country = "US" }
        return (country, lang)
    }

    /// Persist the locale the lib actually settled on (unified catalog "settledLocale"),
    /// WITHOUT wiping the cache. The lib owns its own cache invalidation; this only keeps
    /// the locale we pass next time (and the streaming language) in sync with the lib.
    /// Writes when not yet configured (even when it equals the en-US default, so the
    /// "couldn't detect region" banner clears) or when the value changed.
    static func noteSettledLocale(_ value: String) {
        guard !value.isEmpty, !isConfigured || value != stored else { return }
        UserDefaults.standard.set(value, forKey: preferencesKey)
        os_log(.info, log: cloudLocaleLog, "Cloud locale settled by lib: %{public}s", value)
    }

    static func setStored(_ value: String) {
        if isConfigured && stored == value { return }
        let wasConfigured = isConfigured
        let previous = wasConfigured ? stored : defaultStored
        UserDefaults.standard.set(value, forKey: preferencesKey)
        os_log(.info, log: cloudLocaleLog,
               "Cloud locale %{public}s: %{public}s -> %{public}s",
               wasConfigured ? "changed" : "configured", previous, value)
        invalidateCatalogCache()
    }

    private static let catalogCacheSubdir = "cloud_catalog_cache"

    static func invalidateCatalogCache(reason: String = "") {
        os_log(.info, log: cloudLocaleLog, "Catalog cache invalidated%{public}s",
               reason.isEmpty ? "" : " (\(reason))")
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(catalogCacheSubdir, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where !file.hasDirectoryPath {
            try? FileManager.default.removeItem(at: file)
        }
    }

}
