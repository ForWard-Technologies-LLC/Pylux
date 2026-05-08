//
// OAuth v3 implementation for PSN Remote Play authentication
// Based on research_docs/oauth/IMPLEMENTATION_GUIDE.md
//

#ifndef PSNACCOUNTID_V3_H
#define PSNACCOUNTID_V3_H

#include "settings.h"

#include <QObject>
#include <QNetworkReply>
#include <QNetworkAccessManager>
#include <QUuid>

#include "chiaki/log.h"
#include "chiaki/remote/holepunch.h"

namespace PSNAuthV3 {
    static QString CLIENT_ID = "ba495a24-818c-472b-b12d-ff231c1b5745";
    static QString CLIENT_SECRET = "mvaiZkRsAsI1IBkY";
    static const QString AUTHORIZE_ENDPOINT_V3 = "https://ca.account.sony.com/api/authz/v3/oauth/authorize";
    static const QString TOKEN_ENDPOINT_V3 = "https://ca.account.sony.com/api/authz/v3/oauth/token";
    static const QString REDIRECT_URI = "https://remoteplay.dl.playstation.net/remoteplay/redirect";
    static const QString SCOPES = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update";
}

class PSNAccountIDV3 : public QObject {
    Q_OBJECT

public:
    PSNAccountIDV3(Settings *settings, QObject *parent = nullptr);

    void GetPsnAccountIdFromNpsso(QString npsso);

signals:
    void AccountIDResponse(QString accountId);
    void AccountIDError(const QString& url, const QString& error);
    void Finished();

private:
    QString basicAuthHeader;
    Settings *settings = {};
    QNetworkAccessManager *networkManager = nullptr;
    QString currentNpsso;  // Store the npsso token for saving after successful auth

    static QByteArray to_bytes_little_endian(long long number, int num_bytes) {
        QByteArray byte_array;
        int n = 1;
        if(*(char *)&n == 1) // little endian
        {
            for (int i = 0; i < num_bytes; i++)
            {
                char result = number & 0xFF;
                byte_array.append(result);
                number >>= 8;
            }
        }
        else // big endian
        {
            for (int i = num_bytes - 1; i >= 0; i--)
            {
                char result = (number >> (8 * num_bytes)) & 0xFF;
                byte_array.append(result);
            }    
        }
        return byte_array;
    }

private slots:
    void handleAuthorizationResponse();
    void handleTokenResponse(const QString& url, const QJsonDocument& jsonDocument);
    void handleAccountIdResponse(const QString& url, const QJsonDocument& jsonDocument);
    void handleErrorResponse(const QString& url, const QString& error, const QNetworkReply::NetworkError& err);
    void handleAuthorizationError(QNetworkReply::NetworkError error);

private:
    QNetworkReply *currentAuthorizationReply = nullptr;
};

#endif //PSNACCOUNTID_V3_H

