// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Session lifecycle matching Android's StreamSession.kt exactly

import Combine
import Foundation
import os.log

private let sessionLog = OSLog(subsystem: "com.pylux.stream", category: "StreamSession")

/// Connect parameters matching Android's ConnectInfo data class
struct StreamConnectInfo: Identifiable {
    let id = UUID()
    var host: String
    var ps5: Bool
    var registKey: Data  // 16 bytes
    var morning: Data    // 16 bytes
    var videoWidth: UInt32
    var videoHeight: UInt32
    var videoMaxFps: UInt32
    var videoBitrate: UInt32
    var videoCodec: Int  // 0=H264, 1=H265, 2=H265_HDR
    // PSN holepunch fields (optional, nil/empty for local connections)
    var duid: String?           // PSN device UID hex string
    var psnToken: String?       // PSN OAuth2 access token
    var psnAccountId: String?   // Base64-encoded 8-byte account ID
    var autoRegist: Bool = false
    // Cloud streaming fields (optional, nil/0 for non-cloud connections)
    var serviceType: Int = 0          // 0=REMOTE_PLAY, 1=PSNOW, 2=PSCLOUD
    var cloudLaunchSpec: String?      // base64-encoded launch specification
    var cloudHandshakeKey: String?    // base64-encoded handshake key
    var cloudSessionId: String?       // Gaikai session ID
    var cloudPort: UInt16 = 0         // cloud streaming port
    var cloudPsnWrapperType: UInt8 = 0 // last octet of private IP
    var cloudMtuIn: UInt32 = 0
    var cloudMtuOut: UInt32 = 0
    var cloudRttUs: UInt64 = 0

    /// Whether this is a PSN holepunch connection (matches Android's StreamSession check)
    var isPsnConnection: Bool {
        guard let duid = duid, !duid.isEmpty,
              let token = psnToken, !token.isEmpty else { return false }
        return true
    }

    /// Whether this is a cloud streaming connection
    var isCloudConnection: Bool {
        return serviceType == 1 || serviceType == 2
    }
}

/// Snapshot of the live stream stats for the on-screen overlay. Every value is
/// computed in libchiaki (shared with Qt/Android) — the client only renders them.
struct StreamMetrics {
    let bitrateMbps: Double
    let packetLoss: Double // 0..1
    let droppedFrames: UInt64
    let fps: Double
    let rttMs: Double
    let width: Int
    let height: Int
}

@MainActor
final class StreamSession: ObservableObject {
    @Published private(set) var state: StreamState = .idle
    /// Shown on the connecting overlay (holepunch, STUN, session setup).
    @Published private(set) var connectionPhase: String = ""
    /// Published when auto-registration succeeds (caller should save to HostStore)
    @Published private(set) var autoRegisteredHost: RegisteredHost?
    /// Bumped each time the OPTIONS+SHARE chord fires, so the view surfaces the in-stream menu.
    @Published private(set) var menuRequestToken: Int = 0

    let connectInfo: StreamConnectInfo
    let input: StreamInput
    let pipManager = PictureInPictureManager()
    private var sessionRef: ChiakiSessionRef?
    private var videoDecoder: PyluxVideoDecoder?
    /// Stored view so we can attach when decoder becomes available (matches Android's stored surface).
    private weak var pendingVideoView: StreamVideoUIView?
    private var eventReceiver: SessionEventReceiver?
    /// Holepunch session for PSN connections (kept alive for session lifetime)
    private var holepunchSession: PyluxHolepunchSession?
    /// Chiaki `CHIAKI_EVENT_RUMBLE` → Core Haptics (when `rumbleEnabled`).
    private var rumbleFeedback: StreamRumbleFeedback?
    /// Cached from `StreamPreferences` (refreshed on `resume()` and `.streamPreferencesDidChange`) — avoids keychain read on every rumble packet.
    private var rumbleEffectsEnabled: Bool
    /// Rumble strength percent (0–500, 100 = 1x), cached like `rumbleEffectsEnabled`.
    private var rumbleIntensity: Int
    /// Console-side DualSense intensity settings (HapticIntensity/TriggerIntensity
    /// events), applied like Qt: rumble amplitude is scaled, trigger effects are
    /// scaled and fully skipped when the console says Off.
    private var consoleRumbleScale: Float = 1.0
    private var consoleTriggerScale: Float = 1.0

    /// Qt's multipliers for ChiakiDualSenseEffectIntensity (0=Off,1=Strong,2=Medium,3=Weak).
    private static func intensityScale(_ raw: Int32) -> Float {
        switch raw {
        case 0: return 0
        case 2: return 0.5
        case 3: return 0.33
        default: return 1.0
        }
    }
    private var adaptiveTriggersEnabled: Bool
    private var streamPrefsObserver: NSObjectProtocol?

    init(connectInfo: StreamConnectInfo, input: StreamInput) {
        self.connectInfo = connectInfo
        self.input = input
        let prefs = StreamPreferences.load()
        rumbleEffectsEnabled = prefs.rumbleEnabled
        rumbleIntensity = prefs.rumbleIntensity
        adaptiveTriggersEnabled = prefs.adaptiveTriggersEnabled
        input.controllerStateChangedCallback = { [weak self] statePtr in
            guard let self = self, let ref = self.sessionRef else { return }
            _ = chiaki_session_bridge_set_controller_state(ref, statePtr)
        }
        streamPrefsObserver = NotificationCenter.default.addObserver(
            forName: .streamPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let prefs = StreamPreferences.load()
                self?.rumbleEffectsEnabled = prefs.rumbleEnabled
                self?.rumbleIntensity = prefs.rumbleIntensity
                let triggers = prefs.adaptiveTriggersEnabled
                if self?.adaptiveTriggersEnabled == true && !triggers {
                    StreamTriggerFeedback.reset(controller: self?.input.currentController) // don't leave a resistance latched
                }
                self?.adaptiveTriggersEnabled = triggers
            }
        }
    }

    deinit {
        if let obs = streamPrefsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func resume() {
        guard state == .idle else { return }
        let resumePrefs = StreamPreferences.load()
        rumbleEffectsEnabled = resumePrefs.rumbleEnabled
        rumbleIntensity = resumePrefs.rumbleIntensity
        state = .connecting
        if connectInfo.isPsnConnection {
            connectionPhase = "Preparing internet connection…"
        } else if connectInfo.isCloudConnection {
            connectionPhase = "Connecting to cloud…"
        } else {
            connectionPhase = "Connecting to console…"
        }

        let info = connectInfo
        if info.isCloudConnection {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Using cloud streaming connection path (serviceType=\(info.serviceType))")
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.createAndStartSession(connectInfo: info, holepunchPtr: 0)
            }
        } else if info.isPsnConnection {
            // PSN connection: perform holepunch then create session on a SINGLE dedicated thread.
            // Matches Android: all holepunch calls + session_init + session_start on one Thread.
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Using PSN holepunch connection path (single thread)")
            let thread = Thread { [weak self] in
                self?.resumePsnConnectionOnThread(connectInfo: info)
            }
            thread.qualityOfService = .userInitiated
            thread.name = "PyluxPsnConnection"
            thread.start()
        } else {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Using local connection path")
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.createAndStartSession(connectInfo: info, holepunchPtr: 0)
            }
        }
    }

    func pause() {
        shutdown()
    }

    func shutdown() {
        os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] shutdown: session=\(sessionRef != nil)")
        pipManager.tearDown()
        rumbleFeedback?.shutdown()
        rumbleFeedback = nil
        if let ref = sessionRef {
            sessionRef = nil
            holepunchSession?.markConsumed()
            holepunchSession = nil
            // Stop signals the session thread to exit. The owning join task (started in
            // createAndStartSession / createAndStartSessionSync) will unblock and handle free.
            chiaki_session_bridge_stop(ref)
        } else {
            let hpSession = holepunchSession
            holepunchSession = nil
            DispatchQueue.global(qos: .userInitiated).async { [hpSession] in
                hpSession?.fini()
            }
            eventReceiver?.invalidate()
        }
        eventReceiver = nil
        // Do NOT nil videoDecoder here: session callback may still run until chiaki_session_bridge_join
        // completes. The join task (started in createAndStartSession/createAndStartSessionSync) will nil it.
        connectionPhase = ""
        state = .idle
    }

    func sendLoginPin(_ pin: String) {
        guard let ref = sessionRef else { return }
        let pinBytes = Array(pin.utf8)
        _ = chiaki_session_bridge_set_login_pin(ref, pinBytes, pinBytes.count)
    }

    /// Latest live stream metrics for the stats overlay, or nil if no session is active.
    func metrics() -> StreamMetrics? {
        guard let ref = sessionRef else { return nil }
        var m = ChiakiSessionBridgeMetrics()
        chiaki_session_bridge_get_metrics(ref, &m)
        return StreamMetrics(
            bitrateMbps: m.bitrate_mbps,
            packetLoss: m.packet_loss,
            droppedFrames: m.dropped_frames,
            fps: m.fps,
            rttMs: m.rtt_ms,
            width: Int(m.width),
            height: Int(m.height)
        )
    }

    /// Attach display layer for video output. Call when view is ready and again when session connects.
    /// Stores view so we can attach when decoder becomes available (matches Android's stored surface).
    func attachToView(_ view: StreamVideoUIView) {
        pendingVideoView = view
        let layer = view.videoDisplayLayer
        let bounds = layer?.bounds ?? .zero
        os_log(.default, log: sessionLog, "[StreamSession] attachToView decoder=%{public}@ layer=%{public}@ view.bounds=%.0fx%.0f",
               videoDecoder != nil ? "set" : "nil", layer != nil ? "ok" : "nil", bounds.width, bounds.height)
        videoDecoder?.setDisplayLayer(layer)
        if let layer = layer {
            pipManager.configure(with: layer)
        }
    }

    // MARK: - PSN Holepunch connection on single dedicated thread (matches Android exactly)

    private func resumePsnConnectionOnThread(connectInfo: StreamConnectInfo) {
        guard let duid = connectInfo.duid, let psnToken = connectInfo.psnToken else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.state = .createError(errorCode: -1, message: nil)
            }
            return
        }

        os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Starting PSN holepunch on dedicated thread (duid=\(duid.prefix(16)))")

        // Step 1: Initialize holepunch session
        guard let hpSession = PyluxHolepunchSession(token: psnToken) else {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Failed to init holepunch session")
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.state = .createError(errorCode: -1, message: nil)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.holepunchSession = hpSession
            self?.connectionPhase = "Checking local network (UPnP)…"
        }

        // Step 2: UPnP discover (non-fatal)
        let upnpErr = hpSession.upnpDiscover()
        if upnpErr != 0 { os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] UPnP discover failed (non-fatal): \(upnpErr)") }

        DispatchQueue.main.async { [weak self] in self?.connectionPhase = "Creating online session…" }

        // Step 3: Create session on PSN server
        let createErr = hpSession.createSession()
        if createErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch session create failed: \(createErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.holepunchSession = nil
                self?.state = .createError(errorCode: Int32(createErr), message: nil)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in self?.connectionPhase = "Sending connection details to console…" }

        // Step 4: Create offer
        let offerErr = hpSession.createOffer()
        if offerErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch create offer failed: \(offerErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.holepunchSession = nil
                self?.state = .createError(errorCode: Int32(offerErr), message: nil)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in self?.connectionPhase = "Starting session with your console…" }

        // Step 5: Start session for console
        let duidBytes = hexStringToBytes(duid)
        let consoleType: PyluxHolepunchConsoleType = connectInfo.ps5 ? .PS5 : .PS4
        let startErr = hpSession.start(withDuid: duidBytes, consoleType: consoleType)
        if startErr != 0 {
            let detail = hpSession.lastStartErrorMessage().trimmingCharacters(in: .whitespacesAndNewlines)
            let msg: String? = detail.isEmpty ? nil : detail
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch start failed: \(startErr) — \(detail)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.holepunchSession = nil
                self?.state = .createError(errorCode: Int32(startErr), message: msg)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in self?.connectionPhase = "Punching through NAT (STUN)…" }

        // Step 6: Punch hole for CTRL
        let punchErr = hpSession.punchHole(.CTRL)
        if punchErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch punch hole (CTRL) failed: \(punchErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.holepunchSession = nil
                self?.state = .createError(errorCode: Int32(punchErr), message: nil)
            }
            return
        }
        os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch CTRL hole punched!")

        DispatchQueue.main.async { [weak self] in self?.connectionPhase = "Starting stream…" }

        // Step 7: Create native session with holepunch pointer (all on this same thread)
        let hpPtr = hpSession.nativePtr()
        createAndStartSessionSync(connectInfo: connectInfo, holepunchPtr: hpPtr, hpSession: hpSession)
    }

    // MARK: - Session event handling

    /// Single handler for every bridge session event. BOTH session-creation paths
    /// (the async direct/cloud path and the dedicated-thread PSN path) dispatch
    /// here — the switch used to be duplicated in each and the copies diverged
    /// (the PSN copy was missing the PS-chord case, so the in-stream menu never
    /// opened on PSN sessions). Do not fork this switch again.
    /// `quitReasonStr` arrives separately because `event.quit_reason_str` is a
    /// borrowed C pointer only valid during the callback — the receiver block
    /// copies it into a String before hopping to the main actor.
    private func handleSessionEvent(_ event: ChiakiSessionBridgeEvent, quitReasonStr: String?) {
        switch event.type.rawValue {
        case 0: // ChiakiSessionBridgeEventConnected
            os_log(.default, log: sessionLog, "[StreamSession] Session connected — video starting")
            connectionPhase = ""
            state = .connected
            input.resendMergedControllerStateIfNeeded()
            rumbleFeedback?.shutdown()
            rumbleFeedback = StreamRumbleFeedback(input: input)
            rumbleFeedback?.prepare()
        case 16: // ChiakiSessionBridgeEventPsChord -> surface the in-stream menu
            os_log(.default, log: sessionLog, "[StreamSession] PS chord fired -> requesting in-stream menu")
            menuRequestToken &+= 1
        case 8: // ChiakiSessionBridgeEventRumble
            rumbleFeedback?.applyRumble(
                left: event.rumble_left,
                right: event.rumble_right,
                rumbleEnabled: rumbleEffectsEnabled,
                intensityPercent: Int(Float(rumbleIntensity) * consoleRumbleScale)
            )
        case 10: // ChiakiSessionBridgeEventTriggerEffects
            // Mirror Qt: skip entirely when the console's trigger intensity is Off.
            if adaptiveTriggersEnabled && consoleTriggerScale > 0 {
                let l = withUnsafeBytes(of: event.trigger_left) { Array($0) }
                let r = withUnsafeBytes(of: event.trigger_right) { Array($0) }
                StreamTriggerFeedback.apply(controller: input.currentController,
                                            typeLeft: event.trigger_type_left, left: l,
                                            typeRight: event.trigger_type_right, right: r,
                                            intensityScale: consoleTriggerScale)
            }
        case 14: // ChiakiSessionBridgeEventHapticIntensity (console setting)
            consoleRumbleScale = Self.intensityScale(event.effect_intensity)
        case 15: // ChiakiSessionBridgeEventTriggerIntensity (console setting)
            consoleTriggerScale = Self.intensityScale(event.effect_intensity)
            if consoleTriggerScale == 0 {
                StreamTriggerFeedback.reset(controller: input.currentController)
            }
        case 9: // ChiakiSessionBridgeEventQuit
            rumbleFeedback?.shutdown()
            rumbleFeedback = nil
            StreamTriggerFeedback.reset(controller: input.currentController)
            let quitMsg = quitReasonStr ?? String(format: "reason=0x%08x", event.quit_reason)
            os_log(.error, log: sessionLog, "[StreamSession] Session quit: %{public}s", quitMsg)
            state = .quit(reason: event.quit_reason, reasonString: quitReasonStr)
        case 1: // ChiakiSessionBridgeEventLoginPinRequest
            connectionPhase = ""
            state = .loginPinRequest(pinIncorrect: event.login_pin_incorrect)
        case 3: // ChiakiSessionBridgeEventRegist (auto-registration succeeded)
            let mac = withUnsafeBytes(of: event.regist_server_mac) { Data($0) }
            let nickname = withUnsafeBytes(of: event.regist_server_nickname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let registKey = withUnsafeBytes(of: event.regist_rp_regist_key) { Data($0) }
            let rpKey = withUnsafeBytes(of: event.regist_rp_key) { Data($0) }
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Auto-registration succeeded: \(nickname)")
            autoRegisteredHost = RegisteredHost(
                target: Int(event.regist_target),
                serverMac: mac,
                serverNickname: nickname,
                rpRegistKey: registKey,
                rpKeyType: Int(event.regist_rp_key_type),
                rpKey: rpKey
            )
        default:
            break
        }
    }

    /// Shared receiver setup: copy the C event struct and hand it to
    /// handleSessionEvent on the main actor.
    private nonisolated func makeSessionEventReceiver() -> SessionEventReceiver {
        let receiver = SessionEventReceiver()
        receiver.eventBlock = { [weak self] eventPtr in
            guard let self = self, let eventPtr = eventPtr else { return }
            let event = eventPtr.assumingMemoryBound(to: ChiakiSessionBridgeEvent.self).pointee
            // quit_reason_str points into memory the lib frees right after this
            // callback returns — copy it NOW, before the async hop.
            let quitReasonStr = event.quit_reason_str.map { String(cString: $0) }
            Task { @MainActor in
                self.handleSessionEvent(event, quitReasonStr: quitReasonStr)
            }
        }
        return receiver
    }

    // MARK: - Create and start native session

    private nonisolated func createAndStartSession(connectInfo: StreamConnectInfo, holepunchPtr: UInt) async {
        let receiver = makeSessionEventReceiver()

        await MainActor.run { [weak self] in
            if connectInfo.isCloudConnection {
                self?.connectionPhase = "Preparing cloud stream…"
            } else {
                self?.connectionPhase = "Opening session with console…"
            }
        }

        let decoder = PyluxVideoDecoder(
            width: Int32(connectInfo.videoWidth),
            height: Int32(connectInfo.videoHeight),
            // Treat H265_HDR like H265 for the hardware decoder path.
            codec: (connectInfo.videoCodec == 1 || connectInfo.videoCodec == 2)
                ? PyluxVideoCodec(rawValue: 1)!
                : PyluxVideoCodec(rawValue: 0)!
        )

        var cInfo = ChiakiSessionBridgeConnectInfo()
        var err: Int32 = 0

        // Decode base64 PSN account ID to 8 raw bytes (matches Android)
        var accountIdBytes = [UInt8](repeating: 0, count: 8)
        if let accountIdB64 = connectInfo.psnAccountId, !accountIdB64.isEmpty,
           let decoded = Data(base64Encoded: accountIdB64), decoded.count == 8 {
            accountIdBytes = Array(decoded)
        }

        // Cloud string pointers must remain valid during create call
        let cloudLaunchSpec = connectInfo.cloudLaunchSpec ?? ""
        let cloudHandshakeKey = connectInfo.cloudHandshakeKey ?? ""
        let cloudSessionId = connectInfo.cloudSessionId ?? ""

        let ref: ChiakiSessionRef? = connectInfo.host.withCString { hostPtr in
            cloudLaunchSpec.withCString { launchSpecPtr in
                cloudHandshakeKey.withCString { handshakeKeyPtr in
                    cloudSessionId.withCString { sessionIdPtr in
                        cInfo.host = hostPtr
                        cInfo.ps5 = connectInfo.ps5
                        cInfo.video_width = connectInfo.videoWidth
                        cInfo.video_height = connectInfo.videoHeight
                        cInfo.video_max_fps = connectInfo.videoMaxFps
                        cInfo.video_bitrate = connectInfo.videoBitrate
                        cInfo.video_codec = Int32(connectInfo.videoCodec)
                        // Always true, matching Qt and Android: a Remote Play PS5 sends rumble
                        // ONLY as DualSense haptic audio (a DualShock4-declared client gets no
                        // motor data at all), so gating this on an attached DualSense left RP
                        // rumble silent whenever the controller enumerated after session
                        // creation. The haptics sink below converts the haptic audio back to
                        // normal rumble events. Harmless for cloud (PSNOW/PSCLOUD verified).
                        cInfo.enable_dualsense = true
                        cInfo.holepunch_session = holepunchPtr
                        cInfo.auto_regist = connectInfo.autoRegist
                        // Cloud streaming fields (matching Android JNI)
                        cInfo.service_type = Int32(connectInfo.serviceType)
                        cInfo.cloud_launch_spec = connectInfo.cloudLaunchSpec != nil ? launchSpecPtr : nil
                        cInfo.cloud_handshake_key = connectInfo.cloudHandshakeKey != nil ? handshakeKeyPtr : nil
                        cInfo.cloud_session_id = connectInfo.cloudSessionId != nil ? sessionIdPtr : nil
                        cInfo.cloud_port = connectInfo.cloudPort
                        cInfo.cloud_psn_wrapper_type = connectInfo.cloudPsnWrapperType
                        cInfo.cloud_mtu_in = connectInfo.cloudMtuIn
                        cInfo.cloud_mtu_out = connectInfo.cloudMtuOut
                        cInfo.cloud_rtt_us = connectInfo.cloudRttUs
                        _ = withUnsafeMutableBytes(of: &cInfo.regist_key) { buf in
                            connectInfo.registKey.copyBytes(to: buf, count: min(16, connectInfo.registKey.count))
                        }
                        _ = withUnsafeMutableBytes(of: &cInfo.morning) { buf in
                            connectInfo.morning.copyBytes(to: buf, count: min(16, connectInfo.morning.count))
                        }
                        withUnsafeMutableBytes(of: &cInfo.psn_account_id) { buf in
                            accountIdBytes.withUnsafeBytes { src in
                                buf.copyMemory(from: src)
                            }
                        }
                        return withUnsafeMutablePointer(to: &cInfo) { ptr in
                            chiaki_session_bridge_create(ptr, pylux_session_event_callback, receiver.retainedOpaquePointer(), &err)
                        }
                    }
                }
            }
        }

        guard let ref = ref else {
            let capturedErr = err
            await MainActor.run { [weak self] in
                self?.connectionPhase = ""
                self?.state = .createError(errorCode: capturedErr != 0 ? capturedErr : 1, message: nil)
            }
            return
        }

        chiaki_session_bridge_set_ps_chord(ref, true, 0) // always on: safe, no user toggle
        // Unconditional (matching enable_dualsense above): the console delivers rumble
        // as DualSense haptic-audio; convert it back to rumble events for whatever
        // controller is (or later becomes) attached.
        chiaki_session_bridge_enable_haptics_rumble(ref)

        await MainActor.run { [weak self] in
            self?.connectionPhase = connectInfo.isCloudConnection ? "Starting cloud stream…" : "Starting stream…"
            if holepunchPtr != 0 {
                self?.holepunchSession?.markConsumed()
                self?.holepunchSession = nil
            }
            self?.sessionRef = ref
            self?.videoDecoder = decoder
            self?.eventReceiver = receiver
            // Attach stored view immediately (matches Android: setSurface when session created)
            if let view = self?.pendingVideoView, let layer = view.videoDisplayLayer {
                let b = layer.bounds
                os_log(.default, log: sessionLog, "[StreamSession] attaching stored view to new decoder layer.bounds=%.0fx%.0f", b.width, b.height)
                decoder.setDisplayLayer(layer)
            } else {
                os_log(.default, log: sessionLog, "[StreamSession] no stored view to attach (pendingVideoView=%{public}@)", self?.pendingVideoView != nil ? "set" : "nil")
            }
        }

        // Now safe to set callbacks - decoder/receiver are retained by self
        chiaki_session_bridge_set_video_sample_cb(ref, PyluxVideoDecoderVideoSampleCallback, Unmanaged.passUnretained(decoder).toOpaque())

        let startErr = chiaki_session_bridge_start(ref)
        if startErr != 0 {
            chiaki_session_bridge_free(ref)
            await MainActor.run { [weak self] in
                self?.connectionPhase = ""
                self?.sessionRef = nil
                self?.videoDecoder = nil
                self?.eventReceiver = nil
                self?.state = .createError(errorCode: startErr, message: nil)
            }
            return
        }

        // Single ownership: this background task is the sole place that joins and frees.
        // shutdown() only calls stop() to signal exit; it does NOT queue its own join+free.
        let joinRef = ref
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = chiaki_session_bridge_join(joinRef)
            chiaki_session_bridge_free(joinRef)
            Task { @MainActor [weak self] in
                self?.rumbleFeedback?.shutdown()
                self?.rumbleFeedback = nil
                if self?.sessionRef == nil {
                    self?.videoDecoder = nil
                    self?.eventReceiver?.invalidate()
                    self?.eventReceiver = nil
                } else {
                    self?.sessionRef = nil
                    self?.videoDecoder = nil
                    self?.eventReceiver?.invalidate()
                    self?.eventReceiver = nil
                    if self?.state == .connected {
                        self?.connectionPhase = ""
                        self?.state = .idle
                    }
                }
            }
        }
    }

    // MARK: - Synchronous session creation for PSN connections (runs on dedicated thread)

    private func createAndStartSessionSync(connectInfo: StreamConnectInfo, holepunchPtr: UInt, hpSession: PyluxHolepunchSession) {
        let receiver = makeSessionEventReceiver()

        let decoder = PyluxVideoDecoder(
            width: Int32(connectInfo.videoWidth),
            height: Int32(connectInfo.videoHeight),
            // Treat H265_HDR like H265 for the hardware decoder path.
            codec: (connectInfo.videoCodec == 1 || connectInfo.videoCodec == 2)
                ? PyluxVideoCodec(rawValue: 1)!
                : PyluxVideoCodec(rawValue: 0)!
        )

        var accountIdBytes = [UInt8](repeating: 0, count: 8)
        if let accountIdB64 = connectInfo.psnAccountId, !accountIdB64.isEmpty,
           let decoded = Data(base64Encoded: accountIdB64), decoded.count == 8 {
            accountIdBytes = Array(decoded)
        }

        var cInfo = ChiakiSessionBridgeConnectInfo()
        var err: Int32 = 0

        let ref: ChiakiSessionRef? = connectInfo.host.withCString { hostPtr in
            cInfo.host = hostPtr
            cInfo.ps5 = connectInfo.ps5
            cInfo.video_width = connectInfo.videoWidth
            cInfo.video_height = connectInfo.videoHeight
            cInfo.video_max_fps = connectInfo.videoMaxFps
            cInfo.video_bitrate = connectInfo.videoBitrate
            cInfo.video_codec = Int32(connectInfo.videoCodec)
            // Always true, matching Qt and Android -- see createAndStartSession
            // (RP rumble requires it; harmless for cloud).
            cInfo.enable_dualsense = true
            cInfo.holepunch_session = holepunchPtr
            cInfo.auto_regist = connectInfo.autoRegist
            _ = withUnsafeMutableBytes(of: &cInfo.regist_key) { buf in
                connectInfo.registKey.copyBytes(to: buf, count: min(16, connectInfo.registKey.count))
            }
            _ = withUnsafeMutableBytes(of: &cInfo.morning) { buf in
                connectInfo.morning.copyBytes(to: buf, count: min(16, connectInfo.morning.count))
            }
            withUnsafeMutableBytes(of: &cInfo.psn_account_id) { buf in
                accountIdBytes.withUnsafeBytes { src in buf.copyMemory(from: src) }
            }
            return withUnsafeMutablePointer(to: &cInfo) { ptr in
                chiaki_session_bridge_create(ptr, pylux_session_event_callback,
                                             receiver.retainedOpaquePointer(), &err)
            }
        }

        guard let ref = ref else {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Failed to create session: \(err)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.state = .createError(errorCode: err != 0 ? err : 1, message: nil)
            }
            return
        }

        chiaki_session_bridge_set_ps_chord(ref, true, 0) // always on: safe, no user toggle
        // Unconditional (matching enable_dualsense above): the console delivers rumble
        // as DualSense haptic-audio; convert it back to rumble events for whatever
        // controller is (or later becomes) attached.
        chiaki_session_bridge_enable_haptics_rumble(ref)

        // Native session owns holepunch pointer now
        DispatchQueue.main.async { [weak self] in
            self?.holepunchSession?.markConsumed()
            self?.holepunchSession = nil
            self?.sessionRef = ref
            self?.videoDecoder = decoder
            self?.eventReceiver = receiver
            // Attach stored view immediately (matches Android: setSurface when session created)
            if let view = self?.pendingVideoView, let layer = view.videoDisplayLayer {
                let b = layer.bounds
                os_log(.default, log: sessionLog, "[StreamSession] PSN: attaching stored view layer.bounds=%.0fx%.0f", b.width, b.height)
                decoder.setDisplayLayer(layer)
            } else {
                os_log(.default, log: sessionLog, "[StreamSession] PSN: no stored view (pending=%d)", self?.pendingVideoView != nil ? 1 : 0)
            }
        }

        chiaki_session_bridge_set_video_sample_cb(ref, PyluxVideoDecoderVideoSampleCallback, Unmanaged.passUnretained(decoder).toOpaque())

        let startErr = chiaki_session_bridge_start(ref)
        if startErr != 0 {
            chiaki_session_bridge_free(ref)
            receiver.invalidate()
            DispatchQueue.main.async { [weak self] in
                self?.connectionPhase = ""
                self?.sessionRef = nil; self?.videoDecoder = nil; self?.eventReceiver = nil
                self?.state = .createError(errorCode: startErr, message: nil)
            }
            return
        }

        os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] PSN session started")

        // Single ownership: this background task is the sole place that joins and frees.
        // shutdown() only calls stop() to signal exit; it does NOT queue its own join+free.
        let joinRef = ref
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = chiaki_session_bridge_join(joinRef)
            chiaki_session_bridge_free(joinRef)
            Task { @MainActor [weak self] in
                self?.rumbleFeedback?.shutdown()
                self?.rumbleFeedback = nil
                if self?.sessionRef == nil {
                    self?.videoDecoder = nil
                    self?.eventReceiver?.invalidate()
                    self?.eventReceiver = nil
                } else {
                    self?.sessionRef = nil
                    self?.videoDecoder = nil
                    self?.eventReceiver?.invalidate()
                    self?.eventReceiver = nil
                    if self?.state == .connected {
                        self?.state = .idle
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private nonisolated func hexStringToBytes(_ hex: String) -> Data {
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
