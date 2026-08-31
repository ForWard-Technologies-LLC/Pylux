// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

enum TVConsoleVersion: String, CaseIterable, Identifiable {
    case ps5 = "PS5"
    case ps4GE8 = "PS4 >= 8.0"
    case ps4GE7 = "PS4 >= 7.0, < 8"
    case ps4LT7 = "PS4 < 7.0"

    var id: String { rawValue }
    var isPS5: Bool { self == .ps5 }

    var registTarget: PyluxRegistTarget {
        switch self {
        case .ps5: return .PS5
        case .ps4GE8: return .PS4_GE8
        case .ps4GE7: return .PS4_GE7
        case .ps4LT7: return .PS4_LT7
        }
    }
}

struct TVRegistrationView: View {
    @ObservedObject var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host = "255.255.255.255"
    @State private var broadcast = true
    @State private var consoleVersion: TVConsoleVersion = .ps5
    @State private var psnId = ""
    @State private var pin = ""
    @State private var isExecuting = false
    @State private var logText = ""
    @State private var resultMessage: String?
    @State private var registSuccess = false
    @State private var registService: PyluxRegistService?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Register Console")
                    .font(.title)

                TextField("Host (IP or broadcast)", text: $host)
                    .autocorrectionDisabled()

                Toggle("Broadcast", isOn: $broadcast)

                Picker("Console", selection: $consoleVersion) {
                    ForEach(TVConsoleVersion.allCases) { version in
                        Text(version.rawValue).tag(version)
                    }
                }

                if consoleVersion == .ps4LT7 {
                    TextField("Online ID (username)", text: $psnId)
                        .autocorrectionDisabled()
                } else {
                    TextField("Account ID (8 bytes, base64)", text: $psnId)
                        .autocorrectionDisabled()
                }

                Text(consoleVersion.isPS5
                     ? "On the console: Settings → System → Remote Play → Link Device"
                     : "On the console: Settings → Remote Play Connection Settings → Add Device")
                    .foregroundStyle(.secondary)

                Text("PIN")
                    .font(.headline)
                TVDigitPad(value: $pin, maxLength: 8)

                if !isExecuting {
                    Button("Register") { startRegistration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isFormValid)
                } else {
                    ProgressView()
                }

                if !logText.isEmpty {
                    Text(logText)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let msg = resultMessage {
                    Text(msg)
                        .foregroundStyle(registSuccess ? .green : .red)
                }

                if registSuccess {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(40)
        }
        .navigationTitle("Register")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    registService?.stop()
                    dismiss()
                }
            }
        }
    }

    private var isFormValid: Bool {
        !host.isEmpty && pin.count == 8 && !psnId.isEmpty
    }

    private func startRegistration() {
        isExecuting = true
        logText = ""
        resultMessage = nil

        let info = PyluxRegistInfo()
        info.target = consoleVersion.registTarget
        info.host = host
        info.broadcast = broadcast
        info.pin = UInt32(pin) ?? 0

        if consoleVersion == .ps4LT7 {
            info.psnOnlineId = psnId
        } else if let decoded = Data(base64Encoded: psnId), decoded.count == 8 {
            info.psnAccountId = decoded
        }

        registService = PyluxRegistService(info: info) { result, hostData, log in
            isExecuting = false
            logText = log ?? ""
            switch result {
            case .success:
                registSuccess = true
                resultMessage = "Registration successful!"
                if let hd = hostData {
                    let registered = RegisteredHost(
                        target: Int(hd.target),
                        apSsid: hd.apSsid,
                        apBssid: hd.apBssid,
                        apKey: hd.apKey,
                        apName: hd.apName,
                        serverMac: hd.serverMac,
                        serverNickname: hd.serverNickname,
                        rpRegistKey: hd.rpRegistKey,
                        rpKeyType: Int(hd.rpKeyType),
                        rpKey: hd.rpKey
                    )
                    hostStore.addRegisteredHost(registered)
                }
            case .failed:
                resultMessage = "Registration failed."
            case .canceled:
                resultMessage = "Registration canceled."
            @unknown default:
                break
            }
        }
    }
}

struct TVManualHostView: View {
    @ObservedObject var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var selectedRegisteredHostId: UUID?

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Host (IP address)", text: $host)
                    .autocorrectionDisabled()
            }
            Section("Registered Console") {
                Picker("Registered Console", selection: $selectedRegisteredHostId) {
                    Text("Register on first connection").tag(nil as UUID?)
                    ForEach(hostStore.registeredHosts) { rh in
                        Text(rh.serverNickname ?? rh.serverMacString).tag(rh.id as UUID?)
                    }
                }
            }
            Button("Add") {
                hostStore.addManualHost(ManualHost(host: host, registeredHostId: selectedRegisteredHostId))
                dismiss()
            }
            .disabled(host.isEmpty)
        }
        .navigationTitle("Add Console")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
