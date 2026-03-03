// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Settings matching Android's SettingsActivity exactly

import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os.log

private let settingsLog = OSLog(subsystem: "com.pylux.stream", category: "Settings")

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

struct StreamPreferences: Codable {
    // Remote Play
    var resolutionIndex: Int = 2       // default 720p (index 2 in updated array, matches Android)
    var fps: Int = 60
    var bitrate: Int = 0               // 0 = auto (matches Android null -> auto)
    var codec: Int = 1                 // 0=H264, 1=H265 (matches Android default H265)

    // General
    var swapCrossMoon: Bool = false
    var rumbleEnabled: Bool = true      // matches Android default true
    var motionEnabled: Bool = true      // matches Android default true
    var touchHapticsEnabled: Bool = true // matches Android default true
    var logVerbose: Bool = false

    // Cloud Game Library (PSCloud)
    var cloudResolutionPscloud: String = "720"      // matches Android default
    var cloudDatacenterPscloud: String = "Auto"     // matches Android default

    // Cloud Game Catalog (PSNow)
    var cloudResolutionPsnow: String = "720"        // matches Android default
    var cloudDatacenterPsnow: String = "Auto"       // matches Android default

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
    }
}

// MARK: - Datacenter list storage (matches Android cloud_datacenters_json_*)

enum CloudDatacenterStore {
    /// Save datacenter list after allocation (called from PSGaikaiStreaming)
    static func saveDatacenters(_ datacenters: [[String: Any]], for serviceType: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: datacenters) else { return }
        if serviceType == "pscloud" {
            SecureStore.shared.pscloudDatacentersData = data
        } else {
            SecureStore.shared.psnowDatacentersData = data
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
            let ping = dc["rtt"] as? Int ?? 0
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
    @State private var psnLoggedIn = PsnTokenStore.shared.hasTokens

    var body: some View {
        Form {
            // 1. General (matches Android's General category)
            generalSection

            // 2. Remote Play Settings
            remotePlaySection

            // 3. Cloud Game Library (PSCloud)
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
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Swap Cross/Moon and Box/Pyramid Buttons", isOn: $prefs.swapCrossMoon)
                    .onChange(of: prefs.swapCrossMoon) { _ in prefs.save() }
                Text("Swap face buttons if default mapping is incorrect (e.g. for 8BitDo controllers)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Rumble (TODO)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Rumble", isOn: $prefs.rumbleEnabled)
                    .onChange(of: prefs.rumbleEnabled) { _ in prefs.save() }
                Text("Use phone vibration motor for rumble")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Not yet implemented")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Motion (TODO)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Motion", isOn: $prefs.motionEnabled)
                    .onChange(of: prefs.motionEnabled) { _ in prefs.save() }
                Text("Use device's motion sensors for controller motion")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Not yet implemented")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Touch Haptics (TODO)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Touch Haptics", isOn: $prefs.touchHapticsEnabled)
                    .onChange(of: prefs.touchHapticsEnabled) { _ in prefs.save() }
                Text("Use phone vibration motor for short haptic feedback on button touches")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Not yet implemented")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Verbose Logging (TODO)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Verbose Logging", isOn: $prefs.logVerbose)
                    .onChange(of: prefs.logVerbose) { _ in prefs.save() }
                Text("Warning: This logs a LOT! Don't enable for regular use.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Not yet implemented")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Session Logs (TODO)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session Logs")
                Text("Collected log files from previous sessions for debugging")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Not yet implemented")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("General")
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
        } header: {
            Text("Cloud Game Library")
        } footer: {
            Text("Settings for PS5 Cloud streaming (Game Library tab)")
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
        } header: {
            Text("Cloud Game Catalog")
        } footer: {
            Text("Settings for Catalog streaming")
        }
    }

    // MARK: - Datacenter Picker Helper

    private func datacenterPicker(selection: Binding<String>, serviceType: String) -> some View {
        let datacenters = CloudDatacenterStore.loadDatacenters(for: serviceType)
        return Picker("Datacenter", selection: selection) {
            Text("Auto (Best Ping)").tag("Auto")
            ForEach(datacenters, id: \.name) { dc in
                Text("\(dc.name) (\(dc.ping)ms)").tag(dc.name)
            }
        }
        .onChange(of: selection.wrappedValue) { _ in prefs.save() }
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
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("About")
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
