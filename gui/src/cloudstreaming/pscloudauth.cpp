// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/pscloudauth.h"
#include "cloudstreaming/pskamajisession.h"
#include "jsonrequester.h"
#include "chiaki/remote/holepunch.h"

#include <QObject>
#include <QJsonObject>
#include <QDateTime>
#include <QUrlQuery>

PSCloudAuth::PSCloudAuth(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
{
    basicAuthHeader = JsonRequester::generateBasicAuthHeader(PSCloudAuthConsts::CLIENT_ID, PSCloudAuthConsts::CLIENT_SECRET);
}

void PSCloudAuth::ExchangeNPSSO(QString npssoToken)
{
    qInfo() << "Cloud Auth: Exchanging NPSSO token for access token...";
    
    // Generate DUID dynamically
    size_t duid_size = CHIAKI_DUID_STR_SIZE;
    char duid_arr[duid_size];
    chiaki_holepunch_generate_client_device_uid(duid_arr, &duid_size);
    QString duid = QString(duid_arr);
    qInfo() << "Cloud Auth: Generated DUID:" << duid;
    
    // Build the request body - MUST NOT use .arg() because URL-encoded % will be treated as placeholders!
    // Exact format from successful capture:
    // scope=id_token%3Aemail%20id_token%3Ais_child%20id_token%3Aage%20openid%20kamaji%3Aget_privacy_settings%20user%3AbasicProfile.get%20user%3AbasicProfile.update
    QString encodedScope = QString::fromUtf8(QUrl::toPercentEncoding(PSCloudAuthConsts::SCOPES));
    
    // Build body by concatenation to avoid QString::arg() interpreting % as placeholders
    QString body = "scope=" + encodedScope + 
                   "&npsso=" + npssoToken + 
                   "&client_id=" + PSCloudAuthConsts::CLIENT_ID + 
                   "&client_secret=" + PSCloudAuthConsts::CLIENT_SECRET + 
                   "&grant_type=sso_token" +
                   "&duid=" + duid;
    
    qInfo() << "Cloud Auth: Request body (first 100 chars):" << body.left(100);
    
    // Use PlayStation Now User-Agent (required by API)
    QString userAgent = KamajiConsts::USER_AGENT;
    
    JsonRequester* requester = new JsonRequester(this);
    connect(requester, &JsonRequester::requestFinished, this, &PSCloudAuth::handleAccessTokenResponse);
    connect(requester, &JsonRequester::requestError, this, &PSCloudAuth::handleErrorResponse);
    
    // NO Authorization header for this endpoint - credentials are in the body!
    requester->makePostRequest(PSCloudAuthConsts::TOKEN_URL, "", "application/x-www-form-urlencoded", body, userAgent);
}

void PSCloudAuth::handleAccessTokenResponse(const QString &url, const QJsonDocument &jsonDocument)
{
    QJsonObject jsonObject = jsonDocument.object();
    QString accessToken = jsonObject["access_token"].toString();
    QString idToken = jsonObject["id_token"].toString();
    int expiresIn = jsonObject["expires_in"].toInt();
    
    if (accessToken.isEmpty()) {
        QString errorMsg = "Cloud Auth: Failed to get access token from response";
        qWarning() << errorMsg;
        emit TokenError(errorMsg);
        emit Finished();
        return;
    }
    
    // Calculate expiry timestamp
    QDateTime expiry = QDateTime::currentDateTime().addSecs(expiresIn);
    
    qInfo() << "Cloud Auth: Successfully obtained access token";
    qInfo() << "Cloud Auth: Token expires in" << expiresIn << "seconds (" << expiry.toString() << ")";
    qInfo() << "Cloud Auth: Tokens emitted via signal (not stored - PSCloudAuth is for future catalog API use)";
    
    emit TokenResponse(accessToken, idToken, expiresIn);
    emit Finished();
}

void PSCloudAuth::handleErrorResponse(const QString &url, const QString &error, const QNetworkReply::NetworkError &err)
{
    QString errorMsg = QString("Cloud Auth: Failed to exchange NPSSO token - %1 (Error code: %2)").arg(error).arg(err);
    qWarning() << errorMsg;
    emit TokenError(errorMsg);
    emit Finished();
}

