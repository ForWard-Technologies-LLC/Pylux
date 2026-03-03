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

        // Continue with session setup
        return try continueCloudSessionAfterAuth(
            serviceType: normalizedServiceType,
            gameIdentifier: gameIdentifier,
            gameName: gameName,
            npssoToken: npssoToken,
            sharedDuid: sharedDuid,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
    }

    // MARK: - Continue After Auth

    private func continueCloudSessionAfterAuth(
        serviceType: String,
        gameIdentifier: String,
        gameName: String,
        npssoToken: String,
        sharedDuid: String,
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
            let kamajiResult = kamajiSession.startSessionCreation(npssoToken: npssoToken)
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
        let allocationResult = try gaikai.startAllocationFlow(entitlementId: finalEntitlementId)
        guard allocationResult.success else {
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
