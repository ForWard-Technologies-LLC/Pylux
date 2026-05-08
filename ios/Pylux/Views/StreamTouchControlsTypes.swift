// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Shared types for on-screen controls (Android `fragment_controls.xml` / colors).

import UIKit

enum StreamTouchControlsMode {
    case hidden
    case full
    case touchpadOnly
    /// On-screen controls off: only PS (opens stream overlay + sends CHIAKI_CONTROLLER_BUTTON_PS).
    case psOnly
}

// MARK: - Android res/values/colors.xml + drawable proportions (fragment_controls.xml)

enum StreamControlTheme {
    /// `control_primary` #22ffffff
    static let fillIdle = UIColor(white: 1, alpha: CGFloat(0x22) / 255)
    /// `control_pressed` #88ffffff
    static let fillPressed = UIColor(white: 1, alpha: CGFloat(0x88) / 255)
    /// Share / options use SF Symbols; keep alpha closer to the faint fill so the chip does not read “solid” vs shoulders.
    static let auxiliarySymbolAlphaIdle: CGFloat = 0.5
    static let auxiliarySymbolAlphaPressed: CGFloat = 0.78
    /// Touchpad vector: corner 32 in viewWidth 508
    static func touchpadCornerRadius(forWidth w: CGFloat) -> CGFloat { (32 / 508) * w }
}
