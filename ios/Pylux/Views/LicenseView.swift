// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct LicenseView: View {
    private let licenseText: String

    init() {
        var parts: [String] = []

        if let url = Bundle.main.url(forResource: "agpl_license", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            parts.append(text)
        }

        if let url = Bundle.main.url(forResource: "disclaimer", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            parts.append(text)
        }

        licenseText = parts.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("License")
        .navigationBarTitleDisplayMode(.inline)
    }
}
