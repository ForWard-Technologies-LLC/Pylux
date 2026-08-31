// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Focus-driven Remote Play home for tvOS.

import os.log
import SwiftUI

private let homeLog = OSLog(subsystem: "com.pylux.stream", category: "TVHome")

struct TVHomeView: View {
    @StateObject private var hostStore = HostStore()
    @State private var selected: DisplayHost?
    @State private var connectInfo: StreamConnectInfo?
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var showRegister = false
    @State private var showManual = false
    @State private var npsso = SecureStore.shared.npsso

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 32) {
                hostList
                    .frame(maxWidth: 520)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(40)
            .navigationTitle("Pylux")
            .toolbar {
                Button {
                    hostStore.setDiscoveryActive(!hostStore.discoveryActive)
                } label: {
                    Label(hostStore.discoveryActive ? "Discovery On" : "Discovery Off",
                          systemImage: hostStore.discoveryActive ? "wifi" : "wifi.slash")
                }
                Button("Sign In") { showLogin = true }
                Button("Register") { showRegister = true }
                Button("Add Host") { showManual = true }
                Button("Settings") { showSettings = true }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshAccount() }
        .fullScreenCover(item: $connectInfo) { info in
            TVStreamView(connectInfo: info)
        }
        .sheet(isPresented: $showLogin, onDismiss: refreshAccount) {
            TVLoginView {
                refreshAccount()
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: refreshAccount) {
            NavigationStack {
                TVSettingsView()
                    .environmentObject(hostStore)
            }
        }
        .sheet(isPresented: $showRegister) {
            NavigationStack {
                TVRegistrationView(hostStore: hostStore)
            }
        }
        .sheet(isPresented: $showManual) {
            NavigationStack {
                TVManualHostView(hostStore: hostStore)
            }
        }
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Consoles")
                .font(.title2)
            if hostStore.displayHosts.isEmpty {
                Text("No consoles found. Turn on discovery, add a host, or sign in to see PSN consoles.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480, alignment: .leading)
            } else {
                List(hostStore.displayHosts) { host in
                    Button {
                        selected = host
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.name ?? host.hostAddress)
                                .font(.headline)
                            Text(subtitle(host))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let host = selected {
                Text(host.name ?? "Console")
                    .font(.largeTitle)
                Text(subtitle(host))
                    .foregroundStyle(.secondary)

                HStack(spacing: 20) {
                    Button("Connect") { connect(host) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!host.isRegistered && host.psnDuid == nil)
                    if host.isRegistered, !host.hostAddress.isEmpty {
                        Button("Wake") { hostStore.wakeupHost(host) }
                    }
                    if let registered = host.registeredHost {
                        Button("Unregister", role: .destructive) {
                            hostStore.deleteRegisteredHost(registered)
                            selected = nil
                        }
                    }
                    if case .manual(let m) = host {
                        Button("Remove Host", role: .destructive) {
                            hostStore.deleteManualHost(m.manualHost)
                            selected = nil
                        }
                    }
                }

                if !host.isRegistered {
                    Text("Register this console before connecting.")
                        .foregroundStyle(.secondary)
                    Button("Register Console") { showRegister = true }
                }
            } else {
                Text("Select a console")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func subtitle(_ host: DisplayHost) -> String {
        var parts: [String] = [host.isPS5 ? "PS5" : "PS4", host.typeName]
        if !host.hostAddress.isEmpty { parts.append(host.hostAddress) }
        if host.isRegistered { parts.append("registered") }
        return parts.joined(separator: " · ")
    }

    private func refreshAccount() {
        let stored = SecureStore.shared.npsso
        npsso = stored
        if !stored.isEmpty {
            hostStore.exchangeNpssoAndDiscover(stored)
        }
    }

    private func connect(_ host: DisplayHost) {
        guard let registered = host.registeredHost else {
            showRegister = true
            return
        }
        let prefs = StreamPreferences.load()
        let res = prefs.resolution
        os_log(.default, log: homeLog, "[CONNECT] nick=%{public}s ps5=%d type=%{public}s",
               registered.serverNickname ?? "nil", host.isPS5 ? 1 : 0, host.typeName)

        if let duid = host.psnDuid, host.hostAddress.isEmpty {
            let tokenStore = PsnTokenStore.shared
            connectInfo = StreamConnectInfo(
                host: "",
                ps5: host.isPS5,
                registKey: registered.rpRegistKey,
                morning: registered.rpKey,
                videoWidth: UInt32(res.width),
                videoHeight: UInt32(res.height),
                videoMaxFps: UInt32(prefs.fps),
                videoBitrate: UInt32(prefs.effectiveBitrate),
                videoCodec: prefs.codec,
                duid: duid,
                psnToken: tokenStore.authToken,
                psnAccountId: tokenStore.accountId
            )
        } else {
            connectInfo = StreamConnectInfo(
                host: host.hostAddress,
                ps5: host.isPS5,
                registKey: registered.rpRegistKey,
                morning: registered.rpKey,
                videoWidth: UInt32(res.width),
                videoHeight: UInt32(res.height),
                videoMaxFps: UInt32(prefs.fps),
                videoBitrate: UInt32(prefs.effectiveBitrate),
                videoCodec: prefs.codec
            )
        }
    }
}
