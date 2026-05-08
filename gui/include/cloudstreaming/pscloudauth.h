// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef PSCLOUDAUTH_H
#define PSCLOUDAUTH_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QNetworkReply>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

namespace PSCloudAuthConsts {
    // OAuth credentials for cloud streaming
    static const QString CLIENT_ID = "d5df3976-b7fa-4651-bcc9-05ac9f0cad47";
    static const QString CLIENT_SECRET = "VF8B50Lt0aqyAZH4";
    static const QString TOKEN_URL = "https://ca.account.sony.com/api/authz/v3/oauth/token";
    
    // Scopes required for cloud gaming access
    static const QString SCOPES = "id_token:email id_token:is_child id_token:age openid kamaji:get_privacy_settings user:basicProfile.get user:basicProfile.update";
}

class PSCloudAuth : public QObject {
    Q_OBJECT

public:
    explicit PSCloudAuth(Settings *settings, QObject *parent = nullptr);
    
    // Exchange NPSSO token for access token and id token
    void ExchangeNPSSO(QString npssoToken);

signals:
    void TokenResponse(QString accessToken, QString idToken, int expiresIn);
    void TokenError(QString error);
    void Finished();

private slots:
    void handleAccessTokenResponse(const QString &url, const QJsonDocument &jsonDocument);
    void handleErrorResponse(const QString &url, const QString &error, const QNetworkReply::NetworkError &err);

private:
    Settings *settings;
    QString basicAuthHeader;
};

#endif // PSCLOUDAUTH_H

