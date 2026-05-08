// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Stream screen matching Android's StreamActivity

import SwiftUI
import UIKit
import os.log

private let streamViewLog = OSLog(subsystem: "com.pylux.stream", category: "StreamView")

private func chiakiQuitReasonDescription(_ reason: Int32) -> String {
    switch reason {
    case 0: return "Stream stopped normally."
    case 1: return "Stopped."
    case 0x01000001: return "Session request failed (unknown reason)."
    case 0x01000002: return "Connection refused by console. It may be in use or not ready."
    case 0x01000003: return "Streaming is already in use on the console."
    case 0x01000004: return "The console ended streaming unexpectedly. Please wait and try again."
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
    @State private var onScreenControls: Bool
    @State private var touchpadOnly: Bool
    @State private var showQuitAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showPinAlert = false
    @State private var pinIncorrect = false
    @State private var pinEntry = ""
    @State private var videoHostView: StreamVideoUIView?
    @State private var hideOverlayTask: Task<Void, Never>?
    @State private var pipClosedByUser = false
    @State private var pipIsPossible = false
    @StateObject private var donationCoordinator = DonationPromptCoordinator.shared

    init(connectInfo: StreamConnectInfo) {
        self.connectInfo = connectInfo
        let prefs = StreamPreferences.load()
        let tpOnly = prefs.touchpadOnlyEnabled
        let fullOn = prefs.onScreenControlsEnabled
        _onScreenControls = State(initialValue: tpOnly ? false : fullOn)
        _touchpadOnly = State(initialValue: tpOnly)
        _session = StateObject(wrappedValue: StreamSession(connectInfo: connectInfo, input: StreamInput()))
    }

    private func persistStreamOverlayPreferences() {
        var p = StreamPreferences.load()
        p.onScreenControlsEnabled = onScreenControls
        p.touchpadOnlyEnabled = touchpadOnly
        p.save()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Full-screen video bounds; fit/zoom/stretch come only from AVLayerVideoGravity (matches Android
            // SurfaceView in a full-screen AspectRatioFrameLayout — a fixed 16:9 SwiftUI box made fit≈zoom for 16:9 streams).
            StreamVideoView(
                aspectRatio: CGFloat(connectInfo.videoWidth) / CGFloat(max(connectInfo.videoHeight, 1)),
                displayMode: displayMode
            ) { view in
                videoHostView = view
                session.attachToView(view)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .clipped()

            // Always show at least PS when full/touchpad controls are off (no tap-to-show overlay anymore).
            StreamTouchControlsOverlayRepresentable(
                mode: touchpadOnly ? .touchpadOnly : (onScreenControls ? .full : .psOnly),
                streamInput: session.input,
                onPSButtonPressed: {
                    showOverlay = true
                    scheduleHideOverlay()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(true)

            // Bottom overlay bar (matches Android's stream overlay)
            if showOverlay {
                VStack {
                    Spacer()
                    overlayBar
                }
                .transition(.move(edge: .bottom))
            }

            // Full-screen connecting overlay (above touch controls so STUN/holepunch is always visible)
            if case .connecting = session.state {
                ZStack {
                    Color.black.opacity(0.62)
                        .ignoresSafeArea()
                    VStack(spacing: 18) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.35)
                        Text(session.connectionPhase.isEmpty ? "Connecting…" : session.connectionPhase)
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        Text("This can take a while on some networks.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                }
                .allowsHitTesting(true)
            }

            // PIN entry in-stream (not .alert TextField, not fullScreenCover): those paths use separate UIKit
            // controllers that can force portrait and fight AppOrientationLock, then crash when rotating back.
            if showPinAlert {
                LoginPinEntryView(
                    pinIncorrect: pinIncorrect,
                    pinEntry: $pinEntry,
                    onSubmit: {
                        let pin = pinEntry
                        pinEntry = ""
                        showPinAlert = false
                        session.sendLoginPin(pin)
                    },
                    onCancel: {
                        pinEntry = ""
                        showPinAlert = false
                        session.pause()
                        dismiss()
                    }
                )
                .zIndex(20_000)
                .allowsHitTesting(true)
            }
        }
        // NavigationStack / fullScreenCover still propose safe-area-inset size to children; expand to physical edges
        // so zoom (resizeAspectFill) can use full width (Android SurfaceView is match_parent).
        .ignoresSafeArea()
        .statusBar(hidden: true)
        .onAppear {
            // Match Android StreamActivity userLandscape (async so presentation from parent is committed).
            DispatchQueue.main.async { AppOrientationLock.lockLandscapeForStream() }
            session.pipManager.pipClosedByUser = { [weak session] in
                session?.pause()
                pipClosedByUser = true
            }
            session.resume()
            scheduleHideOverlay()
        }
        .onChange(of: onScreenControls) { on in
            if on { touchpadOnly = false }
            if !on && !touchpadOnly { session.input.clearTouchOverlayState() }
            persistStreamOverlayPreferences()
        }
        .onChange(of: touchpadOnly) { on in
            if on { onScreenControls = false }
            if !on && !onScreenControls { session.input.clearTouchOverlayState() }
            persistStreamOverlayPreferences()
        }
        .onDisappear {
            session.input.clearTouchOverlayState()
            AppOrientationLock.unlockAfterStream()
            donationCoordinator.cancelScheduledOffer()
            donationCoordinator.flushStreamTime()
            if !session.pipManager.isActive {
                session.pause()
            }
        }
        .sheet(isPresented: $donationCoordinator.showPaywall) {
            DonationPaywallView()
        }
        .onChange(of: session.state) { newState in
            switch newState {
            case .connected:
                if let view = videoHostView {
                    session.attachToView(view)
                }
                donationCoordinator.markConnected()
                donationCoordinator.scheduleOfferIfEligible()
            case .quit(_, _):
                donationCoordinator.cancelScheduledOffer()
                donationCoordinator.flushStreamTime()
                showQuitAlert = true
            case .createError(let code, let message):
                donationCoordinator.cancelScheduledOffer()
                donationCoordinator.flushStreamTime()
                if let m = message, !m.isEmpty {
                    errorMessage = "\(m) (code \(code))"
                } else {
                    errorMessage = "Connection failed (code \(code))"
                }
                showErrorAlert = true
            case .loginPinRequest(let incorrect):
                donationCoordinator.cancelScheduledOffer()
                donationCoordinator.flushStreamTime()
                pinIncorrect = incorrect
                pinEntry = ""
                showPinAlert = true
            case .connecting:
                donationCoordinator.cancelScheduledOffer()
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
        .onChange(of: showPinAlert) { show in
            if show {
                AppOrientationLock.lockLandscapeForStream()
            }
        }
        .onChange(of: pipClosedByUser) { closed in
            if closed { dismiss() }
        }
        .onReceive(session.pipManager.$isPossible) { possible in
            pipIsPossible = possible
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

            // Picture in Picture button
            if pipIsPossible {
                Button {
                    session.pipManager.startIfPossible()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 48, height: 36)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                )
            }

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

// MARK: - Login PIN entry (in-stream overlay; avoids UIAlertController and fullScreenCover)

private struct LoginPinEntryView: View {
    let pinIncorrect: Bool
    @Binding var pinEntry: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @State private var keyboardBottomInset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text(pinIncorrect ? "Incorrect PIN" : "Login PIN required")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(
                    pinIncorrect
                        ? "The PIN was incorrect. Enter the PIN shown on your console."
                        : "Enter the PIN displayed on your console."
                )
                .font(.body)
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                TextField("PIN", text: $pinEntry)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.15)))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 280)
                    .onChange(of: pinEntry) { newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(4))
                        if digits != newValue {
                            pinEntry = digits
                        }
                    }
                HStack(spacing: 24) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .foregroundStyle(.white)
                    Button("Submit", action: onSubmit)
                        .buttonStyle(.borderedProminent)
                        .disabled(pinEntry.count != 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.top, 52)
            .padding(.bottom, 20 + keyboardBottomInset)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            let inset = keyboardBottomOverlap(keyboardFrameScreen: frame)
            withAnimation(.easeOut(duration: duration)) {
                keyboardBottomInset = inset
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardBottomInset = 0
            }
        }
    }

    private func keyboardBottomOverlap(keyboardFrameScreen: CGRect) -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else {
            return max(0, UIScreen.main.bounds.height - keyboardFrameScreen.minY)
        }
        let kbInWindow = window.convert(keyboardFrameScreen, from: nil)
        return max(0, window.bounds.maxY - kbInWindow.minY)
    }
}
