// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Settings matching Android's SettingsActivity exactly

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os.log

private let settingsLog = OSLog(subsystem: "com.pylux.stream", category: "Settings")

/// When `true`, shows Motion, Verbose Logging, and Session Logs in General. Keep `false` until wired:
/// - Motion: `StreamInput` device gyro → session (see `StreamInput.swift`).
/// - Verbose logging: read `StreamPreferences.logVerbose` in logging / Chiaki bridge.
/// - Session logs: UI to export prior session logs.
private let showWorkInProgressGeneralSettings = false



// MARK: - Datacenter list storage (matches Android cloud_datacenters_json_*)

enum CloudDatacenterStore {
    /// Whether a non-empty datacenter list is already persisted. Used to avoid
    /// clobbering previously-measured ping RTTs with a no-RTT/dummy list.
    static func hasStoredDatacenters(for serviceType: String) -> Bool {
        let data = serviceType == "pscloud"
            ? SecureStore.shared.pscloudDatacentersData
            : SecureStore.shared.psnowDatacentersData
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return !arr.isEmpty
    }

    /// Save datacenter list after allocation (called from the cloud streaming backend)
    static func saveDatacenters(_ datacenters: [[String: Any]], for serviceType: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: datacenters) else { return }
        if serviceType == "pscloud" {
            SecureStore.shared.pscloudDatacentersData = data
        } else {
            SecureStore.shared.psnowDatacentersData = data
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cloudDatacentersDidUpdate, object: nil)
        }
    }

    /// `JSONSerialization` decodes JSON numbers as `Double`/`NSNumber`; `value as? Int` is usually nil.
    private static func jsonInt(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return nil
        }
    }

    /// Load datacenter list for settings dropdown
    static func loadDatacenters(for serviceType: String) -> [(name: String, ping: Int)] {
        let data = serviceType == "pscloud"
            ? SecureStore.shared.pscloudDatacentersData
            : SecureStore.shared.psnowDatacentersData
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { dc in
            guard let name = dc["dataCenter"] as? String else { return nil }
            let ping = jsonInt(dc["rtt"]) ?? 0
            return (name, ping)
        }
    }
}

// MARK: - Settings View (matches Android SettingsFragment exactly)

struct SettingsView: View {
    @EnvironmentObject var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = StreamPreferences.load()
    @State private var bitrateText = ""
    @State private var showResetAlert = false
    @State private var showLanguageInfo = false
    @State private var psnLoggedIn = PsnTokenStore.shared.hasTokens
    /// Bumped when cloud ping results are saved so datacenter pickers reload from `SecureStore`.
    @State private var datacenterStoreRevision = 0
    @State private var showDonationPaywall = false

    var body: some View {
        Form {
            // 1. Support
            if !DonationStore.productIDs.isEmpty {
                supportSection
            }

            // 2. General
            generalSection

            // 3. Remote Play Settings
            remotePlaySection

            // 4. Cloud Settings (shared across cloud library + catalog)
            cloudSettingsSection

            // 5. Cloud Game Library (PSCloud)
            cloudLibrarySection

            // 4. Cloud Game Catalog (PSNow)
            cloudCatalogSection

            // 5. Reset
            resetSection

            // 6. About
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            bitrateText = prefs.bitrate > 0 ? "\(prefs.bitrate)" : ""
            psnLoggedIn = PsnTokenStore.shared.hasTokens
            datacenterStoreRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDatacentersDidUpdate)) { _ in
            datacenterStoreRevision += 1
        }
    }

    // MARK: - 1. General

    private var generalSection: some View {
        Section {
            // Account
            NavigationLink {
                AccountView(isLoggedIn: $psnLoggedIn)
                    .environmentObject(hostStore)
            } label: {
                HStack {
                    Text("Account")
                    Spacer()
                    Text(psnLoggedIn ? "Signed In" : "Not Signed In")
                        .foregroundColor(psnLoggedIn ? .green : .secondary)
                        .font(.subheadline)
                }
            }

            // Registered Consoles
            NavigationLink {
                RegisteredHostsView(hostStore: hostStore)
            } label: {
                HStack {
                    Text("Registered Consoles")
                    Spacer()
                    Text("\(hostStore.registeredHosts.count)")
                        .foregroundColor(.secondary)
                }
            }

            // Swap Cross/Moon (wired)
            Toggle(isOn: $prefs.swapCrossMoon) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swap Cross/Moon and Box/Pyramid Buttons")
                    Text("Swap face buttons if default mapping is incorrect (e.g. for 8BitDo controllers)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: prefs.swapCrossMoon) { _ in prefs.save() }

            Toggle(isOn: $prefs.rumbleEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rumble")
                    Text("Play console rumble on this device (Core Haptics on supported iPhones; legacy vibrate otherwise)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: prefs.rumbleEnabled) { _ in prefs.save() }

            if prefs.rumbleEnabled {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Rumble Intensity")
                        Spacer()
                        Text("\(prefs.rumbleIntensity)%")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(prefs.rumbleIntensity) },
                            set: { prefs.rumbleIntensity = StreamPreferences.clampRumbleIntensity(Int($0.rounded())) }
                        ),
                        in: 0...500,
                        step: 10,
                        onEditingChanged: { editing in if !editing { prefs.save() } }
                    )
                    Text("Scales vibration strength; 100% matches the console")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $prefs.adaptiveTriggersEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adaptive Triggers")
                    Text("DualSense adaptive-trigger resistance (physical DualSense only)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: prefs.adaptiveTriggersEnabled) { _ in prefs.save() }

            Picker(selection: $prefs.motionSource) {
                ForEach(MotionSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gyro / Motion")
                    Text("Motion sensors sent to the console for gyro aiming")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: prefs.motionSource) { _ in prefs.save() }

            Toggle(isOn: $prefs.touchHapticsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Touch Haptics")
                    Text("Light haptic feedback when using on-screen controls")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: prefs.touchHapticsEnabled) { _ in prefs.save() }

            if showWorkInProgressGeneralSettings {
                Toggle(isOn: $prefs.logVerbose) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verbose Logging")
                        Text("Warning: This logs a LOT! Don't enable for regular use.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: prefs.logVerbose) { _ in prefs.save() }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Logs")
                    Text("Collected log files from previous sessions for debugging")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("General")
        }
    }

    // MARK: - 1.5 Support

    private var supportSection: some View {
        Section {
            Button {
                showDonationPaywall = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Support Pylux")
                        .foregroundColor(.primary)
                    Text("Donate to support development. Thank you for using Pylux.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .sheet(isPresented: $showDonationPaywall) {
                DonationPaywallView()
            }
        } header: {
            Text("Support")
        }
    }

    // MARK: - 2. Remote Play Settings

    private var remotePlaySection: some View {
        Section {
            // Resolution (4 options: 360p, 540p, 720p, 1080p)
            Picker("Resolution", selection: $prefs.resolutionIndex) {
                ForEach(0..<kResolutions.count, id: \.self) { i in
                    Text(kResolutions[i].label).tag(i)
                }
            }
            .onChange(of: prefs.resolutionIndex) { _ in prefs.save() }

            // FPS
            Picker("FPS", selection: $prefs.fps) {
                Text("30").tag(30)
                Text("60").tag(60)
            }
            .onChange(of: prefs.fps) { _ in prefs.save() }

            // Bitrate (with validation 2000-50000, matches Android)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Bitrate")
                    Spacer()
                    TextField("Auto (\(prefs.autoBitrate))", text: $bitrateText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .onChange(of: bitrateText) { newValue in
                            if newValue.isEmpty {
                                prefs.bitrate = 0
                            } else if let val = Int(newValue) {
                                prefs.bitrate = val
                            }
                            prefs.save()
                        }
                }
                if prefs.bitrate > 0 && (prefs.bitrate < 2000 || prefs.bitrate > 50000) {
                    Text("Valid range: 2000 - 50000 kbps")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Codec (default H.265, matches Android)
            Picker("Codec", selection: $prefs.codec) {
                Text("H.264").tag(0)
                Text("H.265 (PS5 only)").tag(1)
            }
            .onChange(of: prefs.codec) { _ in prefs.save() }
        } header: {
            Text("Remote Play Settings")
        }
    }

    // MARK: - 3. Cloud Game Library (PSCloud)

    private var cloudLibrarySection: some View {
        Section {
            // Resolution
            Picker("Resolution", selection: $prefs.cloudResolutionPscloud) {
                ForEach(kCloudResolutionsPscloud, id: \.value) { r in
                    Text(r.label).tag(r.value)
                }
            }
            .onChange(of: prefs.cloudResolutionPscloud) { _ in prefs.save() }

            // Datacenter
            datacenterPicker(
                selection: $prefs.cloudDatacenterPscloud,
                serviceType: "pscloud"
            )

            cloudBitrateSlider(
                bitrateKbps: $prefs.cloudBitratePscloud,
                label: "Bitrate"
            )
        } header: {
            Text("Owned Games (PS5)")
        }
    }

    // MARK: - Cloud Settings (shared)

    private var cloudSettingsSection: some View {
        Section {
            // Game language (manual override, stored separately from the
            // auto-detected catalog locale). Shared across cloud library +
            // catalog, so it lives in its own section above both.
            languagePicker()
        } header: {
            Text("Cloud Settings")
        } footer: {
            Text("Language availability depends on your datacenter's region.")
        }
        // Full caveat shown as a popup only when a specific language is chosen,
        // keeping the inline section short.
        .alert("Game Language", isPresented: $showLanguageInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Not all regions support every language. A language only works on datacenters that offer it — if your chosen language isn't applied, pick a datacenter in a matching region.")
        }
    }

    // MARK: - 4. Cloud Game Catalog (PSNow)

    private var cloudCatalogSection: some View {
        Section {
            // Resolution
            Picker("Resolution", selection: $prefs.cloudResolutionPsnow) {
                ForEach(kCloudResolutionsPsnow, id: \.value) { r in
                    Text(r.label).tag(r.value)
                }
            }
            .onChange(of: prefs.cloudResolutionPsnow) { _ in prefs.save() }

            // Datacenter
            datacenterPicker(
                selection: $prefs.cloudDatacenterPsnow,
                serviceType: "psnow"
            )

            cloudBitrateSlider(
                bitrateKbps: $prefs.cloudBitratePsnow,
                label: "Bitrate"
            )
        } header: {
            Text("Streamable Games (PS3/PS4)")
        }
    }

    private func cloudBitrateSlider(bitrateKbps: Binding<Int>, label: String) -> some View {
        CloudBitrateSlider(bitrateKbps: bitrateKbps, label: label, onCommit: { prefs.save() })
    }

    // MARK: - Datacenter Picker Helper

    private func datacenterPicker(selection: Binding<String>, serviceType: String) -> some View {
        let datacenters = CloudDatacenterStore.loadDatacenters(for: serviceType)
        return Picker("Datacenter", selection: selection) {
            Text("Auto (Best Ping)").tag("Auto")
            ForEach(datacenters, id: \.name) { dc in
                let pingText = dc.ping > 0 ? "\(dc.ping)ms" : "—"
                Text("\(dc.name) (\(pingText))").tag(dc.name)
            }
        }
        .id("\(serviceType)-\(datacenterStoreRevision)")
        .onChange(of: selection.wrappedValue) { _ in prefs.save() }
    }

    // MARK: - Game Language Picker Helper

    /// Human-readable name for a cloud-language locale. Display names are the
    /// platform's responsibility; the locale list itself comes from libchiaki.
    private static func cloudLanguageName(_ locale: String) -> String {
        switch locale {
        case "en-US": return "English"
        case "en-GB": return "English (UK)"
        case "de-DE": return "Deutsch"
        case "fr-FR": return "Français"
        case "fi-FI": return "Suomi"
        case "it-IT": return "Italiano"
        case "es-ES": return "Español"
        case "nl-NL": return "Nederlands"
        case "pt-BR": return "Português (BR)"
        case "ja-JP": return "日本語"
        case "ko-KR": return "한국어"
        default: return locale
        }
    }

    private func languagePicker() -> some View {
        // Show every supported language (datacenter language support can't be
        // reliably enumerated). The manual pick is stored separately from the
        // auto-detected catalog locale and never auto-changes the datacenter;
        // the user picks a matching datacenter themselves.
        let supported = PyluxCloudCatalog.supportedCloudLanguages()
        let catalogLocale = CloudLocaleSettings.stored.isEmpty ? "en-US" : CloudLocaleSettings.stored
        let current = prefs.cloudGameLanguage
        let selection = Binding<String>(
            // Empty override selects "Auto"; an unknown value also falls back to Auto.
            get: { (current.isEmpty || supported.contains(current)) ? current : "" },
            set: { newValue in
                prefs.cloudGameLanguage = newValue
                prefs.save()
                // Surface the datacenter caveat only when overriding to a
                // specific language (Auto needs no warning).
                if !newValue.isEmpty { showLanguageInfo = true }
            }
        )
        return Picker("Game Language", selection: selection) {
            Text("Auto (\(catalogLocale))").tag("")
            ForEach(supported, id: \.self) { loc in
                Text("\(Self.cloudLanguageName(loc)) (\(loc))").tag(loc)
            }
        }
        .id("lang-\(datacenterStoreRevision)")
    }

    // MARK: - 5. Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset All Data")
                        Text("Wipes registered consoles, account credentials, and all settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Reset")
        }
        .alert("Reset All Data?", isPresented: $showResetAlert) {
            Button("Reset Everything", role: .destructive) {
                SecureStore.shared.clearAll()
                hostStore.registeredHosts = []
                hostStore.manualHosts = []
                hostStore.psnHosts = []
                prefs = StreamPreferences()
                prefs.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all registered consoles, account credentials, and saved settings. This cannot be undone.")
        }
    }

    // MARK: - 6. About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(String(cString: pylux_version_string()))
                    .foregroundColor(.secondary)
            }
            NavigationLink(destination: LicenseView()) {
                Text("License & Disclaimer")
            }
        } header: {
            Text("About")
        }
    }

}

private struct CloudBitrateSlider: View {
    @Binding var bitrateKbps: Int
    let label: String
    let onCommit: () -> Void

    var body: some View {
        let mbpsBinding = Binding<Double>(
            get: { Double(bitrateKbps) / 1000.0 },
            set: { newValue in
                bitrateKbps = StreamPreferences.clampCloudBitrateKbps(Int(newValue * 1000))
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(mbpsBinding.wrappedValue.rounded())) Mbps")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: mbpsBinding,
                in: 2...200,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
        }
    }
}

// MARK: - Registered Hosts list (matches Android's SettingsRegisteredHostsFragment)

struct RegisteredHostsView: View {
    @ObservedObject var hostStore: HostStore
    @State private var hostPendingDelete: RegisteredHost?

    var body: some View {
        Group {
            if hostStore.registeredHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No consoles registered.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Register a console from the Remote Play tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hostStore.registeredHosts) { host in
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(host.serverNickname ?? "Unknown Console")
                                    .font(.headline)
                                Text(host.serverMacString)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospaced()
                            }

                            Spacer()

                            Button {
                                hostPendingDelete = host
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Registered Consoles")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Remove Console?",
            isPresented: Binding(
                get: { hostPendingDelete != nil },
                set: { if !$0 { hostPendingDelete = nil } }
            ),
            presenting: hostPendingDelete
        ) { host in
            Button("Remove", role: .destructive) {
                hostStore.deleteRegisteredHost(host)
                hostPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                hostPendingDelete = nil
            }
        } message: { host in
            Text("All saved credentials for \"\(host.serverNickname ?? "Unknown")\" will be permanently deleted — including registration keys and encryption keys. You will need to re-register to connect again.")
        }
    }
}

// MARK: - Account View

struct AccountView: View {
    @EnvironmentObject var hostStore: HostStore
    @Binding var isLoggedIn: Bool

    @State private var onlineId: String = SecureStore.shared.onlineId
    @State private var isLoggingIn: Bool = false
    @State private var loginError: String?
    @State private var showLogoutConfirm: Bool = false
    @State private var showWebView: Bool = false
    
    // Manual login (xbgamestream) state
    @State private var showManualLogin: Bool = false
    @State private var loginCode: String = ""
    @State private var loginStatus: String = ""
    @State private var codeReady: Bool = false
    @State private var browserOpened: Bool = false
    
    private let loginService = PyluxLoginService.shared

    var body: some View {
        Form {
            if isLoggedIn {
                loggedInSection
            } else {
                signInSection
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign Out?", isPresented: $showLogoutConfirm) {
            Button("Sign Out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again to use online features and auto-registration.")
        }
        .sheet(isPresented: $showWebView) {
            if let url = loginService.buildOAuthURL() {
                LoginWebViewContainer(url: url) { npsso in
                    showWebView = false
                    handleNpsso(npsso)
                }
            }
        }
        .sheet(isPresented: $showManualLogin, onDismiss: {
            // Reset manual login state on dismiss
            loginCode = ""
            loginStatus = ""
            codeReady = false
            browserOpened = false
        }) {
            manualLoginSheet
                .onAppear {
                    if !codeReady {
                        startManualLogin()
                    }
                }
        }
    }

    // MARK: - Logged in

    private var loggedInSection: some View {
        Group {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "person.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(onlineId.isEmpty ? "Account" : onlineId)
                            .font(.headline)
                        Text("Signed in")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Signed In")
            }

            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                }
            } footer: {
                Text("Signing out removes your account tokens from this device. Your registered consoles will remain.")
            }
        }
    }

    // MARK: - Sign in

    private var signInSection: some View {
        Group {
            Section {
                Text("Sign in with your account to discover consoles, enable auto-registration, and access Internet Play.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            } header: {
                Text("Account")
            }

            Section {
                Button {
                    showWebView = true
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Login")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isLoggingIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Button {
                    showManualLogin = true
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "keyboard")
                        Text("Manual Login")
                        Spacer()
                    }
                }
                .disabled(isLoggingIn)
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                if isLoggingIn {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.trailing, 6)
                        Text("Signing in...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            } header: {
                Text("Sign In")
            } footer: {
                if let error = loginError {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    Text("Login opens a browser to sign in. If that doesn't work, try Manual Login.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleNpsso(_ npsso: String) {
        isLoggingIn = true
        loginError = nil
        
        Task.detached {
            let success = PsnTokenManager.shared.exchangeNpssoForTokens(npsso)
            
            await MainActor.run {
                isLoggingIn = false
                if success {
                    isLoggedIn = true
                    onlineId = SecureStore.shared.onlineId
                    hostStore.refreshPsnHosts()
                } else {
                    loginError = "Sign in failed. Please try again."
                }
            }
        }
    }
    
    // MARK: - Manual Login (xbgamestream flow)
    
    private var manualLoginSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if codeReady {
                        HStack {
                            Spacer()
                            Text(loginCode)
                                .font(.system(size: 36, weight: .bold, design: .monospaced))
                                .tracking(4)
                                .foregroundColor(.accentColor)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("Login Code")
                } footer: {
                    Text("Enter this code on the website to link your account.")
                        .font(.caption)
                }
                
                Section {
                    Text(loginStatus)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Status")
                }
                
                Section {
                    Button {
                        openBrowser()
                    } label: {
                        HStack {
                            Image(systemName: "safari")
                            Text("Open Browser")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!codeReady)
                    .buttonStyle(.borderedProminent)
                    
                    if browserOpened {
                        Button {
                            checkStatus()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                Text("Check Status")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    Text("1. Tap 'Open Browser' to visit the login page\n2. Sign in and enter the code shown above\n3. Return here and tap 'Check Status'")
                        .font(.caption)
                }
            }
            .navigationTitle("Manual Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showManualLogin = false
                    }
                }
            }
        }
    }
    
    private func startManualLogin() {
        loginCode = loginService.generateLoginCode()
        loginStatus = "Generating code..."
        
        Task.detached {
            let success = await self.loginService.createCode(self.loginCode)
            
            await MainActor.run {
                if success {
                    self.codeReady = true
                    self.loginStatus = "Code ready — tap 'Open Browser' to continue"
                } else {
                    self.loginStatus = "Failed to generate code. Please try again."
                }
            }
        }
    }
    
    private func openBrowser() {
        guard let url = loginService.getLoginURL(code: loginCode) else {
            loginStatus = "Failed to generate login URL"
            return
        }
        
        UIApplication.shared.open(url)
        browserOpened = true
        loginStatus = "Waiting for login... Tap 'Check Status' after signing in"
    }
    
    private func checkStatus() {
        loginStatus = "Checking login status..."
        
        Task.detached {
            if let npsso = await self.loginService.checkTokenStatus(self.loginCode) {
                await MainActor.run {
                    self.loginStatus = "Login successful!"
                    self.showManualLogin = false
                    self.handleNpsso(npsso)
                }
            } else {
                await MainActor.run {
                    self.loginStatus = "Not logged in yet. Complete the login in your browser, then try again."
                }
            }
        }
    }

    private func signOut() {
        PsnTokenStore.shared.clearTokens()
        SecureStore.shared.npsso = ""
        isLoggedIn = false
        onlineId = ""
        hostStore.psnHosts = []
        
        // Clear WebView cache and cookies
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                os_log(.info, log: settingsLog, "Cleared WebView cache and cookies on sign out")
            }
        }
    }
}
