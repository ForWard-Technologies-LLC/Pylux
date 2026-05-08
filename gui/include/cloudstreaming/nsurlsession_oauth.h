// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Platform-native OAuth HTTP helper (NSURLSession on macOS, QNetworkAccessManager elsewhere).

#ifndef NSURLSESSION_OAUTH_H
#define NSURLSESSION_OAUTH_H

#include <QString>
#include <functional>

struct NativeOAuthResult {
    int statusCode;
    QString locationHeader;
    QString errorMessage;
};

// Perform an OAuth GET request using the platform's native HTTP stack
// (NSURLSession on macOS, QNetworkAccessManager elsewhere).
// The callback is invoked on an arbitrary thread; callers must marshal
// to the Qt event loop themselves.
void performNativeOAuthGet(
    const QString &url,
    const QString &userAgent,
    const QString &npsso,
    std::function<void(NativeOAuthResult)> callback);

#endif // NSURLSESSION_OAUTH_H
