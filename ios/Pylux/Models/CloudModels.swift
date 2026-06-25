// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud gaming models matching Android's cloudplay/model/ package exactly

import Foundation
import os

// MARK: - CloudGame (matches Android CloudGame.kt)

/// Represents a game in the cloud catalog (PSNow or PSCloud)
struct CloudGame: Identifiable, Hashable {
    let id: String           // catalog productId (PSCloud) or product id (PSNOW)
    let name: String
    let imageUrl: String     // Cover/box art (type 10)
    let landscapeImageUrl: String  // Landscape (type 12/13)
    let platform: String     // "ps4", "ps3", or "ps5"
    let serviceType: String  // "psnow" or "pscloud"
    let conceptUrl: String   // URL to add game to library (PS5)
    let conceptId: String    // Imagic conceptId for catalog dedupe (PS5 cloud)
    var isOwned: Bool        // Whether user owns this game (PS5)
    var entitlementId: String   // PSCloud: entitlement id for streaming (Qt gameData.id)
    var storeProductId: String  // PSCloud: product_id from entitlements API
    var plusCatalog: Bool    // In the PS Plus subscription catalog (vs the full streamable universe)
    var featureType: Int     // PSN entitlement feature_type (owned games): 3=full game, 1=trial/free, 0=add-on
    // Unified-page acquisition tag, assigned once at catalog-assembly time:
    //   "owned"        -> entitlement resolves to a streamable row (Stream)
    //   "streamable"   -> not owned, PS Now subscription title (Stream)
    //   "purchaseable" -> not owned, PS Plus catalog title (Add to Library, then Stream)
    var category: String
    // PS5-platform membership from the imagic catalog's authoritative `device` array (contains
    // "PS5") OR a PPSA product id. Mirrors Qt's isPs5PlatformGame() and is used to decide which
    // browse rows enter the streamable universe -- NOT the CUSA/PPSA productId token, which
    // mis-classifies cross-gen titles (a PS4 CUSA SKU that also lists "PS5" in `device`).
    var isPs5Platform: Bool

    init(productId: String, name: String, imageUrl: String, landscapeImageUrl: String = "",
         platform: String = "ps4", serviceType: String = "psnow",
         conceptUrl: String = "", conceptId: String = "", isOwned: Bool = false,
         entitlementId: String = "", storeProductId: String = "", plusCatalog: Bool = false,
         featureType: Int = 0, category: String = "", isPs5Platform: Bool = false) {
        self.id = productId
        self.name = name
        self.imageUrl = imageUrl
        self.landscapeImageUrl = landscapeImageUrl.isEmpty ? imageUrl : landscapeImageUrl
        self.platform = platform
        self.serviceType = serviceType
        self.conceptUrl = conceptUrl
        self.conceptId = conceptId
        self.isOwned = isOwned
        self.entitlementId = entitlementId
        self.storeProductId = storeProductId
        self.plusCatalog = plusCatalog
        self.featureType = featureType
        self.category = category
        self.isPs5Platform = isPs5Platform
    }

    /// Mirrors CloudGameCard.qml getStreamingIdentifier() for PSCloud. PS5/cronos streams the owned
    /// PS5 entitlement's OWN id (entitlementId), resolved from the entitlement's platform_id during
    /// cross-reference. For a canonical SKU (Red Dead, Alan Wake) that id == product_id == ...PPSA...;
    /// for a classic whose product_id is a non-streamable wrapper (Blood Omen) it is the ...PPSA..SLUS
    /// license. Never a PS4/CUSA cross-buy id (the platform-disciplined merge guarantees this).
    var streamingIdentifier: String {
        if serviceType.lowercased() == "pscloud" {
            if !entitlementId.isEmpty { return entitlementId }
            if !storeProductId.isEmpty { return storeProductId }
        }
        return id
    }

    // Platform that drives the streaming path (PS4 = Kamaji, PS5 = cronos). serviceType is the
    // canonical signal but with one asymmetry: `psnow` is always PS3/PS4-class (set on PS Now browse
    // rows and filled for owned PS3/PS4 cards from platform_id), while `pscloud` is authoritative ONLY
    // for OWNED cards (filled from the entitlement's platform_id) -- non-owned imagic browse rows are
    // blanket-labeled `pscloud` yet include a few PS4 titles, so for those we use the clean id token
    // (PS4 there streams via PS Now/Kamaji, not cronos). Mirrors canonical Qt, whose non-owned imagic
    // rows simply carry no serviceType and so fall through to the same token path.
    var streamPlatform: String {
        let st = serviceType.lowercased()
        if st == "psnow" { return "ps4" }
        // isOwned gate: imagic browse rows are blanket-tagged serviceType="pscloud" (see catalog parse), so
        // only treat "pscloud" as PS5/cronos when actually OWNED; non-owned rows fall through to the product-id
        // token below, routing non-owned PS4 imagic titles to PS Now (matches Qt, whose imagic rows carry no
        // serviceType at all).
        if st == "pscloud" && isOwned { return "ps5" }
        let p = !storeProductId.isEmpty ? storeProductId : (!id.isEmpty ? id : entitlementId)
        if p.contains("PPSA") { return "ps5" }
        if p.contains("CUSA") { return "ps4" }
        return platform.isEmpty ? "ps5" : platform
    }

    /// Service type to stream with: route by the (platform_id-disciplined) streaming platform --
    /// PS3/PS4 via Kamaji (psnow), PS5 direct (pscloud).
    var streamServiceType: String {
        if serviceType.lowercased() == "psnow" { return "psnow" }
        return streamPlatform == "ps4" ? "psnow" : "pscloud"
    }

    /// Identifier to send to startCompleteCloudSession: PS4/psnow sends the product id (Kamaji
    /// converts it to an entitlement); PS5/pscloud sends the owned entitlement id (direct).
    var streamIdentifier: String {
        if streamServiceType == "psnow" {
            return id.isEmpty ? streamingIdentifier : id
        }
        return streamingIdentifier
    }
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

/// Account privacy settings issue
struct AccountPrivacySettingsError: Error, LocalizedError {
    let upgradeUrl: String
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

// MARK: - PS3 / Classics region (mirrors KamajiConsts in gui/include/cloudstreaming/pskamajisession.h)

/// pcnow (the PS Plus PC "Apollo" backend) has only TWO Classics id families:
///   * SCEA / Americas  -> store MSF192018, US-region ids (UP*/NPUA*/BLUS*),
///                         PS3 child container "APOLLOPS3GAMES"
///   * SCEE / PAL (rest) -> store MSF192014, EU-region ids (EP*/NPEA*/NPEB*/BLES*),
///                         PS3 child container "APOLLOPS3"
/// JP / Asia have no Apollo store (the PC app isn't offered there), so they fall back to
/// PAL. A PS Plus account is authorized at Gaikai only for the id family of its own region
/// group, so we must browse + resolve in the account's group.
enum ClassicsRegion {
    private static let americas: Set<String> = [
        "US", "CA", "MX", "BR", "AR", "CL", "CO", "PE", "EC", "BO",
        "PY", "UY", "CR", "GT", "HN", "NI", "PA", "SV", "DO"
    ]

    static func isAmericasClassicsRegion(_ countryCode: String) -> Bool {
        return americas.contains(countryCode.uppercased())
    }

    /// Country path to use for container/conversion calls (US for Americas, GB for PAL).
    static func classicsStoreCountry(_ accountCountry: String) -> String {
        return isAmericasClassicsRegion(accountCountry) ? "US" : "GB"
    }

    /// Fully-qualified PS3 catalog container id for the account's region group.
    static func classicsPs3ContainerId(_ accountCountry: String) -> String {
        return isAmericasClassicsRegion(accountCountry)
            ? "STORE-MSF192018-APOLLOPS3GAMES"
            : "STORE-MSF192014-APOLLOPS3"
    }

    /// Fully-qualified APOLLOROOT (PS Now: PS3 + PS4) container id for the account's region group.
    static func apolloRootContainerId(_ accountCountry: String) -> String {
        return isAmericasClassicsRegion(accountCountry)
            ? "STORE-MSF192018-APOLLOROOT"
            : "STORE-MSF192014-APOLLOROOT"
    }
}

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

    static var imagicLocale: String { stored.lowercased() }

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

    /// Ordered store locales to try when fetching the catalog. Sony serves a fixed set of
    /// language-COUNTRY combinations: the country is always valid but the language may not be
    /// (a Hungarian-language account yields "hu-HU", which 404s, while "en-HU" works). Fall
    /// back to English for the same country, then en-US, so the catalog loads in every region.
    /// Each tuple is (canonical "ll-CC" for storage, lowercased "ll-cc" for the imagic URL).
    static func fallbackChain() -> [(canonical: String, imagic: String)] {
        let (country, lang) = parseStorePath(stored)
        var seen = Set<String>()
        var chain: [(String, String)] = []
        func add(_ l: String, _ c: String) {
            let canonical = "\(l)-\(c)"
            let imagic = canonical.lowercased()
            if seen.insert(imagic).inserted { chain.append((canonical, imagic)) }
        }
        add(lang, country)
        add("en", country)
        add("en", "US")
        return chain
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
