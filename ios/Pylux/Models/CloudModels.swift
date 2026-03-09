// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud gaming models matching Android's cloudplay/model/ package exactly

import Foundation

// MARK: - CloudGame (matches Android CloudGame.kt)

/// Represents a game in the cloud catalog (PSNow or PSCloud)
struct CloudGame: Identifiable, Hashable {
    let id: String           // productId
    let name: String
    let imageUrl: String     // Cover/box art (type 10)
    let landscapeImageUrl: String  // Landscape (type 12/13)
    let platform: String     // "ps4", "ps3", or "ps5"
    let serviceType: String  // "psnow" or "pscloud"
    let conceptUrl: String   // URL to add game to library (PS5)
    var isOwned: Bool        // Whether user owns this game (PS5)

    init(productId: String, name: String, imageUrl: String, landscapeImageUrl: String = "",
         platform: String = "ps4", serviceType: String = "psnow",
         conceptUrl: String = "", isOwned: Bool = false) {
        self.id = productId
        self.name = name
        self.imageUrl = imageUrl
        self.landscapeImageUrl = landscapeImageUrl.isEmpty ? imageUrl : landscapeImageUrl
        self.platform = platform
        self.serviceType = serviceType
        self.conceptUrl = conceptUrl
        self.isOwned = isOwned
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

/// Ping timeout (RTT > 80ms)
struct PingTimeoutError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
