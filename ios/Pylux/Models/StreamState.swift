// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Stream session state enum

import Foundation

enum StreamState: Equatable {
    case idle
    case connecting
    case connected
    case createError(errorCode: Int32, message: String?)
    case quit(reason: Int32, reasonString: String?)
    case loginPinRequest(pinIncorrect: Bool)
}
