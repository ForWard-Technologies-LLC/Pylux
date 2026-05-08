// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

@main
struct PyluxApp: App {
    @UIApplicationDelegateAdaptor(PyluxAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
