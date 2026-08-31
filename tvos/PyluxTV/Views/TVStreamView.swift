// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// tvOS stream UI: video + controller input. Menu (Siri Remote) confirms disconnect.

import os.log
import SwiftUI
import UIKit

private let streamLog = OSLog(subsystem: "com.pylux.stream", category: "TVStream")

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

struct TVStreamView: View {
    let connectInfo: StreamConnectInfo
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: StreamSession
    @State private var displayMode: DisplayMode = .fit
    @State private var showStats = false
    @State private var statsText = ""
    @State private var lastDroppedFrames: Int64 = -1
    @State private var showDisconnectConfirm = false
    @State private var pinEntry = ""
    @State private var showQuitAlert = false
    @State private var quitMessage = ""
    @State private var errorMessage = ""
    @State private var showErrorAlert = false

    init(connectInfo: StreamConnectInfo) {
        self.connectInfo = connectInfo
        let prefs = StreamPreferences.load()
        _showStats = State(initialValue: prefs.streamStatsOverlayEnabled)
        _session = StateObject(wrappedValue: StreamSession(connectInfo: connectInfo, input: StreamInput()))
    }

    private var isConnected: Bool {
        if case .connected = session.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StreamVideoView(
                aspectRatio: CGFloat(connectInfo.videoWidth) / CGFloat(max(connectInfo.videoHeight, 1)),
                displayMode: displayMode
            ) { view in
                session.attachToView(view)
            }
            .ignoresSafeArea()

            if showStats, isConnected {
                VStack {
                    Text(statsText)
                        .font(.system(size: 18, weight: .regular, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(6)
                    Spacer()
                }
                .padding(.top, 24)
            }

            if case .connecting = session.state {
                VStack(spacing: 18) {
                    ProgressView()
                    Text(session.connectionPhase.isEmpty ? "Connecting…" : session.connectionPhase)
                        .font(.title2)
                    Text("Press Menu to cancel.")
                        .foregroundStyle(.secondary)
                }
                .padding(40)
                .background(Color.black.opacity(0.62))
            }

            if case .loginPinRequest(let incorrect) = session.state {
                VStack(spacing: 20) {
                    Text(incorrect ? "Incorrect PIN — try again" : "Enter console login PIN")
                        .font(.title)
                    TVDigitPad(value: $pinEntry, maxLength: 4) {
                        let pin = pinEntry
                        pinEntry = ""
                        session.sendLoginPin(pin)
                    }
                }
                .padding(40)
                .background(Color.black.opacity(0.85))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.resume()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.pause()
        }
        .onExitCommand {
            showDisconnectConfirm = true
        }
        .onChange(of: session.state) { newState in
            switch newState {
            case .quit(let reason, let reasonString):
                quitMessage = reasonString ?? chiakiQuitReasonDescription(reason)
                showQuitAlert = true
            case .createError(_, let message):
                errorMessage = message ?? "Could not start the stream."
                showErrorAlert = true
            case .loginPinRequest:
                pinEntry = ""
            default:
                break
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateStats()
        }
        .alert("Disconnect?", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                session.pause()
                dismiss()
            }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("Stop Remote Play and return to the console list?")
        }
        .alert("Stream ended", isPresented: $showQuitAlert) {
            Button("OK") {
                session.pause()
                dismiss()
            }
        } message: {
            Text(quitMessage.isEmpty ? "Stream ended." : quitMessage)
        }
        .alert("Connection failed", isPresented: $showErrorAlert) {
            Button("OK") {
                session.pause()
                dismiss()
            }
        } message: {
            Text(errorMessage)
        }
    }

    private func updateStats() {
        guard showStats, isConnected, let m = session.metrics() else { return }
        let drops: Int64 = lastDroppedFrames < 0 ? 0 : max(0, Int64(m.droppedFrames) - lastDroppedFrames)
        lastDroppedFrames = Int64(m.droppedFrames)
        var parts: [String] = []
        parts.append(String(format: "%.1f Mbps", m.bitrateMbps))
        parts.append(String(format: "PL %.1f%%", m.packetLoss * 100.0))
        parts.append("DF/s \(drops)")
        parts.append(String(format: "%.0f FPS", m.fps))
        if m.rttMs > 0 { parts.append(String(format: "%.0f ms", m.rttMs)) }
        parts.append("\(m.width)×\(m.height)")
        statsText = parts.joined(separator: "   •   ")
    }
}
