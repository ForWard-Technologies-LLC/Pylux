// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Host data models matching Android's RegisteredHost, ManualHost, DisplayHost

import Foundation
import os.log

private let hostLog = OSLog(subsystem: "com.pylux.stream", category: "HostStore")

// MARK: - RegisteredHost (persisted, matches Android's RegisteredHost entity)

struct RegisteredHost: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var target: Int              // ChiakiTarget value (e.g. 1000100 for PS5)
    var apSsid: String?
    var apBssid: String?
    var apKey: String?
    var apName: String?
    var serverMac: Data          // 6 bytes
    var serverNickname: String?
    var rpRegistKey: Data        // 16 bytes (CHIAKI_SESSION_AUTH_SIZE)
    var rpKeyType: Int
    var rpKey: Data              // 16 bytes

    var isPS5: Bool { target >= 1_000_000 }

    /// MAC address formatted as XX:XX:XX:XX:XX:XX
    var serverMacString: String {
        serverMac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - ManualHost (persisted, matches Android's ManualHost entity)

struct ManualHost: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var host: String
    var registeredHostId: UUID?  // FK to RegisteredHost
}

// MARK: - DisplayHost (unified model for UI, matches Android's DisplayHost sealed class)

/// PSN-discovered host (matches Android's PsnHost)
struct PsnHost: Equatable {
    var duid: String
    var name: String
    var isPS5: Bool
}

enum DisplayHost: Identifiable, Equatable {
    case discovered(DiscoveredDisplayHost)
    case manual(ManualDisplayHost)
    case psn(PsnDisplayHost)

    var id: String {
        switch self {
        case .discovered(let h): return "disc-\(h.discoveredHost.hostAddr ?? "unknown")"
        case .manual(let h): return "manual-\(h.manualHost.id)"
        case .psn(let h): return "psn-\(h.psnHost.duid)"
        }
    }

    var name: String? {
        switch self {
        case .discovered(let h): return h.discoveredHost.hostName ?? h.registeredHost?.serverNickname
        case .manual(let h): return h.registeredHost?.serverNickname
        case .psn(let h): return h.psnHost.name
        }
    }

    var hostAddress: String {
        switch self {
        case .discovered(let h): return h.discoveredHost.hostAddr ?? ""
        case .manual(let h): return h.manualHost.host
        case .psn: return "" // No direct IP for PSN hosts
        }
    }

    var hostId: String? {
        switch self {
        case .discovered(let h): return h.discoveredHost.hostId ?? h.registeredHost?.serverMacString
        case .manual(let h): return h.registeredHost?.serverMacString
        case .psn(let h): return h.psnHost.duid
        }
    }

    var isPS5: Bool {
        switch self {
        case .discovered(let h): return h.discoveredHost.isPS5
        case .manual(let h): return h.registeredHost?.isPS5 ?? false
        case .psn(let h): return h.psnHost.isPS5
        }
    }

    var registeredHost: RegisteredHost? {
        switch self {
        case .discovered(let h): return h.registeredHost
        case .manual(let h): return h.registeredHost
        case .psn(let h): return h.registeredHost
        }
    }

    var isRegistered: Bool { registeredHost != nil }

    var typeName: String {
        switch self {
        case .discovered: return "discovered"
        case .manual: return "manual"
        case .psn: return "psn"
        }
    }

    /// PSN DUID for holepunch connections
    var psnDuid: String? {
        switch self {
        case .psn(let h): return h.psnHost.duid
        case .discovered(let h): return h.psnDuid
        default: return nil
        }
    }

    static func == (lhs: DisplayHost, rhs: DisplayHost) -> Bool { lhs.id == rhs.id }
}

struct PsnDisplayHost: Equatable {
    var registeredHost: RegisteredHost?
    var psnHost: PsnHost
}

struct DiscoveredDisplayHost: Equatable {
    var registeredHost: RegisteredHost?
    var discoveredHost: PyluxDiscoveredHost
    var psnDuid: String?  // PSN DUID if host also found via PSN

    static func == (lhs: DiscoveredDisplayHost, rhs: DiscoveredDisplayHost) -> Bool {
        lhs.discoveredHost.hostAddr == rhs.discoveredHost.hostAddr &&
        lhs.discoveredHost.hostName == rhs.discoveredHost.hostName &&
        lhs.registeredHost == rhs.registeredHost
    }
}

struct ManualDisplayHost: Equatable {
    var registeredHost: RegisteredHost?
    var manualHost: ManualHost
}

// MARK: - HostStore (persistence + discovery, matches Android MainViewModel + AppDatabase)

@MainActor
class HostStore: ObservableObject {
    @Published var registeredHosts: [RegisteredHost] = []
    @Published var manualHosts: [ManualHost] = []
    @Published var discoveredHosts: [PyluxDiscoveredHost] = []
    @Published var psnHosts: [PsnHost] = []
    @Published var discoveryActive: Bool = true
    @Published var psnRefreshing: Bool = false
    @Published var psnError: String?  // Visible error for PSN operations

    private var discoveryService: PyluxDiscoveryService?
    private let store = SecureStore.shared

    init() {
        loadFromDisk()
        discoveryActive = store.discoveryActive
        if discoveryActive {
            startDiscovery()
        }
    }

    // MARK: - Display hosts (combined, matches Android MainViewModel.displayHosts)

    var displayHosts: [DisplayHost] {
        let macRegistered = Dictionary(
            registeredHosts.compactMap { h -> (String, RegisteredHost)? in
                guard h.serverMac.count == 6 else { return nil }
                return (h.serverMacString, h)
            },
            uniquingKeysWith: { _, last in last }
        )
        let idRegistered = Dictionary(
            registeredHosts.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )

        // Build set of discovered host IPs to avoid duplicates with PSN
        var discoveredIps = Set<String>()

        // Build PSN DUID lookup by nickname (matches Android MainViewModel.combine() cross-reference)
        // This allows discovered hosts to inherit the PSN DUID when the same console
        // is visible both locally and via PSN
        let psnDuidByNickname = Dictionary(
            psnHosts.map { ($0.name, $0.duid) },
            uniquingKeysWith: { _, last in last }
        )
        os_log(.default, log: hostLog, "displayHosts: %d discovered, %d psn, %d manual, %d registered",
               discoveredHosts.count, psnHosts.count, manualHosts.count, registeredHosts.count)

        let discovered: [DisplayHost] = discoveredHosts.map { dh in
            if let addr = dh.hostAddr { discoveredIps.insert(addr) }
            let registered = dh.hostId.flatMap { hostIdStr -> RegisteredHost? in
                guard hostIdStr.count == 12 else { return nil }
                // Build XX:XX:XX:XX:XX:XX from compact hex, then uppercase to match
                // serverMacString which uses %02X. Discovery host-id is typically lowercase.
                let macFormatted = stride(from: 0, to: 12, by: 2).map { i in
                    let start = hostIdStr.index(hostIdStr.startIndex, offsetBy: i)
                    let end = hostIdStr.index(start, offsetBy: 2)
                    return String(hostIdStr[start..<end])
                }.joined(separator: ":").uppercased()
                return macRegistered[macFormatted]
            }
            // Cross-reference: if this discovered host also exists in PSN hosts, carry its DUID
            // (matches Android MainViewModel line 83: psnDuid = matchedDuid)
            let matchedDuid = dh.hostName.flatMap { psnDuidByNickname[$0] }
            os_log(.default, log: hostLog, "  discovered: name=%{public}s hostId=%{public}s registered=%d",
                   dh.hostName ?? "nil", dh.hostId ?? "nil", registered != nil ? 1 : 0)
            return .discovered(DiscoveredDisplayHost(registeredHost: registered, discoveredHost: dh, psnDuid: matchedDuid))
        }

        let manual: [DisplayHost] = manualHosts.map { mh in
            let registered = mh.registeredHostId.flatMap { idRegistered[$0] }
            return .manual(ManualDisplayHost(registeredHost: registered, manualHost: mh))
        }

        // PSN hosts filtering — matches Android MainViewModel.combine() exactly:
        // 1. Filter out PSN hosts already discovered locally (by nickname)
        // 2. Filter out "Main PS4 Console" placeholder unless registered PS4s exist
        //    that aren't all discovered locally
        // 3. Match registered hosts by nickname (not isPS5)

        // Build set of locally discovered nicknames
        let discoveredNicknames = Set(discoveredHosts.compactMap { $0.hostName })

        // Map registered hosts by nickname (matching Android's nicknameRegisteredHosts)
        let nicknameRegistered = Dictionary(
            registeredHosts.compactMap { rh -> (String, RegisteredHost)? in
                guard let nick = rh.serverNickname, !nick.isEmpty else { return nil }
                return (nick, rh)
            },
            uniquingKeysWith: { _, last in last }
        )

        // Count registered PS4 hosts (matches Qt's GetPS4RegisteredHostsRegistered())
        let registeredPS4Count = registeredHosts.filter { !$0.isPS5 }.count

        // Count locally discovered + registered PS4 hosts
        let discoveredRegisteredPS4Count = discovered.filter {
            if case .discovered(let h) = $0 {
                return h.registeredHost != nil && !h.discoveredHost.isPS5
            }
            return false
        }.count

        let psn: [DisplayHost] = psnHosts.compactMap { psnHost in
            // Skip hosts already discovered locally (DUID already transferred above)
            if discoveredNicknames.contains(psnHost.name) { return nil }

            // PS4 placeholder: only show if registered PS4s exist and not all are local
            if !psnHost.isPS5 && psnHost.name == "Main PS4 Console" {
                guard registeredPS4Count > 0,
                      discoveredRegisteredPS4Count < registeredPS4Count else { return nil }
            }

            let registered = nicknameRegistered[psnHost.name]
            return .psn(PsnDisplayHost(registeredHost: registered, psnHost: psnHost))
        }

        return discovered + manual + psn
    }

    // MARK: - Discovery

    func setDiscoveryActive(_ active: Bool) {
        discoveryActive = active
        store.discoveryActive = active
        if active {
            startDiscovery()
        } else {
            stopDiscovery()
        }
    }

    func startDiscovery() {
        guard discoveryService == nil else { return }
        discoveryService = PyluxDiscoveryService { [weak self] hosts in
            self?.discoveredHosts = hosts
        }
    }

    func stopDiscovery() {
        discoveryService?.shutdown()
        discoveryService = nil
        discoveredHosts = []
    }

    // MARK: - Registered hosts

    func addRegisteredHost(_ host: RegisteredHost) {
        // Check for duplicate MAC
        if let idx = registeredHosts.firstIndex(where: { $0.serverMacString == host.serverMacString }) {
            registeredHosts[idx] = host
        } else {
            registeredHosts.append(host)
        }
        saveToDisk()
    }

    func deleteRegisteredHost(_ host: RegisteredHost) {
        registeredHosts.removeAll { $0.id == host.id }
        // Clear FK references in manual hosts
        for i in manualHosts.indices where manualHosts[i].registeredHostId == host.id {
            manualHosts[i].registeredHostId = nil
        }
        saveToDisk()
    }

    // MARK: - Manual hosts

    func addManualHost(_ host: ManualHost) {
        manualHosts.append(host)
        saveToDisk()
    }

    func updateManualHost(_ host: ManualHost) {
        if let idx = manualHosts.firstIndex(where: { $0.id == host.id }) {
            manualHosts[idx] = host
            saveToDisk()
        }
    }

    func deleteManualHost(_ host: ManualHost) {
        manualHosts.removeAll { $0.id == host.id }
        saveToDisk()
    }

    func assignRegisteredHostToManual(manualId: UUID, registeredId: UUID) {
        if let idx = manualHosts.firstIndex(where: { $0.id == manualId }) {
            manualHosts[idx].registeredHostId = registeredId
            saveToDisk()
        }
    }

    // MARK: - PSN Discovery (matches Android's PsnDiscoveryManager)

    func refreshPsnHosts() {
        guard !psnRefreshing else { return }
        psnRefreshing = true
        os_log(.info, log: hostLog, "refreshPsnHosts: starting...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tokenManager = PsnTokenManager.shared
            guard let token = tokenManager.getValidToken() else {
                os_log(.error, log: hostLog, "refreshPsnHosts: no valid PSN token")
                DispatchQueue.main.async { self?.psnRefreshing = false }
                return
            }
            os_log(.info, log: hostLog, "refreshPsnHosts: got valid token (length=%d), listing devices...", token.count)

            var hosts: [PsnHost] = []

            // List PS5 devices (up to 3 tries, matching Android)
            for attempt in 1...3 {
                os_log(.info, log: hostLog, "refreshPsnHosts: PS5 list attempt %d/3", attempt)
                if let devices = PyluxHolepunchSession.listDevices(withToken: token, consoleType: .PS5) {
                    os_log(.info, log: hostLog, "refreshPsnHosts: got %d PS5 devices", devices.count)
                    for device in devices {
                        os_log(.info, log: hostLog, "  PS5 device: %{public}s remoteplay=%d duid=%{public}s",
                               device.deviceName, device.remoteplayEnabled ? 1 : 0, device.duidHex)
                        guard device.remoteplayEnabled else { continue }
                        hosts.append(PsnHost(duid: device.duidHex, name: device.deviceName, isPS5: true))
                    }
                    break
                } else {
                    os_log(.error, log: hostLog, "refreshPsnHosts: PS5 list attempt %d failed", attempt)
                }
            }

            // Add "Main PS4 Console" placeholder (matching Android behavior)
            let ps4DuidBytes = [UInt8](repeating: 0x41, count: 32)
            let ps4Duid = ps4DuidBytes.map { String(format: "%02x", $0) }.joined()
            hosts.append(PsnHost(duid: ps4Duid, name: "Main PS4 Console", isPS5: false))

            DispatchQueue.main.async {
                self?.psnHosts = hosts
                self?.psnRefreshing = false
                os_log(.info, log: hostLog, "refreshPsnHosts: complete - %d hosts total", hosts.count)
            }
        }
    }

    /// Exchange NPSSO for tokens, then refresh PSN hosts.
    /// If tokens already exist and are valid, skip exchange and just discover.
    func exchangeNpssoAndDiscover(_ npsso: String) {
        let store = PsnTokenStore.shared
        // If we already have valid (non-expired) tokens, skip re-exchange and go straight to discovery
        if store.hasTokens && !store.isTokenExpired {
            os_log(.info, log: hostLog, "exchangeNpssoAndDiscover: valid tokens already stored, skipping exchange")
            refreshPsnHosts()
            return
        }

        os_log(.info, log: hostLog, "exchangeNpssoAndDiscover: starting NPSSO exchange (length=%d)", npsso.count)
        psnError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tokenManager = PsnTokenManager.shared

            // Try refresh first if we have a refresh token
            if store.hasTokens {
                os_log(.info, log: hostLog, "Trying token refresh first...")
                if tokenManager.refreshToken() {
                    os_log(.info, log: hostLog, "Token refresh succeeded, discovering PSN hosts...")
                    DispatchQueue.main.async { self?.refreshPsnHosts() }
                    return
                }
            }

            // Full NPSSO exchange
            let success = tokenManager.exchangeNpssoForTokens(npsso)
            if success {
                os_log(.info, log: hostLog, "NPSSO exchange succeeded, discovering PSN hosts...")
                DispatchQueue.main.async {
                    self?.psnError = nil
                    self?.refreshPsnHosts()
                }
            } else {
                os_log(.error, log: hostLog, "NPSSO exchange FAILED - token may be expired")
                DispatchQueue.main.async {
                    self?.psnError = "Login failed: NPSSO token may be expired. Get a fresh token from playstation.com."
                }
            }
        }
    }

    // MARK: - Wakeup

    func wakeupHost(_ host: DisplayHost) {
        guard let registered = host.registeredHost else { return }
        let address = host.hostAddress
        guard !address.isEmpty else { return }
        // Wakeup credential = first 8 bytes of rpRegistKey as big-endian UInt64
        // Matches Android: credential = BigInteger(1, rpRegistKey.take(8).toByteArray()).toLong()
        let keyBytes = registered.rpRegistKey.prefix(8)
        let credential = keyBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        os_log(.default, log: hostLog, "Wakeup: sending to %{public}s, credential=0x%016llx, ps5=%d",
               address, credential, registered.isPS5 ? 1 : 0)
        PyluxDiscoveryService.wakeupHost(address, credential: credential, ps5: registered.isPS5)
    }

    // MARK: - Persistence

    private func saveToDisk() {
        store.registeredHostsData = try? JSONEncoder().encode(registeredHosts)
        store.manualHostsData = try? JSONEncoder().encode(manualHosts)
    }

    private func loadFromDisk() {
        if let data = store.registeredHostsData,
           let hosts = try? JSONDecoder().decode([RegisteredHost].self, from: data) {
            registeredHosts = hosts
        }
        if let data = store.manualHostsData,
           let hosts = try? JSONDecoder().decode([ManualHost].self, from: data) {
            manualHosts = hosts
        }
    }
}
