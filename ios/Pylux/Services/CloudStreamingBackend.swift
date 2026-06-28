// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud streaming orchestrator - mirrors Android CloudStreamingBackend.kt exactly

import Foundation
import os.log

private let cloudLog = OSLog(subsystem: "com.pylux.stream", category: "CloudBackend")

/// CloudStreamingBackend - Orchestrates PlayStation Plus Cloud Gaming flow
/// Mirrors: android/.../cloudplay/api/CloudStreamingBackend.kt
final class CloudStreamingBackend {

    /// Main entry point: Complete entire flow (Steps 1-13)
    /// - Parameters:
    ///   - serviceType: "psnow" or "pscloud"
    ///   - gameIdentifier: Product ID (PSNOW) or Entitlement ID (PSCLOUD)
    ///   - gameName: Display name
    ///   - npssoToken: User's NPSSO token
    ///   - onProgress: Progress callback
    ///   - isCancelled: Cancellation check
    /// - Returns: CloudStreamSession on success
    func startCompleteCloudSession(
        serviceType: String,
        gameIdentifier: String,
        gameName: String,
        npssoToken: String,
        ownedEntitlementId: String = "",  // PSNOW owned fast-path: catalog's pre-resolved entitlement
        ownedPlatform: String = "",       // platform accompanying ownedEntitlementId
        onProgress: ((String) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> CloudStreamSession {
        os_log(.info, log: cloudLog, "=== Starting Complete Cloud Streaming Session ===")
        os_log(.info, log: cloudLog, "Service Type: %{public}s", serviceType)
        os_log(.info, log: cloudLog, "Game: %{public}s (%{public}s)", gameName, gameIdentifier)

        let normalizedServiceType = serviceType.lowercased()
        guard normalizedServiceType == "psnow" || normalizedServiceType == "pscloud" else {
            throw GaikaiAllocationError(message: "Invalid serviceType: \(normalizedServiceType)")
        }

        // Generate shared DUID
        let sharedDuid = generateDuid()
        os_log(.info, log: cloudLog, "Using DUID: %{public}s", String(sharedDuid.prefix(20)))

        // Centralized authorization check (matches Qt lines 91-119)
        guard checkAuthorization(serviceType: normalizedServiceType, npssoToken: npssoToken, duid: sharedDuid) else {
            throw AuthorizationFailedError(message: "Your NPSSO token is likely expired. Please re-login.")
        }
        os_log(.info, log: cloudLog, "✓ Authorization check passed")

        if normalizedServiceType == "pscloud" {
            CloudLocaleSettings.ensureConfigured(npssoToken: npssoToken)
        }

        // Continue with session setup
        return try continueCloudSessionAfterAuth(
            serviceType: normalizedServiceType,
            gameIdentifier: gameIdentifier,
            gameName: gameName,
            npssoToken: npssoToken,
            sharedDuid: sharedDuid,
            ownedEntitlementId: ownedEntitlementId,
            ownedPlatform: ownedPlatform,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
    }

    /// True when a Gaikai allocation error means "the entitlement we streamed isn't valid/owned"
    /// (Gaikai's session-start reports {"name":"noGameForEntitlementId",...}). Signals the owned
    /// fast-path guessed wrong and we should retry with the full resolve/acquire flow.
    private func isEntitlementRejectedError(_ message: String) -> Bool {
        message.range(of: "noGameForEntitlement", options: .caseInsensitive) != nil
    }

    // MARK: - Continue After Auth

    private func continueCloudSessionAfterAuth(
        serviceType: String,
        gameIdentifier: String,
        gameName: String,
        npssoToken: String,
        sharedDuid: String,
        ownedEntitlementId: String = "",
        ownedPlatform: String = "",
        forceFullEntitlementFlow: Bool = false,  // true on the one-shot fallback retry (disables fast-path)
        onProgress: ((String) -> Void)?,
        isCancelled: @escaping () -> Bool
    ) throws -> CloudStreamSession {
        let redirectUri: String
        let userAgent: String

        if serviceType == "pscloud" {
            redirectUri = CloudApiConstants.gaikaiRedirectUri
            userAgent = CloudApiConstants.gaikaiUserAgent
        } else {
            redirectUri = CloudApiConstants.kamajiRedirectUri
            userAgent = CloudApiConstants.kamajiUserAgent
        }

        let initialPlatform = serviceType == "pscloud" ? "ps5" : "ps4"
        var finalEntitlementId = gameIdentifier
        var finalPlatform = initialPlatform
        var usedFastPath = false

        // For PSNOW: Kamaji session (converts productId -> entitlementId)
        // For PSCLOUD: Skip Kamaji entirely
        if serviceType == "psnow" {
            os_log(.info, log: cloudLog, "=== PSNOW Flow: Starting Kamaji Session ===")
            let kamajiSession = PSKamajiSession(
                duid: sharedDuid,
                productId: gameIdentifier,
                accountBaseUrl: CloudApiConstants.accountBase,
                redirectUri: redirectUri,
                userAgent: userAgent
            )
            // Owned-PSNOW fast-path: if the catalog already resolved this title's streaming
            // entitlement (owned), hand it to Kamaji so it skips the resolve/acquire path.
            // Disabled on the fallback retry (forceFullEntitlementFlow).
            if !forceFullEntitlementFlow && !ownedEntitlementId.isEmpty {
                os_log(.info, log: cloudLog, "PSNOW owned fast-path: catalog entitlementId=%{public}s platform=%{public}s",
                       ownedEntitlementId, ownedPlatform)
                kamajiSession.setOwnedEntitlementFastPath(ownedEntitlementId: ownedEntitlementId, ownedPlatform: ownedPlatform)
            } else if forceFullEntitlementFlow {
                os_log(.info, log: cloudLog, "PSNOW: forcing full entitlement flow (fast-path retry fallback)")
            }
            let kamajiResult = kamajiSession.startSessionCreation(npssoToken: npssoToken)
            usedFastPath = kamajiSession.usedEntitlementFastPath
            guard kamajiResult.success else {
                throw KamajiSessionError(message: "Kamaji session failed: \(kamajiResult.message)")
            }
            finalEntitlementId = kamajiResult.entitlementId
            finalPlatform = kamajiResult.platform
            os_log(.info, log: cloudLog, "✓ Kamaji: entitlement=%{public}s platform=%{public}s",
                   finalEntitlementId, finalPlatform)
        } else {
            os_log(.info, log: cloudLog, "=== PSCLOUD Flow: Skipping Kamaji ===")
        }

        // Gaikai allocation (Steps 0-13)
        os_log(.info, log: cloudLog, "=== Starting Gaikai Allocation ===")
        let gaikai = PSGaikaiStreaming(
            duid: sharedDuid,
            serviceType: serviceType,
            platform: finalPlatform,
            npssoToken: npssoToken,
            onProgress: onProgress,
            isCancelled: isCancelled
        )

        // Owned fast-path fallback: if Gaikai rejects a catalog entitlement (it isn't actually
        // valid/owned), retry exactly once via the full resolve/acquire flow. One shot only --
        // forceFullEntitlementFlow disables the fast-path on the retry -- so it can never loop.
        // Gaikai reports this both by throwing GaikaiAllocationError (session start) and via a
        // success=false result, so handle both.
        func retryFullFlow() throws -> CloudStreamSession {
            os_log(.error, log: cloudLog, "Owned fast-path entitlement rejected by Gaikai; retrying once with the full entitlement flow")
            return try continueCloudSessionAfterAuth(
                serviceType: serviceType, gameIdentifier: gameIdentifier, gameName: gameName,
                npssoToken: npssoToken, sharedDuid: sharedDuid,
                ownedEntitlementId: "", ownedPlatform: "", forceFullEntitlementFlow: true,
                onProgress: onProgress, isCancelled: isCancelled
            )
        }

        let allocationResult: GaikaiAllocationResult
        do {
            allocationResult = try gaikai.startAllocationFlow(entitlementId: finalEntitlementId)
        } catch let error as GaikaiAllocationError {
            if usedFastPath && !forceFullEntitlementFlow && isEntitlementRejectedError(error.message) {
                return try retryFullFlow()
            }
            throw error
        }
        guard allocationResult.success else {
            if usedFastPath && !forceFullEntitlementFlow && isEntitlementRejectedError(allocationResult.message) {
                return try retryFullFlow()
            }
            throw GaikaiAllocationError(message: "Gaikai allocation failed: \(allocationResult.message)")
        }

        os_log(.info, log: cloudLog, "✓ Gaikai allocation complete - Server: %{public}s", allocationResult.serverIp)

        return CloudStreamSession(
            serverIp: allocationResult.serverIp,
            serverPort: allocationResult.serverPort,
            handshakeKey: allocationResult.handshakeKey,
            launchSpec: allocationResult.launchSpec,
            sessionId: allocationResult.sessionId,
            entitlementId: finalEntitlementId,
            gameName: gameName,
            platform: finalPlatform,
            psnWrapperType: allocationResult.psnWrapperType,
            mtuIn: allocationResult.mtuIn,
            mtuOut: allocationResult.mtuOut,
            rttMs: allocationResult.rttMs,
            serviceType: serviceType
        )
    }

    // MARK: - Authorization Check (matches Qt lines 543-613)

    private func checkAuthorization(serviceType: String, npssoToken: String, duid: String) -> Bool {
        guard !npssoToken.isEmpty else { return false }

        let kamajiClientId: String
        let scopesStr: String
        let redirectUri: String
        let userAgent: String

        if serviceType == "psnow" {
            kamajiClientId = CloudApiConstants.kamajiClientId
            scopesStr = CloudApiConstants.ps4Scopes
            redirectUri = CloudApiConstants.kamajiRedirectUri
            userAgent = CloudApiConstants.kamajiUserAgent
        } else {
            kamajiClientId = "19ae39c4-3f88-4d11-a792-94e4f52c996d"
            scopesStr = "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s"
            redirectUri = CloudApiConstants.gaikaiRedirectUri
            userAgent = CloudApiConstants.gaikaiUserAgent
        }

        let url = "\(CloudApiConstants.accountBase)/authz/v3/oauth/authorizeCheck"
        let body: [String: Any] = [
            "client_id": kamajiClientId, "scope": scopesStr,
            "redirect_uri": redirectUri, "response_type": "code",
            "service_entity": "urn:service-entity:psn", "duid": duid
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyStr = String(data: bodyData, encoding: .utf8),
              let response = CloudHttpClient.post(url: url, body: bodyStr, headers: [
                  "Content-Type": "application/json; charset=UTF-8",
                  "User-Agent": userAgent,
                  "Cookie": "npsso=\(npssoToken)"
              ]) else { return false }

        return response.statusCode == 200 || response.statusCode == 204
    }

    // MARK: - DUID Generation (matches Android DuidUtil)

    private func generateDuid() -> String {
        let prefix = "0000000700410080"
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        return prefix + randomBytes.map { String(format: "%02x", $0) }.joined()
    }
}
