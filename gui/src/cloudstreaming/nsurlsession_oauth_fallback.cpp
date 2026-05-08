// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Fallback OAuth helper for non-Apple platforms — uses QNetworkAccessManager.

#include "cloudstreaming/nsurlsession_oauth.h"

#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QUrl>

void performNativeOAuthGet(
    const QString &urlString,
    const QString &userAgent,
    const QString &npsso,
    std::function<void(NativeOAuthResult)> callback)
{
    auto *manager = new QNetworkAccessManager();

    QNetworkRequest req{QUrl(urlString)};
    req.setRawHeader("User-Agent", userAgent.toUtf8());
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("Cookie", QString("npsso=%1").arg(npsso).toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::ManualRedirectPolicy);

    QNetworkReply *reply = manager->get(req);

    QObject::connect(reply, &QNetworkReply::finished, [reply, manager, callback]() {
        NativeOAuthResult result;
        result.statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();

        QVariant loc = reply->header(QNetworkRequest::LocationHeader);
        if (loc.isValid())
            result.locationHeader = loc.toUrl().toString();

        if (reply->error() != QNetworkReply::NoError && result.statusCode == 0)
            result.errorMessage = reply->errorString();

        reply->deleteLater();
        manager->deleteLater();
        callback(result);
    });
}
