// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import UIKit

/// Drives `UIApplicationDelegate.application(_:supportedInterfaceOrientationsFor:)` so streaming can
/// match Android `userLandscape`. `requestGeometryUpdate` alone is often ignored under SwiftUI hosting controllers.
enum AppOrientationLock {
    private static func normalMask() -> UIInterfaceOrientationMask {
        var m: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
        if UIDevice.current.userInterfaceIdiom == .pad {
            m.insert(.portraitUpsideDown)
        }
        return m
    }

    static var maskForAppDelegate: UIInterfaceOrientationMask = normalMask()

    static func lockLandscapeForStream() {
        maskForAppDelegate = .landscape
        apply()
    }

    static func unlockAfterStream() {
        maskForAppDelegate = normalMask()
        apply()
    }

    private static func apply() {
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            guard let scene else { return }

            scene.requestGeometryUpdate(.iOS(interfaceOrientations: maskForAppDelegate)) { _ in }

            for window in scene.windows {
                var vc: UIViewController? = window.rootViewController
                while let current = vc {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = current.presentedViewController
                }
            }
        }
    }
}

final class PyluxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientationLock.maskForAppDelegate
    }
}
