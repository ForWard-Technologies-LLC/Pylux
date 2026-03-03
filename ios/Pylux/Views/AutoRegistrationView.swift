// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Auto-registration via PSN holepunch, matching Android's PsnAutoRegistration exactly.
// KEY: All holepunch + session calls run on a SINGLE dedicated Thread,
// matching Android's Thread { ... }.start() pattern. The chiaki C library
// expects all holepunch calls to happen sequentially on the same thread.

import SwiftUI
import os

private let autoRegLog = OSLog(subsystem: "com.pylux.stream", category: "AutoRegist")

// MARK: - AutoRegistrationManager (matches Android PsnAutoRegistration)

@MainActor
final class AutoRegistrationManager: ObservableObject, Identifiable {
    let id = UUID()
    enum State: Equatable {
        case idle
        case running(status: String)
        case success(nickname: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    let hostName: String
    let duid: String
    let isPS5: Bool
    private var holepunchSession: PyluxHolepunchSession?
    private var sessionRef: ChiakiSessionRef?
    private var eventReceiver: SessionEventReceiver?
    private var cancelled = false
    private var registrationThread: Thread?

    /// Registered host data populated by the regist event callback
    private(set) var registeredHost: RegisteredHost?

    /// Overall timeout for the entire registration process
    private let overallTimeout: TimeInterval = 120

    init(hostName: String, duid: String, isPS5: Bool) {
        self.hostName = hostName
        self.duid = duid
        self.isPS5 = isPS5
    }

    // MARK: - Start (matches Android PsnAutoRegistration.start())

    func start() {
        guard case .idle = state else { return }
        cancelled = false
        state = .running(status: "Starting registration...")
        os_log(.default, log: autoRegLog, "Starting PSN auto-registration for %{public}s (duid=%{public}s)", hostName, String(duid.prefix(16)))

        // Capture all values needed by the thread (avoid accessing @MainActor self from background)
        let hostName = self.hostName
        let duid = self.duid
        let isPS5 = self.isPS5

        // Single dedicated thread for ALL holepunch + session calls.
        // This matches Android's Thread { ... }.start() pattern exactly.
        // The chiaki C holepunch library expects sequential calls from the same thread.
        let thread = Thread { [weak self] in
            self?.runRegistrationOnThread(hostName: hostName, duid: duid, isPS5: isPS5)
        }
        thread.qualityOfService = .userInitiated
        thread.name = "PyluxAutoRegistration"
        registrationThread = thread
        thread.start()
    }

    func cancel() {
        cancelled = true
        holepunchSession?.cancel()
        if let ref = sessionRef {
            chiaki_session_bridge_stop(ref)
        }
        os_log(.default, log: autoRegLog, "Auto-registration cancelled")
    }

    // MARK: - Registration flow (runs entirely on ONE dedicated thread)

    private func runRegistrationOnThread(hostName: String, duid: String, isPS5: Bool) {
        // Helper to update UI state from this background thread
        func postStatus(_ msg: String) {
            os_log(.default, log: autoRegLog, "Status: %{public}s", msg)
            DispatchQueue.main.async { [weak self] in self?.state = .running(status: msg) }
        }
        func postError(_ msg: String) {
            os_log(.error, log: autoRegLog, "Failed: %{public}s", msg)
            DispatchQueue.main.async { [weak self] in self?.state = .failed(message: msg) }
        }
        func postSuccess(_ nickname: String) {
            DispatchQueue.main.async { [weak self] in self?.state = .success(nickname: nickname) }
        }

        // Step 0: Get valid PSN token (auto-refreshes if expired)
        guard let token = PsnTokenManager.shared.getValidToken() else {
            postError("No PSN token available or token refresh failed.")
            return
        }
        let accountId = PsnTokenStore.shared.accountId ?? ""
        os_log(.default, log: autoRegLog, "Got valid PSN token (length=%d), accountId=%{public}s", token.count, String(accountId.prefix(8)))

        // Step 1: Initialize holepunch session (matches Android)
        postStatus("Initializing...")
        guard let hpSession = PyluxHolepunchSession(token: token) else {
            postError("Failed to initialize connection")
            return
        }
        DispatchQueue.main.async { [weak self] in self?.holepunchSession = hpSession }
        if cancelled { cleanup(hpSession: hpSession, session: nil); return }

        // Step 2: UPnP discover (non-fatal, matches Android)
        postStatus("Discovering network...")
        let upnpErr = hpSession.upnpDiscover()
        if upnpErr != 0 {
            os_log(.default, log: autoRegLog, "UPnP discover failed (non-fatal): %d", upnpErr)
        }
        if cancelled { cleanup(hpSession: hpSession, session: nil); return }

        // Step 3: Create session on PSN server (matches Android)
        postStatus("Connecting to PSN...")
        let createErr = hpSession.createSession()
        if createErr != 0 {
            cleanup(hpSession: hpSession, session: nil)
            postError("Failed to create PSN session (error \(createErr))")
            return
        }
        if cancelled { cleanup(hpSession: hpSession, session: nil); return }

        // Step 4: Create offer (matches Android)
        postStatus("Setting up connection...")
        let offerErr = hpSession.createOffer()
        if offerErr != 0 {
            cleanup(hpSession: hpSession, session: nil)
            postError("Failed to create connection offer (error \(offerErr))")
            return
        }
        if cancelled { cleanup(hpSession: hpSession, session: nil); return }

        // Step 5: Start session for specific console (matches Android)
        postStatus("Contacting \(hostName)...")
        let duidBytes = hexStringToBytes(duid)
        let consoleType: PyluxHolepunchConsoleType = isPS5 ? .PS5 : .PS4
        let startErr = hpSession.start(withDuid: duidBytes, consoleType: consoleType)
        if startErr != 0 {
            cleanup(hpSession: hpSession, session: nil)
            postError("Console not responding (error \(startErr))")
            return
        }
        if cancelled { cleanup(hpSession: hpSession, session: nil); return }

        // Step 6: Punch hole for CTRL (matches Android - CTRL only, not DATA)
        postStatus("Establishing connection...")
        let punchErr = hpSession.punchHole(.CTRL)
        if punchErr != 0 {
            cleanup(hpSession: hpSession, session: nil)
            postError("Failed to establish connection (error \(punchErr))")
            return
        }
        if cancelled { cleanup(hpSession: hpSession, session: nil); return }

        os_log(.default, log: autoRegLog, "Hole punched successfully, creating registration session...")

        // Step 7: Create native session with autoRegist=true (matches Android ConnectInfo construction)
        postStatus("Registering \(hostName)...")

        let receiver = SessionEventReceiver()
        receiver.eventBlock = { [weak self] eventPtr in
            guard let self = self, let eventPtr = eventPtr else { return }
            let event = eventPtr.assumingMemoryBound(to: ChiakiSessionBridgeEvent.self).pointee
            let typeRaw = event.type.rawValue
            DispatchQueue.main.async {
                switch typeRaw {
                case 3: // CHIAKI_EVENT_REGIST
                    let mac = withUnsafeBytes(of: event.regist_server_mac) { Data($0) }
                    let nickname = withUnsafeBytes(of: event.regist_server_nickname) {
                        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    let registKey = withUnsafeBytes(of: event.regist_rp_regist_key) { Data($0) }
                    let rpKey = withUnsafeBytes(of: event.regist_rp_key) { Data($0) }
                    os_log(.default, log: autoRegLog, "Auto-registration succeeded: %{public}s", nickname)
                    os_log(.default, log: autoRegLog, "[REGIST KEYS] rpRegistKey(%d): %{public}s",
                           registKey.count, registKey.map { String(format: "%02x", $0) }.joined())
                    os_log(.default, log: autoRegLog, "[REGIST KEYS] rpKey(%d) keyType=%d: %{public}s",
                           rpKey.count, event.regist_rp_key_type, rpKey.map { String(format: "%02x", $0) }.joined())
                    os_log(.default, log: autoRegLog, "[REGIST KEYS] mac: %{public}s  target: %d",
                           mac.map { String(format: "%02x", $0) }.joined(separator: ":"), event.regist_target)
                    self.registeredHost = RegisteredHost(
                        target: Int(event.regist_target),
                        serverMac: mac,
                        serverNickname: nickname,
                        rpRegistKey: registKey,
                        rpKeyType: Int(event.regist_rp_key_type),
                        rpKey: rpKey
                    )
                    self.state = .success(nickname: nickname)
                case 9: // CHIAKI_EVENT_QUIT
                    let isError = chiaki_session_bridge_quit_reason_is_error(event.quit_reason)
                    if isError {
                        let reasonStr = event.quit_reason_str.map { String(cString: $0) }
                        let msg = reasonStr ?? "Registration failed (unknown error)"
                        os_log(.error, log: autoRegLog, "Registration quit with error: %{public}s", msg)
                        if case .success = self.state {
                            // Already succeeded, ignore quit error
                        } else {
                            self.state = .failed(message: msg)
                        }
                    } else {
                        os_log(.default, log: autoRegLog, "Registration session ended normally")
                    }
                default:
                    os_log(.default, log: autoRegLog, "Session event: type=%d", typeRaw)
                }
            }
        }

        // Decode base64 PSN account ID to 8 raw bytes (matches Android)
        var accountIdBytes = [UInt8](repeating: 0, count: 8)
        if !accountId.isEmpty,
           let decoded = Data(base64Encoded: accountId), decoded.count == 8 {
            accountIdBytes = Array(decoded)
        }

        let prefs = StreamPreferences.load()
        let res = prefs.resolution

        var cInfo = ChiakiSessionBridgeConnectInfo()
        var err: Int32 = 0

        // Build connect info (matches Android ConnectInfo + JNI exactly)
        let ref: ChiakiSessionRef? = "".withCString { hostPtr in
            cInfo.host = hostPtr                          // empty string for holepunch (matches Android host="")
            cInfo.ps5 = isPS5
            cInfo.video_width = UInt32(res.width)
            cInfo.video_height = UInt32(res.height)
            cInfo.video_max_fps = UInt32(prefs.fps)
            cInfo.video_bitrate = UInt32(prefs.effectiveBitrate)
            cInfo.video_codec = Int32(prefs.codec)
            cInfo.holepunch_session = hpSession.nativePtr()  // raw C pointer
            cInfo.auto_regist = true                         // KEY: triggers registration mode
            // regist_key and morning are zero (not needed for auto-regist, matches Android)
            withUnsafeMutableBytes(of: &cInfo.psn_account_id) { buf in
                accountIdBytes.withUnsafeBytes { src in
                    buf.copyMemory(from: src)
                }
            }
            return withUnsafeMutablePointer(to: &cInfo) { ptr in
                chiaki_session_bridge_create(ptr, pylux_session_event_callback,
                                             receiver.retainedOpaquePointer(), &err)
            }
        }

        guard let ref = ref else {
            os_log(.error, log: autoRegLog, "Failed to create registration session: %d", err)
            cleanup(hpSession: hpSession, session: nil)
            postError("Failed to create session (error \(err))")
            return
        }

        // Native session now owns the holepunch pointer (matches Android ownership model)
        DispatchQueue.main.async { [weak self] in
            self?.holepunchSession?.markConsumed()
            self?.holepunchSession = nil
            self?.sessionRef = ref
            self?.eventReceiver = receiver
        }

        // Step 8: Start session (chiaki_session_start spawns its own internal thread)
        let startSessionErr = chiaki_session_bridge_start(ref)
        if startSessionErr != 0 {
            chiaki_session_bridge_free(ref)
            receiver.invalidate()
            DispatchQueue.main.async { [weak self] in
                self?.sessionRef = nil
                self?.eventReceiver = nil
                self?.state = .failed(message: "Failed to start session (error \(startSessionErr))")
            }
            return
        }

        os_log(.default, log: autoRegLog, "Session started, waiting for registration result...")

        // Step 9: Wait for session to complete (blocks until session thread exits)
        // This matches Android's session.dispose() which calls sessionJoin + sessionFree
        _ = chiaki_session_bridge_join(ref)
        os_log(.default, log: autoRegLog, "Session joined, cleaning up...")

        // Step 10: Free session (this calls chiaki_session_fini which cleans up holepunch via curl)
        // The websocket thread is now properly joined in chiaki_holepunch_session_fini
        chiaki_session_bridge_free(ref)
        os_log(.default, log: autoRegLog, "Session freed")

        // Invalidate receiver (release the self-retain)
        receiver.invalidate()

        // Final cleanup and state check
        // After join(), all C events have fired. Wait briefly for async handlers to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.sessionRef = nil
            self.eventReceiver = nil
            
            // Check if registration event was received (registeredHost gets set in REGIST event)
            if self.registeredHost == nil {
                // No registration data received - if still running, mark as failed
                if case .running = self.state {
                    self.state = .failed(message: "Registration session ended without result")
                }
            }
        }
    }

    // MARK: - Cleanup (matches Android PsnAutoRegistration.cleanup/dispose)

    /// Cleanup when no native session was created yet.
    /// If a native session WAS created, it owns the holepunch pointer.
    private func cleanup(hpSession: PyluxHolepunchSession?, session: ChiakiSessionRef?) {
        if let session = session {
            // Session owns holepunch - stop + join + free
            chiaki_session_bridge_stop(session)
            _ = chiaki_session_bridge_join(session)
            chiaki_session_bridge_free(session)
            DispatchQueue.main.async { [weak self] in
                self?.holepunchSession?.markConsumed()
                self?.holepunchSession = nil
                self?.sessionRef = nil
            }
        } else if let hp = hpSession {
            // No session created - free holepunch directly
            hp.fini()
            DispatchQueue.main.async { [weak self] in
                self?.holepunchSession = nil
            }
        }
    }

    // MARK: - Helpers

    private func hexStringToBytes(_ hex: String) -> Data {
        let len = hex.count / 2
        var bytes = [UInt8]()
        bytes.reserveCapacity(len)
        var index = hex.startIndex
        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return Data(bytes)
    }
}

// MARK: - AutoRegistrationView (matches Android's showAutoRegistrationDialog)

struct AutoRegistrationView: View {
    @ObservedObject var manager: AutoRegistrationManager
    let hostName: String
    let onSuccess: (RegisteredHost) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Registering \(hostName)")
                .font(.headline)
                .padding(.top, 24)

            switch manager.state {
            case .idle:
                EmptyView()

            case .running(let status):
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.2)
                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

            case .success(let nickname):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("\(nickname) registered successfully!")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            HStack {
                Spacer()
                switch manager.state {
                case .running:
                    Button("Cancel") {
                        manager.cancel()
                        onDismiss()
                    }
                    .foregroundColor(.red)
                case .success:
                    Button("Done") {
                        if let host = manager.registeredHost {
                            onSuccess(host)
                        }
                        onDismiss()
                    }
                    .fontWeight(.medium)
                case .failed:
                    Button("Close") {
                        onDismiss()
                    }
                case .idle:
                    EmptyView()
                }
                Spacer()
            }
            .padding(.bottom, 24)
        }
        .frame(minHeight: 250)
        .onAppear {
            manager.start()
        }
        .onDisappear {
            if case .running = manager.state {
                manager.cancel()
            }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = manager.state { return true }
        return false
    }
}
