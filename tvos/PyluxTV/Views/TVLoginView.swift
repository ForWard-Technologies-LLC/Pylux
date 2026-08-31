// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Device-code PSN login for tvOS (no WKWebView). Polls xbgamestream for NPSSO.

import CoreImage
import os.log
import SwiftUI
import UIKit

private let loginLog = OSLog(subsystem: "com.pylux.stream", category: "TVLogin")

struct TVLoginView: View {
    var onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var status = "Preparing login code…"
    @State private var qrImage: UIImage?
    @State private var expired = false
    @State private var pollTask: Task<Void, Never>?

    private let timeout: TimeInterval = 10 * 60

    var body: some View {
        VStack(spacing: 28) {
            Text("Sign in with PlayStation")
                .font(.title)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .background(Color.white)
                    .cornerRadius(8)
            }

            Text(code.isEmpty ? "------" : code)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .tracking(10)

            Text("On your phone or computer, open")
                .foregroundStyle(.secondary)
            Text("xbgamestream.com/psstream")
                .font(.headline)
            Text("and enter the code. Keep this screen private — anyone who sees the code can finish sign-in as you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)

            Text(status)
                .foregroundStyle(expired ? .red : .secondary)

            HStack(spacing: 24) {
                Button("Cancel") { cancelAndDismiss() }
                if expired {
                    Button("Try Again") { start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(40)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
        .onExitCommand { cancelAndDismiss() }
    }

    private func start() {
        pollTask?.cancel()
        expired = false
        code = PyluxLoginService.shared.generateLoginCode()
        qrImage = nil
        status = "Creating login session…"
        pollTask = Task { await runFlow() }
    }

    private func cancelAndDismiss() {
        pollTask?.cancel()
        pollTask = nil
        dismiss()
    }

    @MainActor
    private func runFlow() async {
        let created = await PyluxLoginService.shared.createCode(code)
        guard !Task.isCancelled else { return }
        guard created else {
            status = "Could not create a login code. Try again."
            expired = true
            return
        }
        if let url = PyluxLoginService.shared.getLoginURL(code: code) {
            qrImage = Self.qrImage(from: url.absoluteString)
        }
        status = "Waiting for sign-in on your phone…"
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if Date() >= deadline {
                status = "This code expired. Start again."
                expired = true
                os_log(.info, log: loginLog, "device-code login timed out")
                return
            }
            if let npsso = await PyluxLoginService.shared.checkTokenStatus(code) {
                os_log(.info, log: loginLog, "Received NPSSO token (length: %d)", npsso.count)
                SecureStore.shared.npsso = npsso
                onComplete()
                dismiss()
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func qrImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
