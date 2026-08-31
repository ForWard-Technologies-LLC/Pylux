// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Focusable numeric pad for PIN entry on tvOS (Siri Remote / game controller).

import SwiftUI

struct TVDigitPad: View {
    @Binding var value: String
    var maxLength: Int = 8
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text(display)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(8)
                .frame(minHeight: 48)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(1...9, id: \.self) { d in
                    digitButton(String(d))
                }
                Button("Clear") {
                    value = ""
                }
                .buttonStyle(.bordered)
                digitButton("0")
                Button("Delete") {
                    if !value.isEmpty { value.removeLast() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 420)

            if let onSubmit {
                Button("Submit", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(value.count != maxLength)
            }
        }
    }

    private var display: String {
        if value.isEmpty { return String(repeating: "•", count: maxLength) }
        let shown = value + String(repeating: "•", count: max(0, maxLength - value.count))
        return shown
    }

    private func digitButton(_ label: String) -> some View {
        Button(label) {
            guard value.count < maxLength else { return }
            value.append(label)
        }
        .buttonStyle(.bordered)
        .font(.title)
    }
}
