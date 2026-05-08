// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Main screen matching Android's MainActivity (two-tab ViewPager with custom toolbar)

import SwiftUI

struct ContentView: View {
    @StateObject private var hostStore = HostStore()
    /// Main tab: 0 = Remote Play, 1 = Cloud Play.
    @State private var selectedTab = 0
    @State private var showSettings = false
    @State private var showAccountView = false
    @State private var npsso = SecureStore.shared.npsso
    @State private var isLoggedIn = !SecureStore.shared.npsso.isEmpty
    
    // Fixed background color (same for both tabs, matches Cloud Play)
    private let appBgColor = Color(red: 0.06, green: 0.06, blue: 0.09)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom toolbar matching Android's AppBarLayout with island icons
                toolbarView

                TabView(selection: $selectedTab) {
                    RemotePlayView(isLoggedIn: !npsso.isEmpty) {
                        showAccountView = true
                    }
                    .environmentObject(hostStore)
                    .tag(0)

                    CloudPlayView(npssoToken: npsso) {
                        showAccountView = true
                    }
                    .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(appBgColor)
            .preferredColorScheme(.dark)
            .onAppear {
                let storedNpsso = SecureStore.shared.npsso
                if !storedNpsso.isEmpty {
                    hostStore.exchangeNpssoAndDiscover(storedNpsso)
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            // Re-check NPSSO after settings close in case the user just signed in
            let freshNpsso = SecureStore.shared.npsso
            if freshNpsso != npsso {
                npsso = freshNpsso
                if !freshNpsso.isEmpty {
                    hostStore.exchangeNpssoAndDiscover(freshNpsso)
                }
            }
        }) {
            NavigationStack {
                SettingsView()
                    .environmentObject(hostStore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showAccountView, onDismiss: {
            // Re-check NPSSO after account view closes in case the user just signed in
            let freshNpsso = SecureStore.shared.npsso
            if freshNpsso != npsso {
                npsso = freshNpsso
                isLoggedIn = !freshNpsso.isEmpty
                if !freshNpsso.isEmpty {
                    hostStore.exchangeNpssoAndDiscover(freshNpsso)
                }
            }
        }) {
            NavigationStack {
                AccountView(isLoggedIn: $isLoggedIn)
                    .environmentObject(hostStore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showAccountView = false }
                        }
                    }
            }
        }
    }

    // MARK: - Custom toolbar matching Android's MaterialToolbar with island layout
    
    // Pylux blue accent color from logo
    private let pyluxBlue = Color(red: 0.0, green: 0.62, blue: 0.89)  // #009FE3
    private let pyluxBlueGlow = Color(red: 0.0, green: 0.62, blue: 0.89).opacity(0.3)

    private var toolbarView: some View {
        // Overlay layout: title is absolutely centered over the full bar width,
        // independent of the left/right island sizes.
        ZStack {
            // Centered title with subtle glow
            Image("PyluxLogo")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .shadow(color: pyluxBlueGlow, radius: 8, x: 0, y: 0)

            // Left and right islands pinned to edges
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    modeButton(icon: "gamecontroller.fill", tab: 0)
                    modeButton(icon: "cloud.fill", tab: 1)
                }
                .padding(.horizontal, 3)
                .frame(height: 46)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .strokeBorder(pyluxBlue.opacity(0.25), lineWidth: 1)
                        )
                        .shadow(color: pyluxBlueGlow.opacity(0.4), radius: 4, x: 0, y: 0)
                )

                Spacer()

                // Right island: Action icons with blue accent
                HStack(spacing: 0) {
                    if selectedTab == 0 {
                        Button {
                            hostStore.setDiscoveryActive(!hostStore.discoveryActive)
                        } label: {
                            Image(systemName: hostStore.discoveryActive ? "wifi" : "wifi.slash")
                                .font(.system(size: 16))
                                .foregroundColor(hostStore.discoveryActive ? pyluxBlue : .white.opacity(0.7))
                                .frame(width: 44, height: 40)
                        }
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 44, height: 40)
                    }
                }
                .padding(.horizontal, 3)
                .frame(height: 46)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .strokeBorder(pyluxBlue.opacity(0.25), lineWidth: 1)
                        )
                        .shadow(color: pyluxBlueGlow.opacity(0.4), radius: 4, x: 0, y: 0)
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }

    private func modeButton(icon: String, tab: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(selectedTab == tab ? pyluxBlue : .white.opacity(0.4))
                .frame(width: 44, height: 40)
                .background(
                    ZStack {
                        if selectedTab == tab {
                            Capsule()
                                .fill(pyluxBlue.opacity(0.15))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(pyluxBlue.opacity(0.4), lineWidth: 1)
                                )
                                .shadow(color: pyluxBlueGlow, radius: 6, x: 0, y: 0)
                        } else {
                            Capsule().fill(Color.clear)
                        }
                    }
                )
        }
    }

}

#Preview {
    ContentView()
}
