// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Kamaji authentication (Steps 0.5a-6) - mirrors Android PSKamajiSession.kt exactly

import Foundation
import os.log

private let kamajiLog = OSLog(subsystem: "com.pylux.stream", category: "Kamaji")

/// PSKamajiSession - Handles PlayStation Cloud Gaming Kamaji Authentication (Steps 1-6)
/// Used only for PSNOW games (PS3/PS4). PSCLOUD skips Kamaji entirely.
/// Mirrors: android/.../cloudplay/api/PSKamajiSession.kt
final class PSKamajiSession {
    private let duid: String
    private let productId: String
    private let accountBaseUrl: String
    private let redirectUri: String
    private let userAgent: String

    private let kamajiBase = CloudApiConstants.kamajiBase
    private let storeBase = CloudApiConstants.storeBase
    private let commerceBase = CloudApiConstants.commerceBase
    private let kamajiClientId = CloudApiConstants.kamajiClientId

    private var platform = "ps4"
    private var scopesStr = CloudApiConstants.ps4Scopes
    private var jsessionId: String?
    private var entitlementId: String?
    private var streamingSku: String?
    private var commerceOAuthToken: String?

    init(duid: String, productId: String, accountBaseUrl: String, redirectUri: String, userAgent: String) {
        self.duid = duid
        self.productId = productId
        self.accountBaseUrl = accountBaseUrl
        self.redirectUri = redirectUri
        self.userAgent = userAgent
    }

    /// Start the complete Kamaji session creation flow
    func startSessionCreation(npssoToken: String) -> KamajiSessionResult {
        os_log(.info, log: kamajiLog, "=== Starting Kamaji Session ===")
        os_log(.info, log: kamajiLog, "Product ID: %{public}s", productId)

        // Step 0.5b: Get anonymous auth code
        guard let anonCode = step0_5b_GetAnonymousAuthCode(npssoToken: npssoToken) else {
            return KamajiSessionResult(success: false, message: "Failed to get anonymous auth code")
        }
        os_log(.info, log: kamajiLog, "✓ Step 0.5b: Got anonymous auth code")

        // Step 0.5c: Create anonymous session
        guard let sessionId = step0_5c_CreateAnonymousSession(authCode: anonCode) else {
            return KamajiSessionResult(success: false, message: "Failed to create anonymous session")
        }
        jsessionId = sessionId
        os_log(.info, log: kamajiLog, "✓ Step 0.5c: Got JSESSIONID")

        // Step 0.5d: Convert product ID to entitlement ID
        guard let conversion = step0_5d_ConvertProductId(sessionId: sessionId) else {
            return KamajiSessionResult(success: false, message: "Failed to convert product ID")
        }
        entitlementId = conversion.entitlementId
        platform = conversion.platform
        streamingSku = conversion.sku
        os_log(.info, log: kamajiLog, "✓ Step 0.5d: Entitlement: %{public}s, Platform: %{public}s",
               entitlementId ?? "", platform)

        if platform == "ps3" { scopesStr = "kamaji:commerce_native" }

        // Step 0.5e: Check and acquire entitlement
        guard step0_5e_CheckAndAcquireEntitlement(npssoToken: npssoToken, sessionId: sessionId) else {
            return KamajiSessionResult(success: false, message: "Failed to check/acquire entitlement")
        }
        os_log(.info, log: kamajiLog, "✓ Step 0.5e: Entitlement check OK")

        // Step 5: Get auth code (same as 0.5b)
        guard let authCode = step0_5b_GetAnonymousAuthCode(npssoToken: npssoToken) else {
            return KamajiSessionResult(success: false, message: "Failed to get auth code")
        }
        os_log(.info, log: kamajiLog, "✓ Step 5: Got auth code")

        // Step 6: Create auth session (same as 0.5c)
        guard step0_5c_CreateAnonymousSession(authCode: authCode) != nil else {
            return KamajiSessionResult(success: false, message: "Failed to create auth session")
        }
        os_log(.info, log: kamajiLog, "✓ Step 6: Authenticated session created")
        os_log(.info, log: kamajiLog, "=== Kamaji Session Complete ===")

        return KamajiSessionResult(success: true, message: "Success",
                                   entitlementId: entitlementId ?? "", platform: platform)
    }

    // MARK: - Step 0.5b: Get Anonymous Auth Code

    private func step0_5b_GetAnonymousAuthCode(npssoToken: String) -> String? {
        let params: [(String, String)] = [
            ("smcid", "pc:psnow"), ("applicationId", "psnow"),
            ("response_type", "code"), ("scope", scopesStr),
            ("client_id", kamajiClientId), ("redirect_uri", redirectUri),
            ("service_entity", "urn:service-entity:psn"), ("prompt", "none"),
            ("renderMode", "mobilePortrait"), ("hidePageElements", "forgotPasswordLink"),
            ("displayFooter", "none"), ("disableLinks", "qriocityLink"),
            ("mid", "PSNOW"), ("duid", duid), ("layout_type", "popup"),
            ("service_logo", "ps"), ("tp_psn", "true"), ("noEVBlock", "true")
        ]
        let query = params.map { "\($0.0)=\($0.1.cloudUrlEncoded)" }.joined(separator: "&")
        let url = "\(accountBaseUrl)/v1/oauth/authorize?\(query)"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "User-Agent": userAgent, "Cookie": "npsso=\(npssoToken)"
        ], followRedirects: false), response.statusCode == 302 else { return nil }

        guard let location = CloudHttpClient.extractLocation(from: response),
              let comps = URLComponents(string: location),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        return code
    }

    // MARK: - Step 0.5c: Create Anonymous Session

    @discardableResult
    private func step0_5c_CreateAnonymousSession(authCode: String) -> String? {
        let url = "\(kamajiBase)/user/session"
        let body = "code=\(authCode)&client_id=\(kamajiClientId)&duid=\(duid)"

        guard let response = CloudHttpClient.post(url: url, body: body, headers: [
            "Content-Type": "text/plain;charset=UTF-8",
            "User-Agent": userAgent,
            "X-Alt-Referer": redirectUri,
            "Accept": "*/*",
            "Origin": CloudApiConstants.kamajiOrigin,
            "Referer": CloudApiConstants.kamajiReferer
        ]), response.statusCode == 200 else { return nil }

        CloudLocaleSettings.applyLocaleFromKamajiSessionBody(response.body)
        return CloudHttpClient.extractCookie(from: response, name: "JSESSIONID")
    }

    // MARK: - Step 0.5d: Convert Product ID

    private struct ProductConversion {
        let entitlementId: String
        let platform: String
        let sku: String
    }

    // PS3 / Classics product ids (NPEA/NPEB/BLES/BCES or NPUA/NPUB/BLUS/BCUS — anything that
    // isn't a modern CUSA/PPSA id) come from the public Apollo catalog, which we walk in the
    // account's region group (Americas -> US store, everything else -> PAL/GB). Resolve them
    // against that SAME region's container so the lookup finds the product and returns the PSNW
    // entitlement the account is authorized for at Gaikai. The account's own locale country can
    // be a region with no pcnow storefront (e.g. Hungary -> "Storefront not found"), so map to
    // the region-group store. Must match CloudCatalogService's PS3 catalog source.
    private var isLegacyClassicsId: Bool {
        return !productId.contains("CUSA") && !productId.contains("PPSA")
    }

    private func step0_5d_ConvertProductId(sessionId: String) -> ProductConversion? {
        let storePath = CloudLocaleSettings.parseStorePath(CloudLocaleSettings.stored)
        var country = storePath.country
        var language = storePath.language
        if isLegacyClassicsId {
            country = ClassicsRegion.classicsStoreCountry(country)
            language = "en"
        }
        let url = "\(storeBase)/container/\(country)/\(language)/19/\(productId)?useOffers=true&gkb=1&gkb2=1"
        os_log(.info, log: kamajiLog, "Store container locale: %{public}s", CloudLocaleSettings.stored)

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        ]), response.statusCode == 200 else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any] else {
            return nil
        }

        var eid = ""
        var sku = ""
        var detectedPlatform = "ps4"

        // PS Now streaming entitlements have license_type == 4. Check default_sku, then skus.
        func pickStreamingEntitlement(_ skuObj: [String: Any]) -> Bool {
            guard let ents = skuObj["entitlements"] as? [[String: Any]] else { return false }
            for ent in ents {
                if (ent["license_type"] as? Int) == 4, let id = ent["id"] as? String, !id.isEmpty {
                    eid = id; sku = skuObj["id"] as? String ?? ""; return true
                }
            }
            return false
        }
        if let defaultSku = json["default_sku"] as? [String: Any] { _ = pickStreamingEntitlement(defaultSku) }
        if eid.isEmpty, let skus = json["skus"] as? [[String: Any]] {
            for skuObj in skus where pickStreamingEntitlement(skuObj) { break }
        }

        // Full-game fallback: PS Plus catalog titles have no license_type==4 entitlement; their
        // full-game entitlement is license_type 0 with packageType "*GD". Prefer the one whose id
        // matches the requested product's title id so cross-gen picks the consistent platform.
        if eid.isEmpty {
            let requestedTitleId: String = {
                let dash = productId.split(separator: "-")
                guard dash.count >= 2 else { return "" }
                return String(dash[1].split(separator: "_").first ?? "")
            }()
            func pickFullGameEntitlement(_ skuObj: [String: Any], requireTitleMatch: Bool) -> Bool {
                guard let ents = skuObj["entitlements"] as? [[String: Any]] else { return false }
                for ent in ents {
                    guard let id = ent["id"] as? String, !id.isEmpty else { continue }
                    let pkg = ent["packageType"] as? String ?? ""
                    guard pkg.hasSuffix("GD") else { continue }
                    if requireTitleMatch, !requestedTitleId.isEmpty, !id.contains(requestedTitleId) { continue }
                    eid = id; sku = skuObj["id"] as? String ?? ""; return true
                }
                return false
            }
            for requireTitleMatch in [true, false] {
                if let defaultSku = json["default_sku"] as? [String: Any],
                   pickFullGameEntitlement(defaultSku, requireTitleMatch: requireTitleMatch) { break }
                if let skus = json["skus"] as? [[String: Any]] {
                    var found = false
                    for skuObj in skus where pickFullGameEntitlement(skuObj, requireTitleMatch: requireTitleMatch) { found = true; break }
                    if found { break }
                }
            }
        }

        // Detect platform (PS5 > PS4 > PS3)
        if let platforms = json["playable_platform"] as? [String] {
            if platforms.contains(where: { $0.localizedCaseInsensitiveContains("PS5") }) { detectedPlatform = "ps5" }
            else if platforms.contains(where: { $0.localizedCaseInsensitiveContains("PS4") }) { detectedPlatform = "ps4" }
            else if platforms.contains(where: { $0.localizedCaseInsensitiveContains("PS3") }) { detectedPlatform = "ps3" }
        }

        guard !eid.isEmpty else { return nil }
        return ProductConversion(entitlementId: eid, platform: detectedPlatform, sku: sku)
    }

    // MARK: - Step 0.5e: Check and Acquire Entitlement

    private func step0_5e_CheckAndAcquireEntitlement(npssoToken: String, sessionId: String) -> Bool {
        // Step 0.5e.1: Get commerce OAuth token
        guard let commerceToken = step0_5e1_GetCommerceOAuthToken(npssoToken: npssoToken) else { return false }
        commerceOAuthToken = commerceToken

        // Step 0.5e.2: Check if entitlement exists
        let hasEntitlement = step0_5e2_CheckEntitlementExists()
        if hasEntitlement == nil { return false }
        if hasEntitlement == true { return true }

        // Entitlement not found (404). For PS3 / Classics (legacy non-CUSA/PPSA ids) the streaming
        // entitlement is granted by the PS Plus subscription via a free 100%-off checkout, but that
        // checkout requires a pcnow storefront in the account's region — which many regions (e.g.
        // Hungary) don't have, so the acquire fails with "Against Eligibility Rule". On a real PS5
        // the subscription alone grants streaming with no purchase, so skip the acquire and let
        // Gaikai validate the Premium subscription directly. If Gaikai genuinely needs the
        // entitlement, it returns noGameForEntitlementId downstream and we learn the wall is there.
        if isLegacyClassicsId {
            os_log(.info, log: kamajiLog,
                   "Entitlement not found (404); legacy Classics id -> skipping acquire, proceeding to Gaikai")
            return true
        }

        // PS4/PS5 catalog: try to acquire it via checkout.
        // Step 0.5e.3: Checkout preview
        guard step0_5e3_CheckoutPreview(sessionId: sessionId) else { return false }

        // Step 0.5e.4: Complete checkout
        return step0_5e4_CheckoutBuynow(sessionId: sessionId)
    }

    private func step0_5e1_GetCommerceOAuthToken(npssoToken: String) -> String? {
        let params: [(String, String)] = [
            ("smcid", "pc:psnow"), ("applicationId", "psnow"),
            ("response_type", "token"),
            ("scope", "kamaji:get_internal_entitlements user:account.attributes.validate kamaji:get_privacy_settings user:account.settings.privacy.get kamaji:s2s.subscriptionsPremium.get"),
            ("client_id", "dc523cc2-b51b-4190-bff0-3397c06871b3"),
            ("redirect_uri", redirectUri), ("grant_type", "authorization_code"),
            ("service_entity", "urn:service-entity:psn"), ("prompt", "none"),
            ("renderMode", "mobilePortrait"), ("hidePageElements", "forgotPasswordLink"),
            ("displayFooter", "none"), ("disableLinks", "qriocityLink"),
            ("mid", "PSNOW"), ("duid", duid), ("layout_type", "popup"),
            ("service_logo", "ps"), ("tp_psn", "true"), ("noEVBlock", "true")
        ]
        let query = params.map { "\($0.0)=\($0.1.cloudUrlEncoded)" }.joined(separator: "&")
        let url = "\(accountBaseUrl)/v1/oauth/authorize?\(query)"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "User-Agent": userAgent, "Cookie": "npsso=\(npssoToken)"
        ], followRedirects: false), response.statusCode == 302 else { return nil }

        guard let location = CloudHttpClient.extractLocation(from: response) else { return nil }

        // Extract access_token from URL fragment (#access_token=...) or query
        if let range = location.range(of: "access_token=") {
            let rest = String(location[range.upperBound...])
            return rest.split(separator: "&").first.map(String.init)
        }
        return nil
    }

    private func step0_5e2_CheckEntitlementExists() -> Bool? {
        guard let eid = entitlementId else { return nil }
        let url = "\(commerceBase)/users/me/internal_entitlements/\(eid)?fields=game_meta"
        guard let response = CloudHttpClient.get(url: url, headers: [
            "Authorization": "Bearer \(commerceOAuthToken ?? "")",
            "User-Agent": userAgent, "Accept": "application/json"
        ]) else { return nil }

        if response.statusCode == 200 { return true }
        if response.statusCode == 404 { return false }
        return nil
    }

    private func step0_5e3_CheckoutPreview(sessionId: String) -> Bool {
        let url = "\(kamajiBase)/user/checkout/buynow/preview"
        let sku = streamingSku ?? entitlementId ?? ""

        guard let response = CloudHttpClient.post(url: url, body: "sku=\(sku)", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": userAgent, "Accept": "application/json",
            "Authorization": "Bearer \(commerceOAuthToken ?? "")",
            "Cookie": "JSESSIONID=\(sessionId)"
        ]), response.statusCode == 200 else {
            // Checkout preview errors indicate PS Plus Premium subscription required
            return false
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any],
              let header = json["header"] as? [String: Any],
              (header["status_code"] as? String) == "0x0000",
              let data = json["data"] as? [String: Any],
              let cart = data["cart"] as? [String: Any],
              (cart["total_price_value"] as? Int) == 0 else { return false }

        // Extract actual SKU from response
        if let items = cart["items"] as? [[String: Any]],
           let first = items.first, let actualSku = first["sku_id"] as? String, !actualSku.isEmpty {
            streamingSku = actualSku
        }
        return true
    }

    private func step0_5e4_CheckoutBuynow(sessionId: String) -> Bool {
        let url = "\(kamajiBase)/user/checkout/buynow"
        let sku = streamingSku ?? entitlementId ?? ""

        guard let response = CloudHttpClient.post(url: url, body: "sku=\(sku)", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": userAgent, "Accept": "application/json",
            "Authorization": "Bearer \(commerceOAuthToken ?? "")",
            "Cookie": "JSESSIONID=\(sessionId)"
        ]), response.statusCode == 200 else { return false }

        guard let json = try? JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any],
              let header = json["header"] as? [String: Any],
              (header["status_code"] as? String) == "0x0000" else { return false }
        return true
    }
}
