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

        // The store locale is resolved + persisted by the unified catalog fetch
        // (settledLocale -> cloud_store_locale); the streaming-language fallback reads
        // it. The C flow runs the NPSSO authorizeCheck itself as its first (silent)
        // step and returns AUTHORIZATION_FAILED if the token is expired.
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

        // Store country/language: fall back to the store locale (de-DE -> DE/de) when the
        // server-authoritative values are empty, so non-English native stores don't 404 on US/en.
        let (localeCountry, localeLang) = CloudLocaleSettings.parseStorePath(CloudLocaleSettings.stored)
        let resolvedCountry = SecureStore.shared.cloudResolvedStoreCountry
        let resolvedLang = SecureStore.shared.cloudResolvedStoreLang
        let storeCountry = resolvedCountry.isEmpty ? localeCountry : resolvedCountry
        let storeLang = resolvedLang.isEmpty ? localeLang : resolvedLang

        let result = PyluxCloudProvision.provision(
            withServiceType: serviceType,
            gameIdentifier: gameIdentifier,
            gameName: gameName,
            npsso: npssoToken,
            storeCountry: storeCountry,
            storeLang: storeLang,
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
        } else if msg.contains("ACCOUNT_PRIVACY_SETTINGS") {
            // Sentinel is "ACCOUNT_PRIVACY_SETTINGS:<upgrade-url>" (URL may be absent).
            // Parse defensively -- any missing/garbage URL degrades to an empty string,
            // and the error surfaces through CloudPlayView's generic catch -> alert
            // (no dedicated dialog needed). This path is untested live; keep it total.
            let prefix = "ACCOUNT_PRIVACY_SETTINGS:"
            var upgradeUrl = ""
            if let r = msg.range(of: prefix) {
                upgradeUrl = String(msg[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw AccountPrivacySettingsError(upgradeUrl: upgradeUrl)
        } else if msg.contains("GAME_NOT_FREE") {
            // Stale catalog: a free PS+ title now costs money. Sentinel is
            // "GAME_NOT_FREE:<price>" (price may be empty). Parse defensively.
            var price = ""
            if let r = msg.range(of: "GAME_NOT_FREE:") {
                price = String(msg[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw GameNotFreeError(price: price)
        } else if msg.contains("PING_TIMEOUT") {
            throw PingTimeoutError()
        } else {
            throw GaikaiAllocationError(message: msg)
        }
    }

}
