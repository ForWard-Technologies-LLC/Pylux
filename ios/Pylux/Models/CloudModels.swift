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

To continue anyway, go to Settings → Cloud and manually select a datacenter for your service (Game Library or Game Catalog).
"""
    var errorDescription: String? { Self.alertMessage }
}

/// Authorization failed
struct AuthorizationFailedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// General Gaikai allocation error
struct GaikaiAllocationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Kamaji session error
struct KamajiSessionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Cloud API Constants (matches Android PsnApiConstants.kt + GaikaiConsts)

enum CloudApiConstants {
    // Gaikai constants (matches GaikaiConsts in PSGaikaiStreaming.kt)
    static let configBase = "https://config.cc.prod.gaikai.com/v1"
    static let gaikaiBase = "https://cc.prod.gaikai.com/v1"
    static let gaikaiAccountBase = "https://ca.account.sony.com"
    static let gaikaiRedirectUri = "gaikai://local"
    static let gaikaiUserAgent = "PlayStation Portal/6.0.0-rel.444+6a9cea6f5"

    // PSNow / Kamaji constants (matches PsnApiConstants.kt)
    static let kamajiBase = "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000"
    static let storeBase = "https://psnow.playstation.com/store/api/pcnow/00_09_000"
    static let commerceBase = "https://commerce.api.np.km.playstation.net/commerce/api/v1"
    static let kamajiClientId = "bc6b0777-abb5-40da-92ca-e133cf18e989"
    static let kamajiRedirectUri = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html"
    static let kamajiOrigin = "https://psnow.playstation.com"
    static let kamajiReferer = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/"
    static let kamajiUserAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo"
    static let ps4Scopes = "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get"

    // Cloud config (matches CloudConfig in CloudStreamingBackend.kt)
    static let accountBase = "https://ca.account.sony.com/api"
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
    private static let preferencesKey = "cloud_language_pscloud"
    static let defaultStored = "en-US"

    static var isConfigured: Bool {
        UserDefaults.standard.object(forKey: preferencesKey) != nil
    }

    static var stored: String {
        UserDefaults.standard.string(forKey: preferencesKey) ?? defaultStored
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

    static func fromSession(language: String?, country: String?) -> String? {
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cty = country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !lang.isEmpty, !cty.isEmpty else { return nil }
        return "\(lang)-\(cty.uppercased())"
    }

    static func setFromSession(language: String?, country: String?) {
        guard let locale = fromSession(language: language, country: country) else {
            os_log(.info, log: cloudLocaleLog,
                   "Kamaji session: no language/country in response (stored=%{public}s)", stored)
            return
        }
        if isConfigured {
            // The country is the real region signal; the language part may get auto-corrected
            // by the imagic fetch (e.g. hu-HU settles on en-HU). Only re-save when the country
            // changes, otherwise we'd clobber the validated locale on every Kamaji session.
            let storedCountry = parseStorePath(stored).country
            let sessionCountry = parseStorePath(locale).country
            if storedCountry == sessionCountry {
                os_log(.info, log: cloudLocaleLog,
                       "Kamaji session country unchanged (%{public}s), keeping validated locale %{public}s",
                       sessionCountry, stored)
                return
            }
        }
        setStored(locale)
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

    private static func invalidateCatalogCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(catalogCacheSubdir, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where !file.hasDirectoryPath {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func applyLocaleFromKamajiSessionBody(_ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return }
        setFromSession(
            language: dataObj["language"] as? String,
            country: dataObj["country"] as? String
        )
    }

    private static let bootstrapLock = NSLock()

    @discardableResult
    static func ensureConfigured(npssoToken: String) -> Bool {
        if isConfigured { return true }
        guard !npssoToken.isEmpty else {
            os_log(.info, log: cloudLocaleLog, "Locale bootstrap skipped: no npsso token")
            return false
        }

        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        if isConfigured { return true }

        os_log(.info, log: cloudLocaleLog, "Bootstrapping cloud locale via Kamaji session (first time only)")
        let duid = generateBootstrapDuid()
        guard let code = fetchBootstrapOAuthCode(npssoToken: npssoToken, duid: duid) else {
            os_log(.info, log: cloudLocaleLog, "Locale bootstrap failed: OAuth")
            return false
        }
        guard postBootstrapKamajiSession(oauthCode: code, duid: duid) else {
            os_log(.info, log: cloudLocaleLog, "Locale bootstrap failed: Kamaji session")
            return false
        }
        os_log(.info, log: cloudLocaleLog, "Locale bootstrap OK: %{public}s", stored)
        return isConfigured
    }

    private static func fetchBootstrapOAuthCode(npssoToken: String, duid: String) -> String? {
        let params: [(String, String)] = [
            ("smcid", "pc:psnow"), ("applicationId", "psnow"),
            ("response_type", "code"), ("scope", CloudApiConstants.ps4Scopes),
            ("client_id", CloudApiConstants.kamajiClientId),
            ("redirect_uri", CloudApiConstants.kamajiRedirectUri),
            ("service_entity", "urn:service-entity:psn"), ("prompt", "none"),
            ("renderMode", "mobilePortrait"), ("hidePageElements", "forgotPasswordLink"),
            ("displayFooter", "none"), ("disableLinks", "qriocityLink"),
            ("mid", "PSNOW"), ("duid", duid), ("layout_type", "popup"),
            ("service_logo", "ps"), ("tp_psn", "true"), ("noEVBlock", "true")
        ]
        let query = params.map { "\($0.0)=\($0.1.cloudUrlEncoded)" }.joined(separator: "&")
        let url = "\(CloudApiConstants.accountBase)/v1/oauth/authorize?\(query)"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Cookie": "npsso=\(npssoToken)"
        ], followRedirects: false), response.statusCode == 302,
              let location = CloudHttpClient.extractLocation(from: response),
              let comps = URLComponents(string: location),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        return code
    }

    private static func postBootstrapKamajiSession(oauthCode: String, duid: String) -> Bool {
        let url = "\(CloudApiConstants.kamajiBase)/user/session"
        let body = "code=\(oauthCode)&client_id=\(CloudApiConstants.kamajiClientId)&duid=\(duid)"

        guard let response = CloudHttpClient.post(url: url, body: body, headers: [
            "Content-Type": "text/plain;charset=UTF-8",
            "X-Alt-Referer": CloudApiConstants.kamajiRedirectUri,
            "Origin": CloudApiConstants.kamajiOrigin,
            "Referer": CloudApiConstants.kamajiReferer,
            "Accept": "*/*"
        ]), response.statusCode == 200 else { return false }

        guard let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              header["status_code"] as? String == "0x0000" else { return false }

        applyLocaleFromKamajiSessionBody(response.body)
        return isConfigured
    }

    private static func generateBootstrapDuid() -> String {
        let prefix = "0000000700410080"
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        return prefix + randomBytes.map { String(format: "%02x", $0) }.joined()
    }
}
