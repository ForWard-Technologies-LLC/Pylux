// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Console registration matching Android's RegistActivity + RegistExecuteActivity

import SwiftUI

enum ConsoleVersion: String, CaseIterable, Identifiable {
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

    var chiakiTarget: Int {
        Int(registTarget.rawValue)
    }
}

struct RegistrationView: View {
    @ObservedObject var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host = "255.255.255.255"
    @State private var broadcast = true
    @State private var consoleVersion: ConsoleVersion = .ps5
    @State private var psnId = ""
    @State private var pin = ""
    @State private var isExecuting = false
    @State private var logText = ""
    @State private var resultMessage: String?
    @State private var registSuccess = false
    @State private var registService: PyluxRegistService?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Icon + title (matches Android's iconImageView + titleTextView)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .padding(.top, 16)

                Text("Register Console")
                    .font(.system(size: 32, weight: .bold))

                // Host field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Host").font(.caption).foregroundColor(.secondary)
                    TextField("Host (IP or broadcast)", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // Broadcast toggle
                Toggle("Broadcast", isOn: $broadcast)

                // Console version (matches Android's ps4VersionRadioGroup)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ConsoleVersion.allCases) { version in
                        Button {
                            consoleVersion = version
                        } label: {
                            HStack {
                                Image(systemName: consoleVersion == version ? "circle.inset.filled" : "circle")
                                    .foregroundColor(.accentColor)
                                Text(version.rawValue)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }

                // PSN Account ID help (matches Android's psnAccountIdHelpGroup)
                if consoleVersion != .ps4LT7 {
                    VStack(spacing: 4) {
                        Text("About obtaining your Account ID, see")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Link("chiaki README",
                             destination: URL(string: "https://git.sr.ht/~thestr4ng3r/chiaki/tree/master/item/README.md#obtaining-your-psn-accountid")!)
                            .font(.caption)
                    }
                }

                // PSN ID field
                VStack(alignment: .leading, spacing: 4) {
                    Text(consoleVersion == .ps4LT7
                         ? "Online ID (username, case-sensitive)"
                         : "Account ID (8 bytes, base64)")
                        .font(.caption).foregroundColor(.secondary)
                    TextField(consoleVersion == .ps4LT7 ? "Online ID" : "Account ID (base64)", text: $psnId)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // PIN instructions (matches Android's pinHelp views)
                VStack(spacing: 4) {
                    Text("On your console, navigate to")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text(consoleVersion.isPS5
                         ? "Settings → System → Remote Play → Link Device"
                         : "Settings → Remote Play Connection Settings → Add Device")
                        .font(.callout)
                        .fontWeight(.bold)
                    Text("to obtain the PIN")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                // PIN field
                VStack(alignment: .leading, spacing: 4) {
                    Text("PIN").font(.caption).foregroundColor(.secondary)
                    TextField("8-digit PIN", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }

                // Register button
                if !isExecuting {
                    Button("Register") {
                        startRegistration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }

                // Execution state (matches Android's RegistExecuteActivity)
                if isExecuting {
                    ProgressView()
                        .padding()
                }

                if !logText.isEmpty {
                    GroupBox("Log") {
                        ScrollView {
                            Text(logText)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }

                if let msg = resultMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundColor(registSuccess ? .green : .red)
                        .fontWeight(.bold)
                }

                if registSuccess {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationTitle("Register Console")
        .navigationBarTitleDisplayMode(.inline)
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
        } else {
            if let decoded = Data(base64Encoded: psnId), decoded.count == 8 {
                info.psnAccountId = decoded
            }
        }

        registService = PyluxRegistService(info: info) { [self] result, hostData, log in
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
