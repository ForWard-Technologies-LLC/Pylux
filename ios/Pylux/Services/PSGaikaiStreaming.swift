// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Gaikai streaming allocation flow (Steps 0-13) - mirrors Android PSGaikaiStreaming.kt exactly

import Foundation
import os.log

private let gkLog = OSLog(subsystem: "com.pylux.stream", category: "Gaikai")

/// PSGaikaiStreaming - Complete Gaikai streaming allocation flow (Steps 0-13)
/// Mirrors: android/.../cloudplay/api/PSGaikaiStreaming.kt
final class PSGaikaiStreaming {
    private let duid: String
    private let serviceType: String   // "psnow" or "pscloud"
    private let platform: String      // "ps3", "ps4", or "ps5"
    private let npssoToken: String
    private let onProgress: ((String) -> Void)?
    private let isCancelled: () -> Bool

    // Derived configuration
    private let virtType: String
    private let redirectUri: String
    private let userAgent: String
    private let oauthApiPath: String

    // State
    private var configKey = ""
    private var gaikaiSessionId = ""
    private var gkClientId = ""
    private var ps3GkClientId = ""
    private var streamServerClientId = ""
    private var gkCloudAuthCode = ""
    private var ps3AuthCode = ""
    private var streamServerAuthCode = ""
    private var requestGameSpec: [String: Any] = [:]
    private var selectedDatacenter = ""
    private var selectedDatacenterPort = 0
    private var selectedDatacenterPingResult: [String: Any] = [:]

    // Allocation polling
    private static let maxAllocationWaitSeconds = 900  // 15 min
    private static let defaultAllocationWaitSeconds = 300  // 5 min
    private static let maxLockSessionRetries = 12
    private var allocationWaitStartTime: TimeInterval = 0
    private var allocationMaxWaitSeconds = 0
    private var allocationRetryCount = 0
    private var lockSessionRetryCount = 0

    init(duid: String, serviceType: String, platform: String, npssoToken: String,
         onProgress: ((String) -> Void)? = nil, isCancelled: @escaping () -> Bool = { false }) {
        self.duid = duid
        self.serviceType = serviceType
        self.platform = platform
        self.npssoToken = npssoToken
        self.onProgress = onProgress
        self.isCancelled = isCancelled

        switch platform {
        case "ps3": self.virtType = "konan"
        case "ps5": self.virtType = "cronos"
        default:    self.virtType = "kratos"
        }

        if serviceType == "pscloud" {
            redirectUri = CloudApiConstants.gaikaiRedirectUri
            userAgent = CloudApiConstants.gaikaiUserAgent
            oauthApiPath = "/api/authz/v3"
        } else {
            redirectUri = CloudApiConstants.kamajiRedirectUri
            userAgent = CloudApiConstants.kamajiUserAgent
            oauthApiPath = "/api/v1"
        }
    }

    // MARK: - Main Entry Point

    func startAllocationFlow(entitlementId: String) throws -> GaikaiAllocationResult {
        os_log(.info, log: gkLog, "=== Starting Gaikai Allocation Flow ===")
        os_log(.info, log: gkLog, "Entitlement ID: %{public}s", entitlementId)

        do {
            // Step 0: Get client IDs
            onProgress?("Getting Client IDs - Step 1 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step0_GetClientIds()
            os_log(.info, log: gkLog, "✓ Step 0: Got client IDs")

            // Step 7: Get config
            onProgress?("Getting Configuration - Step 2 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step7_GetConfig()
            os_log(.info, log: gkLog, "✓ Step 7: Got config")

            // Step 8: Start session
            onProgress?("Starting Session - Step 3 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step8_StartSession(entitlementId: entitlementId)
            os_log(.info, log: gkLog, "✓ Step 8: Started session")

            // Step 8a: Get gkClientId auth code
            onProgress?("Getting Tokens - Step 4 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step8a_GetAuthCode()
            os_log(.info, log: gkLog, "✓ Step 8a: Got gkClientId auth code")

            // Step 8b: Get server auth code
            onProgress?("Getting Server Tokens - Step 5 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step8b_GetServerAuthCode()
            os_log(.info, log: gkLog, "✓ Step 8b: Got server auth code")

            // Step 9: Authorize session
            onProgress?("Authorizing Session - Step 6 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step9_AuthorizeSession()
            os_log(.info, log: gkLog, "✓ Step 9: Authorized session")

            // Step 10: Lock session
            onProgress?("Locking Session - Step 7 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            try step10_LockSession()
            os_log(.info, log: gkLog, "✓ Step 10: Locked session")

            // Step 11: Get datacenters
            onProgress?("Getting Datacenters - Step 8 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            let datacenters = try step11_GetDatacenters()
            os_log(.info, log: gkLog, "✓ Step 11: Got %d datacenters", datacenters.count)

            // Step 12: Select datacenter
            onProgress?("Selecting Datacenter - Step 9 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            let dcName = try step12_SelectDatacenter(datacenters: datacenters)
            onProgress?("Selecting Datacenter (\(dcName)) - Step 9 of 10")
            os_log(.info, log: gkLog, "✓ Step 12: Selected datacenter: %{public}s", dcName)

            // Step 13: Allocate slot
            onProgress?("Allocating Streaming Slot - Step 10 of 10")
            guard !isCancelled() else { return .init(success: false, message: "Cancelled") }
            let allocation = try step13_AllocateSlot()

            // Parse allocation response
            guard let launchSlot = allocation["launchSlot"] as? [String: Any] else {
                return .init(success: false, message: "Allocation response missing launchSlot")
            }

            let serverIp = launchSlot["publicIp"] as? String ?? ""
            let serverPort = launchSlot["port"] as? Int ?? 0
            let privateIp = launchSlot["privateIp"] as? String ?? ""
            let handshakeKey = allocation["handshakeKey"] as? String ?? ""
            let launchSpec = allocation["launchSpecification"] as? String ?? ""
            let sessionId = allocation["sessionId"] as? String ?? ""

            guard !serverIp.isEmpty, serverPort != 0, !launchSpec.isEmpty else {
                return .init(success: false, message: "Allocation response incomplete")
            }

            // PSN wrapper type from private IP last octet
            var psnWrapperType = 0x01
            if !privateIp.isEmpty, let lastOctet = privateIp.split(separator: ".").last,
               let octet = Int(lastOctet), (0...255).contains(octet) {
                psnWrapperType = octet
            }

            os_log(.info, log: gkLog, "=== ALLOCATION SUCCESSFUL ===")
            os_log(.info, log: gkLog, "Server: %{public}s:%d", serverIp, serverPort)
            os_log(.info, log: gkLog, "Session ID: %{public}s", sessionId)
            os_log(.info, log: gkLog, "PSN Wrapper Type: 0x%02x", psnWrapperType)

            return GaikaiAllocationResult(
                success: true, message: "Success",
                serverIp: serverIp, serverPort: serverPort,
                handshakeKey: handshakeKey, launchSpec: launchSpec,
                sessionId: sessionId, psnWrapperType: psnWrapperType,
                mtuIn: selectedDatacenterPingResult["mtu_in"] as? Int ?? 1454,
                mtuOut: selectedDatacenterPingResult["mtu_out"] as? Int ?? 1254,
                rttMs: selectedDatacenterPingResult["rtt"] as? Int ?? 20
            )
        } catch let error as PsPlusSubscriptionError {
            throw error
        } catch let error as PingTimeoutError {
            throw error
        } catch let error as GaikaiAllocationError {
            throw error
        } catch {
            os_log(.error, log: gkLog, "Gaikai allocation error: %{public}s", error.localizedDescription)
            return .init(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Step 0: Get Client IDs

    private func step0_GetClientIds() throws {
        let url = "\(CloudApiConstants.gaikaiBase)/client_ids?virtType=\(virtType)"
        guard let response = CloudHttpClient.get(url: url, headers: [
            "User-Agent": userAgent, "Accept": "*/*"
        ]), response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Failed to get client IDs")
        }

        guard let json = parseJSON(response.body),
              let gk = json["gkClientId"] as? String, !gk.isEmpty else {
            throw GaikaiAllocationError(message: "No gkClientId in response")
        }
        gkClientId = gk
        ps3GkClientId = json["ps3GkClientId"] as? String ?? ""
        streamServerClientId = json["streamServerClientId"] as? String ?? ""
        os_log(.info, log: gkLog, "Step 0: gkClientId=%{public}s", gkClientId)
    }

    // MARK: - Step 7: Get Config

    private func step7_GetConfig() throws {
        let url = "\(CloudApiConstants.configBase)/config"
        var body: [String: Any] = ["sessionId": ""]
        if serviceType == "pscloud" {
            body["product"] = "qlite"; body["platform"] = "qlite"
        } else {
            body["product"] = "psnow"; body["platform"] = "PC"
        }
        let bodyStr = jsonString(body)

        guard let response = CloudHttpClient.post(url: url, body: bodyStr, headers: [
            "Content-Type": "application/json", "User-Agent": userAgent, "Accept": "*/*"
        ]), response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Failed to get config")
        }

        guard let json = parseJSON(response.body),
              let key = json["configKey"] as? String, !key.isEmpty else {
            throw GaikaiAllocationError(message: "No configKey in response")
        }
        configKey = key
    }

    // MARK: - Step 8: Start Session

    private func step8_StartSession(entitlementId: String) throws {
        let url = "\(CloudApiConstants.gaikaiBase)/sessions/start?npEnv=np"
        requestGameSpec = buildRequestGameSpec(entitlementId: entitlementId)
        let wrapper: [String: Any] = ["requestGameSpecification": requestGameSpec]
        let bodyStr = jsonString(wrapper)

        guard let response = CloudHttpClient.post(url: url, body: bodyStr, headers: [
            "Content-Type": "application/json", "User-Agent": userAgent,
            "Accept": "application/json", "X-Gaikai-Session": configKey
        ]), response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Failed to start session")
        }

        if let newKey = response.header("x-gaikai-session") ?? response.header("X-Gaikai-Session"),
           !newKey.isEmpty { configKey = newKey }

        guard let json = parseJSON(response.body),
              let sid = json["sessionId"] as? String, !sid.isEmpty else {
            throw GaikaiAllocationError(message: "No sessionId in response")
        }
        gaikaiSessionId = sid
        os_log(.info, log: gkLog, "Step 8: Session ID: %{public}s", gaikaiSessionId)
    }

    // MARK: - Step 8a: Get gkClientId Auth Code

    private func step8a_GetAuthCode() throws {
        var params: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", gkClientId),
            ("redirect_uri", redirectUri),
            ("service_entity", "urn:service-entity:psn"),
            ("prompt", "none"),
            ("duid", duid)
        ]
        if serviceType == "pscloud" {
            params += [("smcid", "qlite"), ("applicationId", "qlite"), ("mid", "qlite"),
                       ("scope", "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s")]
        } else {
            params += [("smcid", "pc:psnow"), ("applicationId", "psnow"), ("mid", "PSNOW"),
                       ("scope", "kamaji:commerce_native versa:user_update_entitlements_first_play kamaji:lists"),
                       ("renderMode", "mobilePortrait"), ("hidePageElements", "forgotPasswordLink"),
                       ("displayFooter", "none"), ("disableLinks", "qriocityLink"),
                       ("layout_type", "popup"), ("service_logo", "ps"), ("tp_psn", "true"), ("noEVBlock", "true")]
        }

        let code = try getOAuthCode(params: params)
        gkCloudAuthCode = code
        os_log(.info, log: gkLog, "Step 8a: Got gkCloudAuthCode")
    }

    // MARK: - Step 8b: Get Server Auth Code

    private func step8b_GetServerAuthCode() throws {
        var params: [(String, String)] = [
            ("response_type", "code"),
            ("redirect_uri", redirectUri),
            ("service_entity", "urn:service-entity:psn"),
            ("prompt", "none")
        ]
        if serviceType == "pscloud" {
            params += [("client_id", streamServerClientId), ("smcid", "qlite"),
                       ("applicationId", "qlite"), ("mid", "qlite"),
                       ("scope", "id_token:duid id_token:online_id openid oauth:create_authn_ticket_for_cloud_console_signin"),
                       ("duid", duid)]
        } else {
            params.append(("client_id", ps3GkClientId))
            params += [("smcid", "pc:psnow"), ("applicationId", "psnow"), ("mid", "PSNOW")]
            if platform == "ps3" {
                params.append(("scope", "kamaji:commerce_native"))
            } else {
                params += [("scope", "sso:none"), ("duid", duid)]
            }
            params += [("renderMode", "mobilePortrait"), ("hidePageElements", "forgotPasswordLink"),
                       ("displayFooter", "none"), ("disableLinks", "qriocityLink"),
                       ("layout_type", "popup"), ("service_logo", "ps"), ("tp_psn", "true"), ("noEVBlock", "true")]
        }

        let code = try getOAuthCode(params: params)
        if serviceType == "pscloud" {
            streamServerAuthCode = code; ps3AuthCode = ""
        } else {
            ps3AuthCode = code; streamServerAuthCode = code
        }
    }

    // MARK: - Step 9: Authorize Session

    private func step9_AuthorizeSession() throws {
        let url = "\(CloudApiConstants.gaikaiBase)/sessions/\(gaikaiSessionId)/authorize"
        requestGameSpec["gkCloudAuthCode"] = gkCloudAuthCode
        requestGameSpec["ps3AuthCode"] = ps3AuthCode
        requestGameSpec["streamServerAuthCode"] = streamServerAuthCode

        let body = jsonString(["requestGameSpecification": requestGameSpec])
        guard let response = CloudHttpClient.post(url: url, body: body, headers: gaikaiHeaders()) else {
            throw GaikaiAllocationError(message: "Authorize session request failed")
        }

        if response.statusCode != 200 {
            // Check for PS Plus subscription error (eventCode 002.2001)
            var isPSPlusError = false
            if let bodyJson = parseJSON(response.body),
               let errors = bodyJson["errors"] as? [[String: Any]] {
                for errorObj in errors {
                    if (errorObj["eventCode"] as? String) == "002.2001" { isPSPlusError = true }
                }
            }
            if isPSPlusError {
                throw PsPlusSubscriptionError(message: "PlayStation Plus Premium subscription is required to stream this game")
            }
            throw GaikaiAllocationError(message: "Authorize failed: HTTP \(response.statusCode)")
        }

        if let newKey = response.header("x-gaikai-session"), !newKey.isEmpty { configKey = newKey }
    }

    // MARK: - Step 10: Lock Session (with retry)

    private func step10_LockSession() throws {
        os_log(.info, log: gkLog, "Step 10: Locking session (attempt %d)", lockSessionRetryCount + 1)
        let url = "\(CloudApiConstants.gaikaiBase)/sessions/\(gaikaiSessionId)/lock?forceLogout=true"
        let body = jsonString(["requestGameSpecification": requestGameSpec])

        guard let response = CloudHttpClient.post(url: url, body: body, headers: gaikaiHeaders()),
              response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Lock session failed")
        }

        if let newKey = response.header("x-gaikai-session"), !newKey.isEmpty { configKey = newKey }

        guard let json = parseJSON(response.body) else {
            throw GaikaiAllocationError(message: "Lock session: invalid response")
        }

        let lockAcquired = json["lockAcquired"] as? Bool ?? false
        let pollFrequency = json["pollFrequency"] as? Int ?? 10

        if !lockAcquired {
            lockSessionRetryCount += 1
            if lockSessionRetryCount > Self.maxLockSessionRetries {
                throw GaikaiAllocationError(message: "Could not acquire lock after \(Self.maxLockSessionRetries) attempts")
            }
            let msg = "Closing old session - Attempt \(lockSessionRetryCount)"
            onProgress?(msg)
            os_log(.info, log: gkLog, "%{public}s", msg)
            guard !isCancelled() else { return }
            Thread.sleep(forTimeInterval: TimeInterval(pollFrequency))
            try step10_LockSession() // Retry
            return
        }
        lockSessionRetryCount = 0
    }

    // MARK: - Step 11: Get Datacenters

    private func step11_GetDatacenters() throws -> [[String: Any]] {
        let url = "\(CloudApiConstants.gaikaiBase)/sessions/\(gaikaiSessionId)/datacenters"
        let body = jsonString(["requestGameSpecification": requestGameSpec])

        guard let response = CloudHttpClient.post(url: url, body: body, headers: gaikaiHeaders()),
              response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Failed to get datacenters")
        }

        if let newKey = response.header("x-gaikai-session"), !newKey.isEmpty { configKey = newKey }

        guard let arr = parseJSONArray(response.body) else {
            throw GaikaiAllocationError(message: "Invalid datacenters response")
        }

        for dc in arr {
            os_log(.info, log: gkLog, "  DC: %{public}s %{public}s:%d",
                   dc["dataCenter"] as? String ?? "", dc["publicIp"] as? String ?? "", dc["port"] as? Int ?? 0)
        }

        // Save datacenter list to UserDefaults for Settings dropdown
        // (matches Android cloud_datacenters_json_pscloud / cloud_datacenters_json_psnow)
        let dcListForStore = arr.map { dc -> [String: Any] in
            ["dataCenter": dc["dataCenter"] as? String ?? "",
             "rtt": 20,  // dummy RTT until senkusha is bridged
             "port": dc["port"] as? Int ?? 0,
             "publicIp": dc["publicIp"] as? String ?? ""]
        }
        CloudDatacenterStore.saveDatacenters(dcListForStore, for: serviceType)

        return arr
    }

    // MARK: - Step 12: Select Datacenter

    private func step12_SelectDatacenter(datacenters: [[String: Any]]) throws -> String {
        guard !datacenters.isEmpty else { throw GaikaiAllocationError(message: "No datacenters available") }

        // Check user's datacenter preference (matches Android cloud_datacenter_pscloud/psnow)
        let prefs = StreamPreferences.load()
        let userChoice = serviceType == "pscloud" ? prefs.cloudDatacenterPscloud : prefs.cloudDatacenterPsnow

        // Find the selected datacenter (or fall back to first if "Auto" or not found)
        let targetDc: [String: Any]
        if userChoice != "Auto",
           let userDc = datacenters.first(where: { ($0["dataCenter"] as? String) == userChoice }) {
            targetDc = userDc
            os_log(.info, log: gkLog, "Step 12: Using user-selected datacenter: %{public}s", userChoice)
        } else {
            targetDc = datacenters[0]
            os_log(.info, log: gkLog, "Step 12: Using auto (first) datacenter: %{public}s",
                   targetDc["dataCenter"] as? String ?? "")
        }

        let dcName = targetDc["dataCenter"] as? String ?? ""
        // TODO: Replace dummy ping values with native senkusha ping results
        let pingResult: [String: Any] = [
            "dataCenter": dcName,
            "rtt": 20, "rtts": [20],
            "mtu_in": 1454, "mtu_out": 1254,
            "port": targetDc["port"] as? Int ?? 0,
            "publicIp": targetDc["publicIp"] as? String ?? "",
            "maxBandwidth": targetDc["maxBandwidth"] as? Int ?? 0
        ]

        return try submitDatacenterSelection(pingResult: pingResult, validatePing: false)
    }

    private func submitDatacenterSelection(pingResult: [String: Any], validatePing: Bool) throws -> String {
        let dcName = pingResult["dataCenter"] as? String ?? ""
        let rtt = pingResult["rtt"] as? Int ?? 0

        if validatePing && rtt > 80 {
            throw PingTimeoutError(message: "Ping must be < 80ms. \(dcName) has \(rtt)ms latency.")
        }

        selectedDatacenterPingResult = pingResult
        selectedDatacenter = dcName
        selectedDatacenterPort = pingResult["port"] as? Int ?? 0

        let url = "\(CloudApiConstants.gaikaiBase)/sessions/\(gaikaiSessionId)/datacenters/select"
        let body = jsonString([
            "requestGameSpecification": requestGameSpec,
            "pingResults": [pingResult]
        ])

        guard let response = CloudHttpClient.post(url: url, body: body, headers: gaikaiHeaders()),
              response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Datacenter selection failed")
        }

        if let newKey = response.header("x-gaikai-session"), !newKey.isEmpty { configKey = newKey }

        // Extract port from response if provided
        if let json = parseJSON(response.body), let port = json["port"] as? Int, port > 0 {
            selectedDatacenterPort = port
        }

        os_log(.info, log: gkLog, "Step 12: Selected %{public}s:%d", dcName, selectedDatacenterPort)
        return dcName
    }

    // MARK: - Step 13: Allocate Slot (with retry)

    private func step13_AllocateSlot() throws -> [String: Any] {
        let url = "\(CloudApiConstants.gaikaiBase)/sessions/\(gaikaiSessionId)/allocate"
        let network: [String: Any] = [
            "bwKbpsSent": 50000, "bwLoss": 0.001,
            "mtu": selectedDatacenterPingResult["mtu_in"] as? Int ?? 1454,
            "rtt": selectedDatacenterPingResult["rtt"] as? Int ?? 25,
            "port": selectedDatacenterPort,
            "bwKbpsReceived": 200000, "bwLossUpstream": 0,
            "mtuUpstream": selectedDatacenterPingResult["mtu_out"] as? Int ?? 1254
        ]

        let body = jsonString([
            "requestGameSpecification": requestGameSpec,
            "dataCenter": selectedDatacenter,
            "network": network,
            "stateExecutionTime": 5974.7632,
            "streamTestTime": 11262.8423
        ])

        guard let response = CloudHttpClient.post(url: url, body: body, headers: gaikaiHeaders()),
              response.statusCode == 200 else {
            throw GaikaiAllocationError(message: "Allocation failed")
        }

        if let newKey = response.header("x-gaikai-session"), !newKey.isEmpty { configKey = newKey }

        guard let allocation = parseJSON(response.body) else {
            throw GaikaiAllocationError(message: "Invalid allocation response")
        }

        // Check if queued or data migration
        let queued = allocation["queued"] as? Bool ?? false
        let dataMigration = allocation["dataMigration"] as? Bool ?? false
        let pollFrequency = allocation["pollFrequency"] as? Int ?? 15

        if queued || dataMigration {
            allocationRetryCount += 1
            if allocationWaitStartTime == 0 {
                allocationWaitStartTime = Date().timeIntervalSince1970
                let waitEstimate = allocation["waitTimeEstimate"] as? Int ?? -1
                allocationMaxWaitSeconds = waitEstimate > 0
                    ? min(waitEstimate * 2, Self.maxAllocationWaitSeconds)
                    : Self.defaultAllocationWaitSeconds
            }

            let elapsed = Int(Date().timeIntervalSince1970 - allocationWaitStartTime)
            if elapsed >= allocationMaxWaitSeconds {
                throw GaikaiAllocationError(message: "Allocation wait timeout after \(elapsed)s")
            }

            let msg: String
            if dataMigration {
                let pct = allocation["dataMigrationPercentageComplete"] as? Int ?? 0
                msg = "Migrating data (\(pct)%) - Attempt \(allocationRetryCount)"
            } else {
                let qPos = allocation["displayQueuePosition"] as? Int ?? allocation["queuePosition"] as? Int ?? -1
                msg = qPos >= 0
                    ? "Queue position: \(qPos) - Attempt \(allocationRetryCount)"
                    : "Allocating streaming slot - Attempt \(allocationRetryCount)"
            }
            onProgress?(msg)
            os_log(.info, log: gkLog, "%{public}s", msg)

            guard !isCancelled() else { throw GaikaiAllocationError(message: "Cancelled") }
            Thread.sleep(forTimeInterval: TimeInterval(pollFrequency))
            return try step13_AllocateSlot() // Retry
        }

        allocationRetryCount = 0
        os_log(.info, log: gkLog, "✓ Slot allocated!")
        return allocation
    }

    // MARK: - Build Request Game Spec

    private func buildRequestGameSpec(entitlementId: String) -> [String: Any] {
        var spec: [String: Any] = [:]

        // Timezone
        let tz = TimeZone.current
        let offset = tz.secondsFromGMT()
        let hours = offset / 3600
        let minutes = abs((offset % 3600) / 60)
        let tzStr = hours >= 0 ? String(format: "UTC+%02d:%02d", hours, minutes)
                               : String(format: "UTC-%02d:%02d", abs(hours), minutes)

        // Common fields
        spec["entitlementId"] = entitlementId
        spec["npEnv"] = "np"
        spec["language"] = "en-US"
        spec["cloudEndpoint"] = "https://cc.prod.gaikai.com"
        spec["redirectUri"] = redirectUri

        // Resolution from settings (matches Android cloud_resolution_pscloud / cloud_resolution_psnow)
        let cloudPrefs = StreamPreferences.load()
        let cloudRes: (width: Int, height: Int)
        let resSetting: String
        if serviceType == "pscloud" {
            cloudRes = cloudPrefs.cloudResolutionDimensionsPscloud
            resSetting = cloudPrefs.cloudResolutionPscloud
        } else {
            cloudRes = cloudPrefs.cloudResolutionDimensionsPsnow
            resSetting = cloudPrefs.cloudResolutionPsnow
        }
        spec["resolutionSetting"] = resSetting
        spec["clientWidth"] = cloudRes.width
        spec["clientHeight"] = cloudRes.height
        spec["adaptiveStreamMode"] = "resize"
        spec["useClientBwLadder"] = true

        // Audio upload
        spec["audioUploadEnabled"] = true
        spec["audioUploadNumChannels"] = 1
        spec["audioUploadSamplingFrequency"] = 48000

        // Input
        spec["acceptButton"] = "X"
        spec["encryptionSupported"] = true
        spec["summerTime"] = 0
        spec["timeZone"] = tzStr
        spec["httpUserAgent"] = userAgent
        spec["gkCloudAuthCode"] = gkCloudAuthCode

        // Accessibility
        spec["accessibilityMarqueeSpeed"] = 0
        spec["accessibilityLargeText"] = 0
        spec["accessibilityBoldText"] = 0
        spec["accessibilityContrast"] = 0
        spec["accessibilityTtsEnable"] = 0
        spec["accessibilityTtsSpeed"] = 0
        spec["accessibilityTtsVolume"] = 0

        // Capabilities
        spec["partyCapability"] = false
        spec["homesharing"] = false
        spec["isFirstBoot"] = false
        spec["isPlusMember"] = true
        spec["parentalLevel"] = 0
        spec["yuvCoefficient"] = ""

        var caps = ["cloudDrivenSenkushaTest"]

        if serviceType == "pscloud" {
            spec["videoEncoderProfile"] = "hw5.0"
            spec["connectedControllers"] = ["ds4", "ds5", "xinput"]
            spec["input"] = ["controllers": ["ds4", "ds5", "xinput"]]
            spec["model"] = "portal"
            spec["platform"] = "qlite"
            spec["gaikaiPlayer"] = "16.4.0"
            spec["protocolVersion"] = 12
            spec["ps3AuthCode"] = ""
            spec["streamServerAuthCode"] = streamServerAuthCode
            caps.append("cronos")

            let maxRes = Int(resSetting) ?? 1080
            spec["videoStreamSettings"] = [
                "clientHeight": cloudRes.height,
                "supportedMaxResolution": maxRes,
                "supportedVideoEncoderProfiles": ["hevc_hw4"],
                "supportedDynamicRange": "sdr",
                "preferredMaxResolution": maxRes,
                "preferredDynamicRange": "sdr",
                "hqMode": 1
            ] as [String: Any]

            spec["audioChannels"] = "2"
            spec["audioEncoderProfile"] = "default"
            spec["audioStreamSettings"] = [
                "audioEncoderProfile": "default",
                "maxAudioChannels": "2",
                "preferredNumberAudioChannels": "2"
            ]
        } else {
            spec["audioChannels"] = "2.1"
            spec["audioEncoderProfile"] = "default"
            spec["videoEncoderProfile"] = "hw4.1"
            spec["connectedControllers"] = ["xinput"]
            spec["input"] = ["controllers": ["xinput"]]
            spec["model"] = "WINDOWS"
            spec["platform"] = "PC"
            spec["gaikaiPlayer"] = "12.5.0"
            spec["protocolVersion"] = 9
            spec["ps3AuthCode"] = ps3AuthCode
            spec["streamServerAuthCode"] = ps3AuthCode
            caps.append("kratos")
        }

        spec["capabilities"] = caps
        return spec
    }

    // MARK: - Helpers

    private func gaikaiHeaders() -> [String: String] {
        return [
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "Accept": "*/*",
            "X-Gaikai-Session": configKey,
            "X-Gaikai-SessionId": gaikaiSessionId
        ]
    }

    private func getOAuthCode(params: [(String, String)]) throws -> String {
        let query = params.map { "\($0.0)=\($0.1.cloudUrlEncoded)" }.joined(separator: "&")
        let url = "\(CloudApiConstants.gaikaiAccountBase)\(oauthApiPath)/oauth/authorize?\(query)"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "User-Agent": userAgent, "Cookie": "npsso=\(npssoToken)"
        ], followRedirects: false) else {
            throw GaikaiAllocationError(message: "OAuth request failed")
        }

        guard response.statusCode == 302 else {
            throw GaikaiAllocationError(message: "OAuth: expected 302, got \(response.statusCode)")
        }

        guard let location = CloudHttpClient.extractLocation(from: response) else {
            throw GaikaiAllocationError(message: "No Location header in OAuth redirect")
        }

        guard let code = extractCodeFromURL(location) else {
            throw GaikaiAllocationError(message: "No code in OAuth redirect URL")
        }
        return code
    }

    private func extractCodeFromURL(_ urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func parseJSON(_ str: String) -> [String: Any]? {
        guard let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private func parseJSONArray(_ str: String) -> [[String: Any]]? {
        guard let data = str.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

