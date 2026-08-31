// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Stream preferences (extracted from SettingsView so tvOS can compile without WebKit)

import Foundation

extension Notification.Name {
    /// Posted after `StreamPreferences.save()` so an active `StreamSession` can refresh cached toggles without keychain reads per rumble event.
    static let streamPreferencesDidChange = Notification.Name("com.pylux.streamPreferencesDidChange")
    /// Posted when `CloudDatacenterStore` saves ping rows so Settings pickers reload RTT labels.
    static let cloudDatacentersDidUpdate = Notification.Name("com.pylux.cloudDatacentersDidUpdate")
}

// MARK: - Stream Preferences (matches Android's Preferences)

struct StreamResolution: Equatable {
    let width: Int
    let height: Int
    var label: String { "\(height)p" }
}

/// All remote play resolution options (matches Android: 360p, 540p, 720p, 1080p)
let kResolutions: [StreamResolution] = [
    StreamResolution(width: 640, height: 360),
    StreamResolution(width: 960, height: 540),
    StreamResolution(width: 1280, height: 720),
    StreamResolution(width: 1920, height: 1080),
]

/// Cloud Library (PSCloud) resolution options (matches Android: 720p-4K)
let kCloudResolutionsPscloud: [(label: String, value: String, width: Int, height: Int)] = [
    ("720p (1280x720)", "720", 1280, 720),
    ("1080p (1920x1080)", "1080", 1920, 1080),
    ("1440p (2560x1440)", "1440", 2560, 1440),
    ("2160p (3840x2160) - 4K", "2160", 3840, 2160),
]

/// Cloud Catalog (PSNow) resolution options (matches Android: 720p/1080p)
let kCloudResolutionsPsnow: [(label: String, value: String, width: Int, height: Int)] = [
    ("720p (1280x720)", "720", 1280, 720),
    ("1080p (1920x1080)", "1080", 1920, 1080),
]

/// Where the motion data (gyro/accel/orientation) streamed to the console comes from.
enum MotionSource: String, Codable, CaseIterable, Identifiable {
    case auto        // controller when it has sensors, else this device
    case controller  // controller only
    case phone       // this device only
    case off         // no motion
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (controller, fall back to phone)"
        case .controller: return "Controller only"
        case .phone: return "Phone only"
        case .off: return "Off"
        }
    }
}

struct StreamPreferences: Codable {
    // Remote Play
    var resolutionIndex: Int = 2       // default 720p (index 2 in updated array, matches Android)
    var fps: Int = 60
    var bitrate: Int = 0               // 0 = auto (matches Android null -> auto)
    var codec: Int = 1                 // 0=H264, 1=H265 (matches Android default H265)

    // General
    var swapCrossMoon: Bool = false
    var rumbleEnabled: Bool = true      // matches Android default true
    /// Rumble strength percent, 0–500 (100 = 1x). Matches Android's rumbleIntensity.
    var rumbleIntensity: Int = 100
    var motionSource: MotionSource = .auto
    var touchHapticsEnabled: Bool = true // matches Android default true
    var adaptiveTriggersEnabled: Bool = true // DualSense adaptive triggers (physical DualSense only)
    var logVerbose: Bool = false

    /// Stream overlay: full on-screen controls (matches Android `onScreenControlsEnabled`, default true)
    var onScreenControlsEnabled: Bool = true
    /// Stream overlay: touchpad-only strip (matches Android `touchpadOnlyEnabled`, default false)
    var touchpadOnlyEnabled: Bool = false
    /// In-stream performance stats overlay toggle (matches Android `streamStatsOverlayEnabled`, default false)
    var streamStatsOverlayEnabled: Bool = false

    // Cloud Game Library (PSCloud)
    var cloudResolutionPscloud: String = "720"      // matches Android default
    var cloudDatacenterPscloud: String = "Auto"     // matches Android default
    var cloudBitratePscloud: Int = 20000            // kbps, matches Qt/Android default 20 Mbps

    // Cloud Game Catalog (PSNow)
    var cloudResolutionPsnow: String = "720"        // matches Android default
    var cloudDatacenterPsnow: String = "Auto"       // matches Android default
    var cloudBitratePsnow: Int = 20000              // kbps, matches Qt/Android default 20 Mbps

    /// Cloud streaming game language (BCP-47, e.g. "de-DE"). Empty = follow the
    /// detected catalog locale.
    var cloudGameLanguage: String = ""

    static let cloudBitrateMinKbps = 2000
    static let cloudBitrateMaxKbps = 200_000
    static let cloudBitrateDefaultKbps = 20000

    private enum CodingKeys: String, CodingKey {
        case resolutionIndex, fps, bitrate, codec
        case swapCrossMoon, rumbleEnabled, rumbleIntensity, motionSource, touchHapticsEnabled, logVerbose
        case motionEnabled // legacy bool, migrated into motionSource
        case adaptiveTriggersEnabled
        case onScreenControlsEnabled, touchpadOnlyEnabled
        case cloudResolutionPscloud, cloudDatacenterPscloud, cloudBitratePscloud
        case cloudResolutionPsnow, cloudDatacenterPsnow, cloudBitratePsnow
        case cloudGameLanguage
        case cloudLanguage // legacy key
    }

    init(
        resolutionIndex: Int = 2,
        fps: Int = 60,
        bitrate: Int = 0,
        codec: Int = 1,
        swapCrossMoon: Bool = false,
        rumbleEnabled: Bool = true,
        rumbleIntensity: Int = 100,
        motionSource: MotionSource = .auto,
        touchHapticsEnabled: Bool = true,
        logVerbose: Bool = false,
        onScreenControlsEnabled: Bool = true,
        touchpadOnlyEnabled: Bool = false,
        cloudResolutionPscloud: String = "720",
        cloudDatacenterPscloud: String = "Auto",
        cloudBitratePscloud: Int = StreamPreferences.cloudBitrateDefaultKbps,
        cloudResolutionPsnow: String = "720",
        cloudDatacenterPsnow: String = "Auto",
        cloudBitratePsnow: Int = StreamPreferences.cloudBitrateDefaultKbps,
        cloudGameLanguage: String = ""
    ) {
        self.resolutionIndex = resolutionIndex
        self.fps = fps
        self.bitrate = bitrate
        self.codec = codec
        self.swapCrossMoon = swapCrossMoon
        self.rumbleEnabled = rumbleEnabled
        self.rumbleIntensity = Self.clampRumbleIntensity(rumbleIntensity)
        self.motionSource = motionSource
        self.touchHapticsEnabled = touchHapticsEnabled
        self.logVerbose = logVerbose
        self.onScreenControlsEnabled = onScreenControlsEnabled
        self.touchpadOnlyEnabled = touchpadOnlyEnabled
        self.cloudResolutionPscloud = cloudResolutionPscloud
        self.cloudDatacenterPscloud = cloudDatacenterPscloud
        self.cloudBitratePscloud = Self.clampCloudBitrateKbps(cloudBitratePscloud)
        self.cloudResolutionPsnow = cloudResolutionPsnow
        self.cloudDatacenterPsnow = cloudDatacenterPsnow
        self.cloudBitratePsnow = Self.clampCloudBitrateKbps(cloudBitratePsnow)
        self.cloudGameLanguage = cloudGameLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolutionIndex = try c.decodeIfPresent(Int.self, forKey: .resolutionIndex) ?? 2
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        codec = try c.decodeIfPresent(Int.self, forKey: .codec) ?? 1
        swapCrossMoon = try c.decodeIfPresent(Bool.self, forKey: .swapCrossMoon) ?? false
        rumbleEnabled = try c.decodeIfPresent(Bool.self, forKey: .rumbleEnabled) ?? true
        rumbleIntensity = Self.clampRumbleIntensity(
            try c.decodeIfPresent(Int.self, forKey: .rumbleIntensity) ?? 100
        )
        if let source = try c.decodeIfPresent(MotionSource.self, forKey: .motionSource) {
            motionSource = source
        } else {
            // Migrate the legacy motionEnabled bool (Off keeps motion off; anything else = Auto).
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .motionEnabled) ?? true
            motionSource = legacy ? .auto : .off
        }
        touchHapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .touchHapticsEnabled) ?? true
        adaptiveTriggersEnabled = try c.decodeIfPresent(Bool.self, forKey: .adaptiveTriggersEnabled) ?? true
        logVerbose = try c.decodeIfPresent(Bool.self, forKey: .logVerbose) ?? false
        onScreenControlsEnabled = try c.decodeIfPresent(Bool.self, forKey: .onScreenControlsEnabled) ?? true
        touchpadOnlyEnabled = try c.decodeIfPresent(Bool.self, forKey: .touchpadOnlyEnabled) ?? false
        cloudResolutionPscloud = try c.decodeIfPresent(String.self, forKey: .cloudResolutionPscloud) ?? "720"
        cloudDatacenterPscloud = try c.decodeIfPresent(String.self, forKey: .cloudDatacenterPscloud) ?? "Auto"
        cloudBitratePscloud = Self.clampCloudBitrateKbps(
            try c.decodeIfPresent(Int.self, forKey: .cloudBitratePscloud) ?? Self.cloudBitrateDefaultKbps
        )
        cloudResolutionPsnow = try c.decodeIfPresent(String.self, forKey: .cloudResolutionPsnow) ?? "720"
        cloudDatacenterPsnow = try c.decodeIfPresent(String.self, forKey: .cloudDatacenterPsnow) ?? "Auto"
        cloudBitratePsnow = Self.clampCloudBitrateKbps(
            try c.decodeIfPresent(Int.self, forKey: .cloudBitratePsnow) ?? Self.cloudBitrateDefaultKbps
        )
        cloudGameLanguage = try c.decodeIfPresent(String.self, forKey: .cloudGameLanguage)
            ?? c.decodeIfPresent(String.self, forKey: .cloudLanguage) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resolutionIndex, forKey: .resolutionIndex)
        try c.encode(fps, forKey: .fps)
        try c.encode(bitrate, forKey: .bitrate)
        try c.encode(codec, forKey: .codec)
        try c.encode(swapCrossMoon, forKey: .swapCrossMoon)
        try c.encode(rumbleEnabled, forKey: .rumbleEnabled)
        try c.encode(rumbleIntensity, forKey: .rumbleIntensity)
        try c.encode(motionSource, forKey: .motionSource)
        try c.encode(touchHapticsEnabled, forKey: .touchHapticsEnabled)
        try c.encode(adaptiveTriggersEnabled, forKey: .adaptiveTriggersEnabled)
        try c.encode(logVerbose, forKey: .logVerbose)
        try c.encode(onScreenControlsEnabled, forKey: .onScreenControlsEnabled)
        try c.encode(touchpadOnlyEnabled, forKey: .touchpadOnlyEnabled)
        try c.encode(cloudResolutionPscloud, forKey: .cloudResolutionPscloud)
        try c.encode(cloudDatacenterPscloud, forKey: .cloudDatacenterPscloud)
        try c.encode(cloudBitratePscloud, forKey: .cloudBitratePscloud)
        try c.encode(cloudResolutionPsnow, forKey: .cloudResolutionPsnow)
        try c.encode(cloudDatacenterPsnow, forKey: .cloudDatacenterPsnow)
        try c.encode(cloudBitratePsnow, forKey: .cloudBitratePsnow)
        try c.encode(cloudGameLanguage, forKey: .cloudGameLanguage)
    }

    static func clampRumbleIntensity(_ percent: Int) -> Int {
        min(500, max(0, percent))
    }

    static func clampCloudBitrateKbps(_ kbps: Int) -> Int {
        min(cloudBitrateMaxKbps, max(cloudBitrateMinKbps, kbps))
    }

    func cloudBitrateKbps(for serviceType: String) -> Int {
        let raw = serviceType == "pscloud" ? cloudBitratePscloud : cloudBitratePsnow
        return Self.clampCloudBitrateKbps(raw)
    }

    var resolution: StreamResolution {
        let i = max(0, min(resolutionIndex, kResolutions.count - 1))
        return kResolutions[i]
    }

    /// Auto bitrate based on resolution/codec (matches Android videoProfileDefaultBitrate)
    var autoBitrate: Int {
        switch resolution.height {
        case 360:  return codec == 1 ? 4000 : 5000
        case 540:  return codec == 1 ? 6000 : 8000
        case 720:  return codec == 1 ? 8000 : 10000
        case 1080: return codec == 1 ? 12000 : 15000
        default:   return 10000
        }
    }

    /// Effective bitrate (user value or auto)
    var effectiveBitrate: Int {
        (bitrate >= 2000 && bitrate <= 50000) ? bitrate : autoBitrate
    }

    /// Cloud resolution dimensions for PSCloud
    var cloudResolutionDimensionsPscloud: (width: Int, height: Int) {
        if let r = kCloudResolutionsPscloud.first(where: { $0.value == cloudResolutionPscloud }) {
            return (r.width, r.height)
        }
        return (1280, 720)
    }

    /// Cloud resolution dimensions for PSNow
    var cloudResolutionDimensionsPsnow: (width: Int, height: Int) {
        if let r = kCloudResolutionsPsnow.first(where: { $0.value == cloudResolutionPsnow }) {
            return (r.width, r.height)
        }
        return (1280, 720)
    }

    static func load() -> StreamPreferences {
        if let data = SecureStore.shared.streamPreferencesData,
           let prefs = try? JSONDecoder().decode(StreamPreferences.self, from: data) {
            return prefs
        }
        return StreamPreferences()
    }

    func save() {
        SecureStore.shared.streamPreferencesData = try? JSONEncoder().encode(self)
        NotificationCenter.default.post(name: .streamPreferencesDidChange, object: nil)
    }
}
