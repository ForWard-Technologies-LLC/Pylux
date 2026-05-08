// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// SecureStore — single Keychain-backed store for all app settings and credentials.
// Replaces all UserDefaults usage with an encrypted, access-controlled Keychain backend.
//
// Usage: SecureStore.shared.<propertyName>

import Foundation
import Security
import os.log

private let storeLog = OSLog(subsystem: "com.pylux.stream", category: "SecureStore")

// MARK: - Keychain backend

private enum KC {
    static let service = "com.pylux.stream"

    // MARK: String

    static func readString(_ key: String) -> String? {
        guard let data = readData(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeString(_ key: String, _ value: String) {
        writeData(key, Data(value.utf8))
    }

    // MARK: Data

    static func readData(_ key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        if status != errSecItemNotFound {
            os_log(.error, log: storeLog, "KC read FAILED key=%{public}s status=%d", key, status)
        }
        return nil
    }

    static func writeData(_ key: String, _ value: Data) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let attrs: [CFString: Any] = [
            kSecValueData:      value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            for (k, v) in attrs { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                os_log(.error, log: storeLog, "KC add FAILED key=%{public}s status=%d", key, addStatus)
            }
        } else if updateStatus != errSecSuccess {
            os_log(.error, log: storeLog, "KC update FAILED key=%{public}s status=%d", key, updateStatus)
        }
    }

    static func delete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Typed helpers

    static func readBool(_ key: String, default def: Bool = false) -> Bool {
        guard let s = readString(key) else { return def }
        return s == "1"
    }
    static func writeBool(_ key: String, _ value: Bool) {
        writeString(key, value ? "1" : "0")
    }

    static func readInt(_ key: String, default def: Int = 0) -> Int {
        guard let s = readString(key) else { return def }
        return Int(s) ?? def
    }
    static func writeInt(_ key: String, _ value: Int) {
        writeString(key, String(value))
    }

    static func readDouble(_ key: String, default def: Double = 0) -> Double {
        guard let s = readString(key) else { return def }
        return Double(s) ?? def
    }
    static func writeDouble(_ key: String, _ value: Double) {
        writeString(key, String(value))
    }

    static func readStringSet(_ key: String) -> Set<String> {
        guard let data = readData(key),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }
    static func writeStringSet(_ key: String, _ value: Set<String>) {
        if let data = try? JSONSerialization.data(withJSONObject: Array(value)) {
            writeData(key, data)
        }
    }
}

// MARK: - SecureStore

/// Central store for all app settings and credentials.
/// Everything is stored in the iOS Keychain — encrypted at rest and excluded from
/// unencrypted backups. Thread-safe for reads (Keychain calls are synchronised by
/// the OS); call from the main actor for writes that need to publish changes.
final class SecureStore {
    static let shared = SecureStore()
    private init() {
        os_log(.info, log: storeLog,
               "SecureStore ready: hasAuthToken=%d hasNpsso=%d hasDuid=%d hasHosts=%d",
               authToken.isEmpty ? 0 : 1, npsso.isEmpty ? 0 : 1,
               duid.isEmpty ? 0 : 1, registeredHostsData != nil ? 1 : 0)
    }

    // MARK: - Keys

    // PSN tokens
    private let kNpsso         = "pylux.npssoToken"
    private let kAuthToken     = "pylux.psnAuthToken"
    private let kRefreshToken  = "pylux.psnRefreshToken"
    private let kTokenExpiry   = "pylux.psnAuthTokenExpiry"
    private let kAccountId     = "pylux.psnAccountId"
    private let kOnlineId      = "pylux.psnOnlineId"
    private let kDuid          = "pylux.psnDuid"

    // Hosts
    private let kRegisteredHosts = "pylux.registeredHosts"
    private let kManualHosts     = "pylux.manualHosts"
    private let kDiscoveryActive = "pylux.discoveryEnabled"

    // Stream preferences
    private let kStreamPrefs = "pylux.streamPreferences"

    // Datacenter caches (server-returned, refreshed on use — still kept secure)
    private let kDcPscloud = "cloud_datacenters_json_pscloud"
    private let kDcPsnow   = "cloud_datacenters_json_psnow"

    // Cloud
    private let kCloudFavorites = "favorite_games"
    private let kCloudSortState = "cloud_sort_state"

    // Donation / support paywall
    private let kTotalStreamTimeMs       = "pylux.totalStreamTimeMs"
    private let kLastDonationPromptWallMs = "pylux.lastDonationPromptWallMs"
    private let kDonationPaywallShowCount = "pylux.donationPaywallShowCount"

    // Last connect info (ConnectInfoEntryView)
    private let kLastHost       = "pylux.lastHost"
    private let kLastRegistKey  = "pylux.lastRegistKey"
    private let kLastMorning    = "pylux.lastMorning"
    private let kLastPs5        = "pylux.lastPs5"
    private let kLastResolution = "pylux.lastResolution"
    private let kLastFps        = "pylux.lastFps"
    private let kLastCodec      = "pylux.lastCodec"

    // MARK: - PSN Tokens

    var npsso: String {
        get { KC.readString(kNpsso) ?? "" }
        set { newValue.isEmpty ? KC.delete(kNpsso) : KC.writeString(kNpsso, newValue) }
    }

    var authToken: String {
        get { KC.readString(kAuthToken) ?? "" }
        set { newValue.isEmpty ? KC.delete(kAuthToken) : KC.writeString(kAuthToken, newValue) }
    }

    var refreshToken: String {
        get { KC.readString(kRefreshToken) ?? "" }
        set { newValue.isEmpty ? KC.delete(kRefreshToken) : KC.writeString(kRefreshToken, newValue) }
    }

    var tokenExpiry: TimeInterval {
        get { KC.readDouble(kTokenExpiry) }
        set { KC.writeDouble(kTokenExpiry, newValue) }
    }

    var accountId: String {
        get { KC.readString(kAccountId) ?? "" }
        set { newValue.isEmpty ? KC.delete(kAccountId) : KC.writeString(kAccountId, newValue) }
    }

    /// PSN online ID (gamertag), fetched once during token exchange.
    var onlineId: String {
        get { KC.readString(kOnlineId) ?? "" }
        set { newValue.isEmpty ? KC.delete(kOnlineId) : KC.writeString(kOnlineId, newValue) }
    }

    var duid: String {
        get { KC.readString(kDuid) ?? "" }
        set { newValue.isEmpty ? KC.delete(kDuid) : KC.writeString(kDuid, newValue) }
    }

    // MARK: - Hosts

    var registeredHostsData: Data? {
        get { KC.readData(kRegisteredHosts) }
        set {
            if let d = newValue { KC.writeData(kRegisteredHosts, d) }
            else { KC.delete(kRegisteredHosts) }
        }
    }

    var manualHostsData: Data? {
        get { KC.readData(kManualHosts) }
        set {
            if let d = newValue { KC.writeData(kManualHosts, d) }
            else { KC.delete(kManualHosts) }
        }
    }

    var discoveryActive: Bool {
        get { KC.readBool(kDiscoveryActive, default: true) }
        set { KC.writeBool(kDiscoveryActive, newValue) }
    }

    // MARK: - Stream Preferences

    var streamPreferencesData: Data? {
        get { KC.readData(kStreamPrefs) }
        set {
            if let d = newValue { KC.writeData(kStreamPrefs, d) }
            else { KC.delete(kStreamPrefs) }
        }
    }

    // MARK: - Cloud Datacenter Cache

    var pscloudDatacentersData: Data? {
        get { KC.readData(kDcPscloud) }
        set {
            if let d = newValue { KC.writeData(kDcPscloud, d) }
            else { KC.delete(kDcPscloud) }
        }
    }

    var psnowDatacentersData: Data? {
        get { KC.readData(kDcPsnow) }
        set {
            if let d = newValue { KC.writeData(kDcPsnow, d) }
            else { KC.delete(kDcPsnow) }
        }
    }

    // MARK: - Cloud Preferences

    var cloudFavorites: Set<String> {
        get { KC.readStringSet(kCloudFavorites) }
        set { KC.writeStringSet(kCloudFavorites, newValue) }
    }

    var cloudSortState: Int {
        get { KC.readInt(kCloudSortState) }
        set { KC.writeInt(kCloudSortState, newValue) }
    }

    // MARK: - Donation / Support Paywall

    var totalStreamTimeMs: Int64 {
        get { Int64(KC.readString(kTotalStreamTimeMs) ?? "0") ?? 0 }
        set { KC.writeString(kTotalStreamTimeMs, String(newValue)) }
    }

    func addTotalStreamTimeMs(_ delta: Int64) {
        guard delta > 0 else { return }
        totalStreamTimeMs += delta
    }

    var lastDonationPromptWallClockMs: Int64 {
        get { Int64(KC.readString(kLastDonationPromptWallMs) ?? "0") ?? 0 }
        set { KC.writeString(kLastDonationPromptWallMs, String(newValue)) }
    }

    var donationPaywallShowCount: Int {
        get { KC.readInt(kDonationPaywallShowCount) }
        set { KC.writeInt(kDonationPaywallShowCount, newValue) }
    }

    @discardableResult
    func incrementDonationPaywallShowCount() -> Int {
        let next = donationPaywallShowCount + 1
        donationPaywallShowCount = next
        return next
    }

    // MARK: - Last Connect Info (ConnectInfoEntryView)

    var lastHost: String {
        get { KC.readString(kLastHost) ?? "" }
        set { KC.writeString(kLastHost, newValue) }
    }

    var lastRegistKey: String {
        get { KC.readString(kLastRegistKey) ?? "" }
        set { KC.writeString(kLastRegistKey, newValue) }
    }

    var lastMorning: String {
        get { KC.readString(kLastMorning) ?? "" }
        set { KC.writeString(kLastMorning, newValue) }
    }

    var lastPs5: Bool {
        get { KC.readBool(kLastPs5) }
        set { KC.writeBool(kLastPs5, newValue) }
    }

    var lastResolutionIndex: Int {
        get { KC.readInt(kLastResolution) }
        set { KC.writeInt(kLastResolution, newValue) }
    }

    var lastFpsIndex: Int {
        get { KC.readInt(kLastFps) }
        set { KC.writeInt(kLastFps, newValue) }
    }

    var lastCodecIndex: Int {
        get { KC.readInt(kLastCodec) }
        set { KC.writeInt(kLastCodec, newValue) }
    }

    // MARK: - Reset

    /// Deletes every Keychain item owned by this app. Irreversible.
    func clearAll() {
        let allKeys = [
            kNpsso, kAuthToken, kRefreshToken, kTokenExpiry, kAccountId, kOnlineId, kDuid,
            kRegisteredHosts, kManualHosts, kDiscoveryActive,
            kStreamPrefs,
            kDcPscloud, kDcPsnow,
            kCloudFavorites, kCloudSortState,
            kTotalStreamTimeMs, kLastDonationPromptWallMs, kDonationPaywallShowCount,
            kLastHost, kLastRegistKey, kLastMorning, kLastPs5,
            kLastResolution, kLastFps, kLastCodec,
        ]
        for key in allKeys { KC.delete(key) }
        os_log(.info, log: storeLog, "SecureStore cleared all %d keys", allKeys.count)
    }
}
