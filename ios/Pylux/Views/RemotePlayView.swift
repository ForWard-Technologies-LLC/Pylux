// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Remote Play tab matching Android's RemotePlayFragment

import SwiftUI
import os.log

private let remotePlayLog = OSLog(subsystem: "com.pylux.stream", category: "RemotePlay")

struct RemotePlayView: View {
    @EnvironmentObject var hostStore: HostStore
    @State private var showFabMenu = false
    @State private var showRegistration = false
    @State private var showAddManual = false
    @State private var showStandbyAlert = false
    @State private var selectedHost: DisplayHost?
    @State private var hostToWakeup: DisplayHost?
    @State private var hostToDelete: DisplayHost?
    @State private var showDeleteAlert = false
    @State private var manualHostToEdit: ManualHost?
    @State private var showUnregisteredAlert = false
    @State private var showPsnRegistTypeAlert = false  // Auto vs Manual for PSN hosts
    @State private var showSignInRequiredAlert = false
    @State private var autoRegistManager: AutoRegistrationManager?
    @State private var connectInfo: StreamConnectInfo?
    
    let isLoggedIn: Bool
    let onSignInTapped: () -> Void

    var body: some View {
        ZStack {
            if hostStore.displayHosts.isEmpty {
                emptyStateView
            } else {
                hostListView
            }

            // FAB - bottom right (matches Android's FloatingActionButton)
            fabOverlay
        }
        .sheet(isPresented: $showRegistration) {
            NavigationStack {
                RegistrationView(hostStore: hostStore)
            }
        }
        .sheet(isPresented: $showAddManual) {
            NavigationStack {
                ManualHostView(hostStore: hostStore)
            }
        }
        .sheet(item: $manualHostToEdit) { mh in
            NavigationStack {
                ManualHostView(hostStore: hostStore, existingHost: mh)
            }
        }
        .sheet(item: $autoRegistManager) { manager in
            AutoRegistrationView(
                manager: manager,
                hostName: selectedHost?.name ?? "Console",
                onSuccess: { registeredHost in
                    hostStore.addRegisteredHost(registeredHost)
                },
                onDismiss: { autoRegistManager = nil }
            )
            .presentationDetents([.medium])
        }
        // Stream fills the cover edge-to-edge (no nav bar / Close): toolbar chrome stole top safe area and
        // misaligned L1/L2 vs dpad; Disconnect in StreamView still ends the session via dismiss().
        .fullScreenCover(item: $connectInfo, onDismiss: { connectInfo = nil }) { info in
            StreamView(connectInfo: info)
        }
        .alert("Console in Standby", isPresented: $showStandbyAlert) {
            Button("Wake Up") {
                if let h = selectedHost { hostStore.wakeupHost(h) }
            }
            Button("Connect") { connectToHost(selectedHost) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The console is currently in standby mode. Do you want to send a Wakeup packet instead of trying to connect immediately?")
        }
        .alert("Not Registered", isPresented: $showUnregisteredAlert) {
            Button("Auto Register") {
                handleAutoRegisterRequest()
            }
            Button("Manual Register") { showRegistration = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This console is not registered. Would you like to register it?")
        }
        .alert("Sign In Required", isPresented: $showSignInRequiredAlert) {
            Button("Sign In") {
                onSignInTapped()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Auto-registration requires you to be signed in. Please sign in to continue.")
        }
        .alert("Registration Type", isPresented: $showPsnRegistTypeAlert) {
            Button("Automatic") {
                if let host = selectedHost, let duid = host.psnDuid {
                    autoRegistManager = AutoRegistrationManager(
                        hostName: host.name ?? "Console",
                        duid: duid,
                        isPS5: host.isPS5
                    )
                }
            }
            Button("Manual") { showRegistration = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let host = selectedHost, !host.isPS5 {
                Text("Would you like to use automatic registration (must be main PS4 console registered to your account)?")
            } else {
                Text("Would you like to use automatic registration?")
            }
        }
        .alert("Remove Console?", isPresented: $showDeleteAlert) {
            Button("Remove", role: .destructive) {
                if case .manual(let mh) = hostToDelete {
                    // Also wipe the registered host data if one is linked
                    if let reg = mh.registeredHost {
                        hostStore.deleteRegisteredHost(reg)
                    }
                    hostStore.deleteManualHost(mh.manualHost)
                }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            if case .manual(let mh) = hostToDelete {
                if mh.registeredHost != nil {
                    Text("This will remove the console entry and permanently delete all saved registration and encryption keys for \(mh.manualHost.host). You will need to re-register to connect again.")
                } else {
                    Text("Are you sure you want to remove the console entry for \(mh.manualHost.host)?")
                }
            }
        }
    }

    // MARK: - Empty state (matches Android's emptyInfoLayout)

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            if let psnError = hostStore.psnError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text(psnError)
                    .font(.subheadline)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            } else if hostStore.psnRefreshing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                Text("Discovering consoles...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: hostStore.discoveryActive ? "wifi" : "wifi.slash")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(hostStore.discoveryActive
                     ? "No consoles added or discovered."
                     : "No consoles added yet.\nEnable Discovery to automatically find consoles on your local network.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
    }

    // MARK: - Host list (matches Android's hostsRecyclerView)

    private var hostListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(hostStore.displayHosts) { host in
                    HostCardView(
                        host: host,
                        onTap: { hostTriggered(host) },
                        onWakeup: host.isRegistered ? { hostStore.wakeupHost(host) } : nil,
                        onEdit: {
                            if case .manual(let mh) = host {
                                manualHostToEdit = mh.manualHost
                            }
                        },
                        onDelete: {
                            hostToDelete = host
                            showDeleteAlert = true
                        }
                    )
                }
            }
            .padding(.bottom, 96) // room for FAB
        }
    }

    // MARK: - FAB with speed dial (matches Android's FloatingActionButton + speed dial)

    private var fabOverlay: some View {
        ZStack {
            // Dimmed background when speed dial expanded
            if showFabMenu {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showFabMenu = false }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 16) {
                        if showFabMenu {
                            if isLoggedIn {
                                fabMenuItem(title: "Refresh Consoles List", icon: "arrow.clockwise") {
                                    hostStore.setDiscoveryActive(true)
                                    showFabMenu = false
                                }
                            } else {
                                fabMenuItem(title: "Sign In to Add Consoles", icon: "person.circle") {
                                    showFabMenu = false
                                    onSignInTapped()
                                }
                            }
                            fabMenuItem(title: "Manually Register Console", icon: "key.fill") {
                                showFabMenu = false
                                showRegistration = true
                            }
                            fabMenuItem(title: "Manually Add Console", icon: "plus.circle.fill") {
                                showFabMenu = false
                                showAddManual = true
                            }
                        }

                        // Main FAB
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                showFabMenu.toggle()
                            }
                        } label: {
                            Image(systemName: showFabMenu ? "xmark" : "plus")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(Circle().fill(Color.accentColor))
                                .shadow(radius: 4)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func fabMenuItem(title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemBackground))
                            .shadow(radius: 2)
                    )
            }

            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(radius: 2)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Host triggered (matches Android's hostTriggered + handlePsnHostTriggered)

    // Matches Android RemotePlayFragment.hostTriggered + handlePsnHostTriggered
    private func hostTriggered(_ host: DisplayHost) {
        os_log(.default, log: remotePlayLog, "hostTriggered: type=%{public}s name=%{public}s registered=%d psnDuid=%{public}s",
               host.typeName, host.name ?? "nil", host.isRegistered ? 1 : 0, host.psnDuid?.prefix(12).description ?? "nil")

        // PSN hosts have their own flow (matches Android handlePsnHostTriggered)
        if case .psn = host {
            selectedHost = host
            if host.isRegistered {
                connectToPsnHost(host)
            } else {
                showPsnRegistTypeAlert = true
            }
            return
        }

        if host.registeredHost != nil {
            // Registered local host
            if case .discovered(let dh) = host,
               dh.discoveredHost.state == .standby {
                selectedHost = host
                showStandbyAlert = true
            } else {
                connectToHost(host)
            }
        } else {
            // Not registered local host (matches Android lines 241-297)
            selectedHost = host
            let hasPsnTokens = PsnTokenStore.shared.hasTokens
            let duid = host.psnDuid
            os_log(.default, log: remotePlayLog, "Unregistered host: hasPsnTokens=%d psnDuid=%{public}s",
                   hasPsnTokens ? 1 : 0, duid?.prefix(12).description ?? "nil")

            if hasPsnTokens, duid != nil {
                // Logged in to PSN AND host has a matching DUID - offer auto or manual
                showPsnRegistTypeAlert = true
            } else {
                // No PSN login or no DUID match - manual only
                showUnregisteredAlert = true
            }
        }
    }

    /// Connect to a local host (matches Android RemotePlayFragment's direct ConnectInfo creation)
    private func connectToHost(_ host: DisplayHost?) {
        guard let host = host, let registered = host.registeredHost else { return }
        let prefs = StreamPreferences.load()
        let res = prefs.resolution
        os_log(.default, log: remotePlayLog, "[CONNECT] Local: host=%{public}s ps5=%d nick=%{public}s",
               host.hostAddress, host.isPS5 ? 1 : 0, registered.serverNickname ?? "nil")
        os_log(.default, log: remotePlayLog, "[CONNECT] registKey(%d): %{public}s",
               registered.rpRegistKey.count,
               registered.rpRegistKey.map { String(format: "%02x", $0) }.joined())
        os_log(.default, log: remotePlayLog, "[CONNECT] morning/rpKey(%d) keyType=%d: %{public}s",
               registered.rpKey.count, registered.rpKeyType,
               registered.rpKey.map { String(format: "%02x", $0) }.joined())
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
    
    /// Handle auto-registration request, checking if user is signed in first
    private func handleAutoRegisterRequest() {
        // Check if user is signed in
        let hasPsnTokens = PsnTokenStore.shared.hasTokens
        
        if !hasPsnTokens {
            // Not signed in - show sign-in required alert
            showSignInRequiredAlert = true
            return
        }
        
        // User is signed in - check if host has DUID
        guard let host = selectedHost, let duid = host.psnDuid else {
            // No DUID available - fall back to manual registration
            os_log(.default, log: remotePlayLog, "Auto-registration attempted but no DUID available, falling back to manual")
            showRegistration = true
            return
        }
        
        // Start auto-registration
        autoRegistManager = AutoRegistrationManager(
            hostName: host.name ?? "Console",
            duid: duid,
            isPS5: host.isPS5
        )
    }

    /// Connect to a PSN host via holepunch (matches Android RemotePlayFragment.handlePsnHostTriggered)
    private func connectToPsnHost(_ host: DisplayHost?) {
        guard let host = host,
              let registered = host.registeredHost,
              let duid = host.psnDuid else { return }
        let prefs = StreamPreferences.load()
        let res = prefs.resolution
        let tokenStore = PsnTokenStore.shared
        let authToken = tokenStore.authToken
        let accountId = tokenStore.accountId
        os_log(.default, log: remotePlayLog, "[CONNECT] PSN: duid=%{public}s ps5=%d nick=%{public}s",
               String(duid.prefix(16)), host.isPS5 ? 1 : 0, registered.serverNickname ?? "nil")
        os_log(.default, log: remotePlayLog, "[CONNECT] registKey(%d): %{public}s",
               registered.rpRegistKey.count,
               registered.rpRegistKey.map { String(format: "%02x", $0) }.joined())
        os_log(.default, log: remotePlayLog, "[CONNECT] morning/rpKey(%d) keyType=%d: %{public}s",
               registered.rpKey.count, registered.rpKeyType,
               registered.rpKey.map { String(format: "%02x", $0) }.joined())
        os_log(.default, log: remotePlayLog, "[CONNECT] authToken present=%d len=%d  accountId present=%d len=%d",
               authToken.isEmpty ? 0 : 1, authToken.count,
               accountId.isEmpty ? 0 : 1, accountId.count)
        connectInfo = StreamConnectInfo(
            host: "",  // No direct IP for PSN connections (matches Android)
            ps5: host.isPS5,
            registKey: registered.rpRegistKey,
            morning: registered.rpKey,
            videoWidth: UInt32(res.width),
            videoHeight: UInt32(res.height),
            videoMaxFps: UInt32(prefs.fps),
            videoBitrate: UInt32(prefs.effectiveBitrate),
            videoCodec: prefs.codec,
            duid: duid,
            psnToken: authToken,
            psnAccountId: accountId
        )
    }

}
