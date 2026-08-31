// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// tvOS settings: Pickers instead of Slider; no touch/gyro/on-screen-control options.

import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject var hostStore: HostStore
    @State private var prefs = StreamPreferences.load()
    @State private var showResetAlert = false
    @State private var showLogin = false
    @State private var psnLoggedIn = PsnTokenStore.shared.hasTokens || !SecureStore.shared.npsso.isEmpty

    private let rumbleSteps = Array(stride(from: 0, through: 500, by: 50))
    private let bitrateSteps: [Int] = [0, 2000, 5000, 8000, 10000, 15000, 20000, 30000, 50000]

    var body: some View {
        Form {
            Section("Account") {
                HStack {
                    Text("PlayStation")
                    Spacer()
                    Text(psnLoggedIn ? "Signed In" : "Not Signed In")
                        .foregroundStyle(psnLoggedIn ? .green : .secondary)
                }
                if psnLoggedIn {
                    Button("Sign Out", role: .destructive) { signOut() }
                } else {
                    Button("Sign In") { showLogin = true }
                }
            }

            Section("Discovery") {
                Toggle("Search local network", isOn: Binding(
                    get: { hostStore.discoveryActive },
                    set: { hostStore.setDiscoveryActive($0) }
                ))
            }

            Section("Controller") {
                Toggle("Swap Cross/Moon and Box/Pyramid", isOn: $prefs.swapCrossMoon)
                    .onChange(of: prefs.swapCrossMoon) { _ in prefs.save() }
                Toggle("Rumble", isOn: $prefs.rumbleEnabled)
                    .onChange(of: prefs.rumbleEnabled) { _ in prefs.save() }
                if prefs.rumbleEnabled {
                    Picker("Rumble Intensity", selection: $prefs.rumbleIntensity) {
                        ForEach(rumbleSteps, id: \.self) { step in
                            Text("\(step)%").tag(step)
                        }
                    }
                    .onChange(of: prefs.rumbleIntensity) { _ in
                        prefs.rumbleIntensity = StreamPreferences.clampRumbleIntensity(prefs.rumbleIntensity)
                        prefs.save()
                    }
                }
                Toggle("Adaptive Triggers", isOn: $prefs.adaptiveTriggersEnabled)
                    .onChange(of: prefs.adaptiveTriggersEnabled) { _ in prefs.save() }
            }

            Section("Remote Play") {
                Picker("Resolution", selection: $prefs.resolutionIndex) {
                    ForEach(0..<kResolutions.count, id: \.self) { i in
                        Text(kResolutions[i].label).tag(i)
                    }
                }
                .onChange(of: prefs.resolutionIndex) { _ in prefs.save() }

                Picker("FPS", selection: $prefs.fps) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .onChange(of: prefs.fps) { _ in prefs.save() }

                Picker("Bitrate", selection: $prefs.bitrate) {
                    ForEach(bitrateSteps, id: \.self) { kbps in
                        if kbps == 0 {
                            Text("Auto (\(prefs.autoBitrate) kbps)").tag(0)
                        } else {
                            Text("\(kbps) kbps").tag(kbps)
                        }
                    }
                }
                .onChange(of: prefs.bitrate) { _ in prefs.save() }

                Picker("Codec", selection: $prefs.codec) {
                    Text("H.264").tag(0)
                    Text("H.265 (PS5 only)").tag(1)
                }
                .onChange(of: prefs.codec) { _ in prefs.save() }

                Toggle("Performance stats overlay", isOn: $prefs.streamStatsOverlayEnabled)
                    .onChange(of: prefs.streamStatsOverlayEnabled) { _ in prefs.save() }
            }

            Section("Registered Consoles") {
                if hostStore.registeredHosts.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hostStore.registeredHosts) { host in
                        HStack {
                            Text(host.serverNickname ?? host.serverMacString)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                hostStore.deleteRegisteredHost(host)
                            }
                        }
                    }
                }
            }

            Section("Reset") {
                Button("Reset All Data", role: .destructive) {
                    showResetAlert = true
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(String(cString: pylux_version_string()))
                        .foregroundStyle(.secondary)
                }
                NavigationLink("License & Disclaimer") {
                    LicenseView()
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { psnLoggedIn = PsnTokenStore.shared.hasTokens || !SecureStore.shared.npsso.isEmpty }
        .sheet(isPresented: $showLogin, onDismiss: {
            psnLoggedIn = PsnTokenStore.shared.hasTokens || !SecureStore.shared.npsso.isEmpty
        }) {
            TVLoginView {
                psnLoggedIn = true
                let npsso = SecureStore.shared.npsso
                if !npsso.isEmpty {
                    hostStore.exchangeNpssoAndDiscover(npsso)
                }
            }
        }
        .alert("Reset All Data?", isPresented: $showResetAlert) {
            Button("Reset Everything", role: .destructive) {
                SecureStore.shared.clearAll()
                hostStore.registeredHosts = []
                hostStore.manualHosts = []
                hostStore.psnHosts = []
                prefs = StreamPreferences()
                prefs.save()
                psnLoggedIn = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all registered consoles, account credentials, and saved settings.")
        }
    }

    private func signOut() {
        PsnTokenStore.shared.clearTokens()
        SecureStore.shared.npsso = ""
        hostStore.psnHosts = []
        psnLoggedIn = false
    }
}
