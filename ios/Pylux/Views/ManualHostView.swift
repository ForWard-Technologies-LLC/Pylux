// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Manual host add/edit matching Android's EditManualConsoleActivity

import SwiftUI

struct ManualHostView: View {
    @ObservedObject var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    var existingHost: ManualHost?

    @State private var host = ""
    @State private var selectedRegisteredHostId: UUID?

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Host (IP address)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
            }

            Section("Registered Console") {
                if hostStore.registeredHosts.isEmpty {
                    Text("No registered consoles. Register on first connection.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Registered Console", selection: $selectedRegisteredHostId) {
                        Text("Register on first Connection").tag(nil as UUID?)
                        ForEach(hostStore.registeredHosts) { rh in
                            Text(rh.serverNickname ?? rh.serverMacString)
                                .tag(rh.id as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                Button(existingHost != nil ? "Save" : "Add") {
                    save()
                }
                .disabled(host.isEmpty)
            }

            if existingHost != nil {
                Section {
                    Button("Delete", role: .destructive) {
                        if let existing = existingHost {
                            hostStore.deleteManualHost(existing)
                        }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(existingHost != nil ? "Edit Console" : "Add Console Manually")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear {
            if let existing = existingHost {
                host = existing.host
                selectedRegisteredHostId = existing.registeredHostId
            }
        }
    }

    private func save() {
        if var existing = existingHost {
            existing.host = host
            existing.registeredHostId = selectedRegisteredHostId
            hostStore.updateManualHost(existing)
        } else {
            let newHost = ManualHost(host: host, registeredHostId: selectedRegisteredHostId)
            hostStore.addManualHost(newHost)
        }
        dismiss()
    }
}
