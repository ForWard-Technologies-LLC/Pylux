// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Manual ConnectInfo entry form for testing (Phase 5)

import SwiftUI

struct ConnectInfoEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = SecureStore.shared.lastHost
    @State private var registKey = SecureStore.shared.lastRegistKey
    @State private var morning = SecureStore.shared.lastMorning
    @State private var ps5 = SecureStore.shared.lastPs5
    @State private var resolutionIndex = SecureStore.shared.lastResolutionIndex
    @State private var fpsIndex = SecureStore.shared.lastFpsIndex
    @State private var codecIndex = SecureStore.shared.lastCodecIndex
    @State private var connectInfoToStream: StreamConnectInfo?

    private let resolutions: [(w: UInt32, h: UInt32)] = [(1280, 720), (1920, 1080)]
    private let fpsOptions: [UInt32] = [30, 60]
    private let codecs = ["H.264", "H.265"]

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Host (IP)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("PS5", isOn: $ps5)
            }
            Section("Credentials") {
                TextField("Regist Key (hex 32)", text: $registKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Morning (hex 32)", text: $morning)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Video") {
                Picker("Resolution", selection: $resolutionIndex) {
                    Text("720p").tag(0)
                    Text("1080p").tag(1)
                }
                Picker("FPS", selection: $fpsIndex) {
                    Text("30").tag(0)
                    Text("60").tag(1)
                }
                Picker("Codec", selection: $codecIndex) {
                    ForEach(0..<codecs.count, id: \.self) { Text(codecs[$0]).tag($0) }
                }
            }
            Section {
                Button("Connect") {
                    if let info = buildConnectInfo() {
                        saveDefaults()
                        connectInfoToStream = info
                    }
                }
                .disabled(!isValid)
            }
        }
        .navigationTitle("Connect")
        .fullScreenCover(item: $connectInfoToStream) { info in
            NavigationStack {
                StreamView(connectInfo: info)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { connectInfoToStream = nil }
                        }
                    }
            }
        }
    }

    private static let hexSet = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
    private var isValid: Bool {
        host.count >= 7 &&
        registKey.count == 32 && registKey.unicodeScalars.allSatisfy { Self.hexSet.contains($0) } &&
        morning.count == 32 && morning.unicodeScalars.allSatisfy { Self.hexSet.contains($0) }
    }

    private func buildConnectInfo() -> StreamConnectInfo? {
        let ri = clamped(resolutionIndex, min: 0, max: resolutions.count - 1)
        let fi = clamped(fpsIndex, min: 0, max: fpsOptions.count - 1)
        let ci = clamped(codecIndex, min: 0, max: 1)
        let r = resolutions[ri]
        let f = fpsOptions[fi]
        guard let rk = Data(hexString: registKey), rk.count == 16,
              let m = Data(hexString: morning), m.count == 16 else { return nil }
        var rkPadded = rk
        var mPadded = m
        while rkPadded.count < 16 { rkPadded.append(0) }
        while mPadded.count < 16 { mPadded.append(0) }
        let bitrate: UInt32 = r.h == 1080 ? 15000 : 10000
        return StreamConnectInfo(
            host: host,
            ps5: ps5,
            registKey: rkPadded,
            morning: mPadded,
            videoWidth: r.w,
            videoHeight: r.h,
            videoMaxFps: f,
            videoBitrate: bitrate,
            videoCodec: ci
        )
    }

    private func saveDefaults() {
        let s = SecureStore.shared
        s.lastHost = host
        s.lastRegistKey = registKey
        s.lastMorning = morning
        s.lastPs5 = ps5
        s.lastResolutionIndex = resolutionIndex
        s.lastFpsIndex = fpsIndex
        s.lastCodecIndex = codecIndex
    }
}

private func clamped(_ value: Int, min minVal: Int, max maxVal: Int) -> Int {
    Swift.min(Swift.max(value, minVal), maxVal)
}

private extension Data {
    init?(hexString: String) {
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        let s = hexString.filter { hexChars.contains($0.unicodeScalars.first!) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            let byte = UInt8(s[i..<next], radix: 16)
            guard let b = byte else { return nil }
            data.append(b)
            i = next
        }
        self = data
    }
}

