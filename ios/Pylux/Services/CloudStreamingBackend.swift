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

        if normalizedServiceType == "pscloud" {
            CloudLocaleSettings.ensureConfigured(npssoToken: npssoToken)
        }

        // The C flow runs the NPSSO authorizeCheck itself as its first (silent) step
        // and returns AUTHORIZATION_FAILED if the token is expired.
        return try continueCloudSessionAfterAuth(
            serviceType: normalizedServiceType,
            gameIdentifier: gameIdentifier,
            gameName: gameName,
            npssoToken: npssoToken,
            ownedEntitlementId: ownedEntitlementId,
            ownedPlatform: ownedPlatform,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
    }

    // MARK: - Continue After Auth (unified libchiaki provisioning flow)

    /// Runs the entire Kamaji+Gaikai flow in libchiaki (chiaki_cloud_provision_session via
    /// PyluxCloudProvision). The owned fast-path and the one-shot noGameForEntitlementId
    /// fallback now live in C, so this just marshals settings in and the result/errors out.
    private func continueCloudSessionAfterAuth(
        serviceType: String,
        gameIdentifier: String,
        gameName: String,
        npssoToken: String,
        ownedEntitlementId: String = "",
        ownedPlatform: String = "",
        onProgress: ((String) -> Void)?,
        isCancelled: @escaping () -> Bool
    ) throws -> CloudStreamSession {
        let prefs = StreamPreferences.load()
        let pscloud = serviceType == "pscloud"

        // Streaming language: manual picker, else the detected catalog locale.
        let gameLanguage: String = {
            let l = prefs.cloudGameLanguage
            return l.isEmpty ? CloudLocaleSettings.stored : l
        }()
        let forcedDatacenter = pscloud ? prefs.cloudDatacenterPscloud : prefs.cloudDatacenterPsnow
        let resolution = Int32(Int(pscloud ? prefs.cloudResolutionPscloud : prefs.cloudResolutionPsnow) ?? 1080)
        let bitrate = Int32(StreamPreferences.clampCloudBitrateKbps(pscloud ? prefs.cloudBitratePscloud : prefs.cloudBitratePsnow))

        // Prior stored datacenters for this service -> the lib merges this run's pings into them
        // and returns the full list, so the Settings picker keeps previously-measured RTTs.
        let priorData = pscloud ? SecureStore.shared.pscloudDatacentersData : SecureStore.shared.psnowDatacentersData
        let priorDatacentersJson = priorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        let result = PyluxCloudProvision.provision(
            withServiceType: serviceType,
            gameIdentifier: gameIdentifier,
            gameName: gameName,
            npsso: npssoToken,
            storeCountry: SecureStore.shared.cloudResolvedStoreCountry,
            storeLang: SecureStore.shared.cloudResolvedStoreLang,
            gameLanguage: gameLanguage,
            ownedEntitlementId: ownedEntitlementId,
            ownedPlatform: ownedPlatform,
            forcedDatacenter: forcedDatacenter,
            priorDatacentersJson: priorDatacentersJson,
            catalogIsForeign: SecureStore.shared.isCloudCatalogIsForeign,
            resolution: resolution,
            bitrateKbps: bitrate,
            onProgress: { stage in onProgress?(stage) },
            isCancelled: { isCancelled() }
        )

        // Persist the merged datacenter list so Settings shows the measured RTTs
        // (whether or not allocation succeeded -- the old code saved during the ping).
        if let pings = result.datacenterPings, !pings.isEmpty,
           let data = pings.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            CloudDatacenterStore.saveDatacenters(arr, for: serviceType)
        }

        if result.err == 0 {
            os_log(.info, log: cloudLog, "✓ Cloud provisioning complete - Server: %{public}s", result.serverIp)
            return CloudStreamSession(
                serverIp: result.serverIp,
                serverPort: Int(result.serverPort),
                handshakeKey: result.handshakeKey,
                launchSpec: result.launchSpec,
                sessionId: result.sessionId,
                entitlementId: result.entitlementId,
                gameName: gameName,
                platform: result.platform,
                psnWrapperType: Int(result.psnWrapperType),
                mtuIn: Int(result.mtuIn),
                mtuOut: Int(result.mtuOut),
                rttMs: Int(result.rttMs),
                serviceType: serviceType
            )
        }

        // Map the C error_message sentinels to the error types CloudPlayView catches.
        let msg = result.errorMessage ?? "Allocation failed"
        os_log(.error, log: cloudLog, "Cloud provisioning failed: %{public}s", msg)
        if msg.contains("AUTHORIZATION_FAILED") {
            throw AuthorizationFailedError(message: "Your NPSSO token is likely expired. Please re-login.")
        } else if msg.contains("PS_PLUS_SUBSCRIPTION_REQUIRED") {
            throw PsPlusSubscriptionError(message: "PS Plus subscription required")
        } else if msg.contains("PING_TIMEOUT") {
            throw PingTimeoutError()
        } else {
            throw GaikaiAllocationError(message: msg)
        }
    }

}
