// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Session lifecycle matching Android's StreamSession.kt exactly

import Foundation
import Combine
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

@MainActor
final class StreamSession: ObservableObject {
    @Published private(set) var state: StreamState = .idle
    /// Published when auto-registration succeeds (caller should save to HostStore)
    @Published private(set) var autoRegisteredHost: RegisteredHost?

    let connectInfo: StreamConnectInfo
    let input: StreamInput
    private var sessionRef: ChiakiSessionRef?
    private var videoDecoder: PyluxVideoDecoder?
    private var eventReceiver: SessionEventReceiver?
    /// Holepunch session for PSN connections (kept alive for session lifetime)
    private var holepunchSession: PyluxHolepunchSession?

    init(connectInfo: StreamConnectInfo, input: StreamInput) {
        self.connectInfo = connectInfo
        self.input = input
        input.controllerStateChangedCallback = { [weak self] statePtr in
            guard let self = self, let ref = self.sessionRef else { return }
            _ = chiaki_session_bridge_set_controller_state(ref, statePtr)
        }
    }

    func resume() {
        guard state == .idle else { return }
        state = .connecting

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
        input.stopPolling()
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
        videoDecoder = nil
        state = .idle
    }

    func sendLoginPin(_ pin: String) {
        guard let ref = sessionRef else { return }
        let pinBytes = Array(pin.utf8)
        _ = chiaki_session_bridge_set_login_pin(ref, pinBytes, pinBytes.count)
    }

    /// Attach display layer for video output. Call after session connects.
    func attachToView(_ view: StreamVideoUIView) {
        videoDecoder?.setDisplayLayer(view.videoDisplayLayer)
    }

    // MARK: - PSN Holepunch connection on single dedicated thread (matches Android exactly)

    private func resumePsnConnectionOnThread(connectInfo: StreamConnectInfo) {
        guard let duid = connectInfo.duid, let psnToken = connectInfo.psnToken else {
            DispatchQueue.main.async { [weak self] in self?.state = .createError(errorCode: -1) }
            return
        }

        os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Starting PSN holepunch on dedicated thread (duid=\(duid.prefix(16)))")

        // Step 1: Initialize holepunch session
        guard let hpSession = PyluxHolepunchSession(token: psnToken) else {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Failed to init holepunch session")
            DispatchQueue.main.async { [weak self] in self?.state = .createError(errorCode: -1) }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.holepunchSession = hpSession }

        // Step 2: UPnP discover (non-fatal)
        let upnpErr = hpSession.upnpDiscover()
        if upnpErr != 0 { os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] UPnP discover failed (non-fatal): \(upnpErr)") }

        // Step 3: Create session on PSN server
        let createErr = hpSession.createSession()
        if createErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch session create failed: \(createErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in self?.holepunchSession = nil; self?.state = .createError(errorCode: Int32(createErr)) }
            return
        }

        // Step 4: Create offer
        let offerErr = hpSession.createOffer()
        if offerErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch create offer failed: \(offerErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in self?.holepunchSession = nil; self?.state = .createError(errorCode: Int32(offerErr)) }
            return
        }

        // Step 5: Start session for console
        let duidBytes = hexStringToBytes(duid)
        let consoleType: PyluxHolepunchConsoleType = connectInfo.ps5 ? .PS5 : .PS4
        let startErr = hpSession.start(withDuid: duidBytes, consoleType: consoleType)
        if startErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch start failed: \(startErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in self?.holepunchSession = nil; self?.state = .createError(errorCode: Int32(startErr)) }
            return
        }

        // Step 6: Punch hole for CTRL
        let punchErr = hpSession.punchHole(.CTRL)
        if punchErr != 0 {
            os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch punch hole (CTRL) failed: \(punchErr)")
            hpSession.fini()
            DispatchQueue.main.async { [weak self] in self?.holepunchSession = nil; self?.state = .createError(errorCode: Int32(punchErr)) }
            return
        }
        os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Holepunch CTRL hole punched!")

        // Step 7: Create native session with holepunch pointer (all on this same thread)
        let hpPtr = hpSession.nativePtr()
        createAndStartSessionSync(connectInfo: connectInfo, holepunchPtr: hpPtr, hpSession: hpSession)
    }

    // MARK: - Create and start native session

    private nonisolated func createAndStartSession(connectInfo: StreamConnectInfo, holepunchPtr: UInt) async {
        let receiver = SessionEventReceiver()
        receiver.eventBlock = { [weak self] eventPtr in
            guard let self = self, let eventPtr = eventPtr else { return }
            let event = eventPtr.assumingMemoryBound(to: ChiakiSessionBridgeEvent.self).pointee
            let typeRaw = event.type.rawValue
            Task { @MainActor in
                switch typeRaw {
                case 0: // ChiakiSessionBridgeEventConnected
                    os_log(.default, log: sessionLog, "[StreamSession] Session connected — video starting")
                    self.state = .connected
                    self.input.startPolling()
                case 9: // ChiakiSessionBridgeEventQuit
                    let reasonStr = event.quit_reason_str.map { String(cString: $0) }
                    let quitMsg = reasonStr ?? String(format: "reason=0x%08x", event.quit_reason)
                    os_log(.error, log: sessionLog, "[StreamSession] Session quit: %{public}s", quitMsg)
                    self.state = .quit(reason: event.quit_reason, reasonString: reasonStr)
                case 1: // ChiakiSessionBridgeEventLoginPinRequest
                    self.state = .loginPinRequest(pinIncorrect: event.login_pin_incorrect)
                case 3: // ChiakiSessionBridgeEventRegist (auto-registration succeeded)
                    let mac = withUnsafeBytes(of: event.regist_server_mac) { Data($0) }
                    let nickname = withUnsafeBytes(of: event.regist_server_nickname) {
                        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    let registKey = withUnsafeBytes(of: event.regist_rp_regist_key) { Data($0) }
                    let rpKey = withUnsafeBytes(of: event.regist_rp_key) { Data($0) }
                    os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Auto-registration succeeded: \(nickname)")
                    self.autoRegisteredHost = RegisteredHost(
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
        }

        let decoder = PyluxVideoDecoder(
            width: Int32(connectInfo.videoWidth),
            height: Int32(connectInfo.videoHeight),
            codec: connectInfo.videoCodec == 1 ? PyluxVideoCodec(rawValue: 1)! : PyluxVideoCodec(rawValue: 0)!
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
            await MainActor.run { [weak self] in
                self?.state = .createError(errorCode: err != 0 ? err : 1)
            }
            return
        }

        await MainActor.run { [weak self] in
            if holepunchPtr != 0 {
                self?.holepunchSession?.markConsumed()
                self?.holepunchSession = nil
            }
            self?.sessionRef = ref
            self?.videoDecoder = decoder
            self?.eventReceiver = receiver
        }

        // Now safe to set callbacks - decoder/receiver are retained by self
        chiaki_session_bridge_set_video_sample_cb(ref, PyluxVideoDecoderVideoSampleCallback, Unmanaged.passUnretained(decoder).toOpaque())

        let startErr = chiaki_session_bridge_start(ref)
        if startErr != 0 {
            chiaki_session_bridge_free(ref)
            await MainActor.run { [weak self] in
                self?.sessionRef = nil
                self?.videoDecoder = nil
                self?.eventReceiver = nil
                self?.state = .createError(errorCode: startErr)
            }
            return
        }

        // Single ownership: this background task is the sole place that joins and frees.
        // shutdown() only calls stop() to signal exit; it does NOT queue its own join+free.
        let joinRef = ref
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = chiaki_session_bridge_join(joinRef)
            chiaki_session_bridge_free(joinRef)
            Task { @MainActor in
                if self?.sessionRef == nil {
                    // shutdown() already cleared state; just invalidate receiver
                    self?.eventReceiver?.invalidate()
                    self?.eventReceiver = nil
                } else {
                    // Natural session end — clear everything
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

    // MARK: - Synchronous session creation for PSN connections (runs on dedicated thread)

    private func createAndStartSessionSync(connectInfo: StreamConnectInfo, holepunchPtr: UInt, hpSession: PyluxHolepunchSession) {
        let receiver = SessionEventReceiver()
        receiver.eventBlock = { [weak self] eventPtr in
            guard let self = self, let eventPtr = eventPtr else { return }
            let event = eventPtr.assumingMemoryBound(to: ChiakiSessionBridgeEvent.self).pointee
            let typeRaw = event.type.rawValue
            DispatchQueue.main.async {
                switch typeRaw {
                case 0:
                    os_log(.default, log: sessionLog, "[StreamSession] Session connected — video starting")
                    self.state = .connected; self.input.startPolling()
                case 9:
                    let reasonStr = event.quit_reason_str.map { String(cString: $0) }
                    let quitMsg = reasonStr ?? String(format: "reason=0x%08x", event.quit_reason)
                    os_log(.error, log: sessionLog, "[StreamSession] Session quit: %{public}s", quitMsg)
                    self.state = .quit(reason: event.quit_reason, reasonString: reasonStr)
                case 1: self.state = .loginPinRequest(pinIncorrect: event.login_pin_incorrect)
                case 3:
                    let mac = withUnsafeBytes(of: event.regist_server_mac) { Data($0) }
                    let nickname = withUnsafeBytes(of: event.regist_server_nickname) {
                        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    let registKey = withUnsafeBytes(of: event.regist_rp_regist_key) { Data($0) }
                    let rpKey = withUnsafeBytes(of: event.regist_rp_key) { Data($0) }
                    os_log(.default, log: sessionLog, "%{public}s", "[StreamSession] Auto-registration succeeded: \(nickname)")
                    self.autoRegisteredHost = RegisteredHost(
                        target: Int(event.regist_target), serverMac: mac,
                        serverNickname: nickname, rpRegistKey: registKey,
                        rpKeyType: Int(event.regist_rp_key_type), rpKey: rpKey
                    )
                default: break
                }
            }
        }

        let decoder = PyluxVideoDecoder(
            width: Int32(connectInfo.videoWidth),
            height: Int32(connectInfo.videoHeight),
            codec: connectInfo.videoCodec == 1 ? PyluxVideoCodec(rawValue: 1)! : PyluxVideoCodec(rawValue: 0)!
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
            DispatchQueue.main.async { [weak self] in self?.state = .createError(errorCode: err != 0 ? err : 1) }
            return
        }

        // Native session owns holepunch pointer now
        DispatchQueue.main.async { [weak self] in
            self?.holepunchSession?.markConsumed()
            self?.holepunchSession = nil
            self?.sessionRef = ref
            self?.videoDecoder = decoder
            self?.eventReceiver = receiver
        }

        chiaki_session_bridge_set_video_sample_cb(ref, PyluxVideoDecoderVideoSampleCallback, Unmanaged.passUnretained(decoder).toOpaque())

        let startErr = chiaki_session_bridge_start(ref)
        if startErr != 0 {
            chiaki_session_bridge_free(ref)
            receiver.invalidate()
            DispatchQueue.main.async { [weak self] in
                self?.sessionRef = nil; self?.videoDecoder = nil; self?.eventReceiver = nil
                self?.state = .createError(errorCode: startErr)
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
            Task { @MainActor in
                if self?.sessionRef == nil {
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
