// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Stream screen matching Android's StreamActivity

import SwiftUI
import os.log

private let streamViewLog = OSLog(subsystem: "com.pylux.stream", category: "StreamView")

private func chiakiQuitReasonDescription(_ reason: Int32) -> String {
    switch reason {
    case 0: return "Stream stopped normally."
    case 1: return "Stopped."
    case 0x01000001: return "Session request failed (unknown reason)."
    case 0x01000002: return "Connection refused by console. It may be in use or not ready."
    case 0x01000003: return "Remote Play is already in use on the console."
    case 0x01000004: return "Remote Play on the console crashed. Please wait and try again."
    case 0x02000001: return "Control connection failed (unknown)."
    case 0x02000002: return "Control connection refused. Check network settings."
    case 0x04000001: return "Stream connection timed out."
    default:
        return String(format: "Stream ended (code: 0x%08x).", UInt32(bitPattern: reason))
    }
}

enum DisplayMode: String, CaseIterable {
    case fit = "Fit"
    case zoom = "Zoom"
    case stretch = "Stretch"
}

struct StreamView: View {
    let connectInfo: StreamConnectInfo
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: StreamSession
    @State private var showOverlay = true
    @State private var displayMode: DisplayMode = .fit
    @State private var onScreenControls = false
    @State private var touchpadOnly = false
    @State private var showQuitAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showPinAlert = false
    @State private var pinIncorrect = false
    @State private var pinEntry = ""
    @State private var videoHostView: StreamVideoUIView?
    @State private var hideOverlayTask: Task<Void, Never>?

    init(connectInfo: StreamConnectInfo) {
        self.connectInfo = connectInfo
        _session = StateObject(wrappedValue: StreamSession(connectInfo: connectInfo, input: StreamInput()))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StreamVideoView(aspectRatio: 16.0 / 9.0, displayMode: displayMode) { view in
                videoHostView = view
                session.attachToView(view)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(aspectRatioForDisplayMode, contentMode: displayMode == .stretch ? .fill : .fit)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                showOverlay = true
                scheduleHideOverlay()
            }

            // Connecting overlay
            if case .connecting = session.state {
                ProgressView("Connecting...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .foregroundColor(.white)
            }

            // Bottom overlay bar (matches Android's stream overlay)
            if showOverlay {
                VStack {
                    Spacer()
                    overlayBar
                }
                .transition(.move(edge: .bottom))
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            session.resume()
            scheduleHideOverlay()
        }
        .onDisappear { session.pause() }
        .onChange(of: session.state) { newState in
            switch newState {
            case .quit(_, _):
                showQuitAlert = true
            case .createError:
                errorMessage = "Connection failed"
                showErrorAlert = true
            case .loginPinRequest(let incorrect):
                pinIncorrect = incorrect
                pinEntry = ""
                showPinAlert = true
            case .connected:
                if let view = videoHostView {
                    session.attachToView(view)
                }
            default:
                break
            }
        }
        .alert("Stream Ended", isPresented: $showQuitAlert) {
            Button("OK") { dismiss() }
        } message: {
            if case .quit(let reason, let reasonStr) = session.state {
                let msg = reasonStr ?? chiakiQuitReasonDescription(reason)
                Text(msg)
            } else {
                Text("The stream has ended.")
            }
        }
        .alert("Connection Error", isPresented: $showErrorAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(errorMessage)
        }
        .alert(pinIncorrect ? "Incorrect PIN" : "Login PIN Required", isPresented: $showPinAlert) {
            TextField("PIN", text: $pinEntry)
                .keyboardType(.numberPad)
            Button("Submit") {
                session.sendLoginPin(pinEntry)
                pinEntry = ""
            }
            Button("Cancel", role: .cancel) { pinEntry = "" }
        } message: {
            Text(pinIncorrect ? "The PIN was incorrect. Enter the PIN shown on your console." : "Enter the PIN displayed on your console.")
        }
    }

    private var aspectRatioForDisplayMode: CGFloat {
        switch displayMode {
        case .fit, .zoom: return 16.0 / 9.0
        case .stretch: return 16.0 / 9.0
        }
    }

    // MARK: - Overlay bar (matches Android's stream overlay: controls, display mode, disconnect)

    private var overlayBar: some View {
        HStack(spacing: 12) {
            // On-Screen Controls toggle (matches Android's onScreenControlsSwitch)
            Toggle("On-Screen Controls", isOn: $onScreenControls)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .fixedSize()

            // Touchpad Only toggle (matches Android's touchpadOnlySwitch)
            Toggle("Touchpad only", isOn: $touchpadOnly)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .fixedSize()

            Spacer()

            // Display mode toggle group (matches Android's displayModeToggle)
            HStack(spacing: 0) {
                displayModeButton(.fit, icon: "rectangle.arrowtriangle.2.inward")
                displayModeButton(.zoom, icon: "arrow.up.left.and.arrow.down.right")
                displayModeButton(.stretch, icon: "arrow.left.and.right")
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            )

            // Disconnect button (matches Android's disconnectButton)
            Button("Disconnect") {
                session.pause()
                dismiss()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }

    private func displayModeButton(_ mode: DisplayMode, icon: String) -> some View {
        Button {
            displayMode = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(displayMode == mode ? .accentColor : .white.opacity(0.7))
                .frame(width: 48, height: 36)
        }
    }

    private func scheduleHideOverlay() {
        hideOverlayTask?.cancel()
        hideOverlayTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds, matches Android
            if !Task.isCancelled {
                withAnimation { showOverlay = false }
            }
        }
    }
}
