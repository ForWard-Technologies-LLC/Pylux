#include "psnaccountid_v3.h"
#include "jsonrequester.h"

#include <qjsonobject.h>
#include <QObject>
#include <QDebug>
#include <QUrlQuery>
#include <QRegularExpression>
#include <QRandomGenerator>

PSNAccountIDV3::PSNAccountIDV3(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
{
    basicAuthHeader = JsonRequester::generateBasicAuthHeader(PSNAuthV3::CLIENT_ID, PSNAuthV3::CLIENT_SECRET);
    networkManager = new QNetworkAccessManager(this);
}

void PSNAccountIDV3::GetPsnAccountIdFromNpsso(QString npsso) {
    // Store the npsso token so we can save it after successful authentication
    currentNpsso = npsso;
    
    // Generate DUID (Device Unique ID) - REQUIRED for push notification WebSocket
    // Format: "0000000700410080" (16 hex chars) + 16 random bytes (32 hex chars) = 48 hex chars total
    // Reference: lib/include/chiaki/remote/holepunch.h and lib/src/remote/holepunch.c
    // CRITICAL: The duid parameter must be included in the authorization request for the token
    // to be accepted by the push notification WebSocket service (see holepunch.h lines 175-176)
    size_t duid_size = CHIAKI_DUID_STR_SIZE;
    char duid_arr[duid_size];
    chiaki_holepunch_generate_client_device_uid(duid_arr, &duid_size);
    QString duid = QString(duid_arr);
    qCInfo(chiakiGui) << "PSNAccountIDV3: Generated DUID:" << duid;
    
    // Step 1: Build authorization URL with access_type=offline (CRITICAL for refresh token)
    // Reference: research_docs/oauth/IMPLEMENTATION_GUIDE.md lines 48-69
    // CRITICAL: Include duid parameter - required for push notification WebSocket to accept the token
    // Reference: lib/include/chiaki/remote/holepunch.h lines 175-176
    QUrl authUrl(PSNAuthV3::AUTHORIZE_ENDPOINT_V3);
    QUrlQuery query;
    query.addQueryItem("client_id", PSNAuthV3::CLIENT_ID);
    query.addQueryItem("redirect_uri", PSNAuthV3::REDIRECT_URI);
    query.addQueryItem("scope", PSNAuthV3::SCOPES);
    query.addQueryItem("response_type", "code");
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("access_type", "offline"); // CRITICAL: Requests refresh token!
    query.addQueryItem("duid", duid); // CRITICAL: Required for push notification WebSocket
    query.addQueryItem("smcid", "remoteplay");
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("PlatformPrivacyWs1", "minimal");
    query.addQueryItem("no_captcha", "true");
    query.addQueryItem("cid", QUuid::createUuid().toString(QUuid::WithoutBraces));
    authUrl.setQuery(query);

    qCInfo(chiakiGui) << "PSNAccountIDV3: Getting authorization code with npsso";

    // Make GET request with Cookie header to follow redirects
    QNetworkRequest request(authUrl);
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    request.setRawHeader("Cookie", QString("npsso=%1").arg(npsso).toUtf8());

    currentAuthorizationReply = networkManager->get(request);
    connect(currentAuthorizationReply, &QNetworkReply::finished, this, &PSNAccountIDV3::handleAuthorizationResponse);
    connect(currentAuthorizationReply, &QNetworkReply::errorOccurred, this, &PSNAccountIDV3::handleAuthorizationError);
}

void PSNAccountIDV3::handleAuthorizationResponse() {
    if (!currentAuthorizationReply) {
        emit AccountIDError("", "No authorization reply available");
        emit Finished();
        return;
    }

    if (currentAuthorizationReply->error() != QNetworkReply::NoError) {
        handleAuthorizationError(currentAuthorizationReply->error());
        return;
    }

    // Get the final URL after redirects
    // QNetworkAccessManager follows redirects automatically for HTTP 301/302
    // The reply's url() after completion should be the final redirected URL
    QUrl finalUrl = currentAuthorizationReply->url();
    
    // Also check if there's a redirect target attribute (for manual redirect handling if needed)
    QVariant redirectTarget = currentAuthorizationReply->attribute(QNetworkRequest::RedirectionTargetAttribute);
    if (redirectTarget.isValid() && !redirectTarget.toUrl().isEmpty()) {
        QUrl redirectUrl = redirectTarget.toUrl();
        if (redirectUrl.isRelative()) {
            finalUrl = currentAuthorizationReply->url().resolved(redirectUrl);
        } else {
            finalUrl = redirectUrl;
        }
    }

    QString finalUrlString = finalUrl.toString();
    qCInfo(chiakiGui) << "PSNAccountIDV3: Authorization redirect URL:" << finalUrlString;

    // Extract authorization code from redirect URL
    // Reference: research_docs/oauth/remote_play_token_manager.py lines 95-109
    QRegularExpression codeRegex("[?&]code=([^&]+)");
    QRegularExpressionMatch match = codeRegex.match(finalUrlString);
    
    if (match.hasMatch()) {
        QString authCode = match.captured(1);
        qCInfo(chiakiGui) << "PSNAccountIDV3: Successfully obtained authorization code";
        
        currentAuthorizationReply->deleteLater();
        currentAuthorizationReply = nullptr;

        // Step 2: Exchange authorization code for tokens
        // Reference: research_docs/oauth/IMPLEMENTATION_GUIDE.md lines 71-99
        // Note: OAuth v3 endpoint does NOT use Basic Auth - credentials go in body only
        QUrlQuery bodyQuery;
        bodyQuery.addQueryItem("grant_type", "authorization_code");
        bodyQuery.addQueryItem("code", authCode);
        bodyQuery.addQueryItem("client_id", PSNAuthV3::CLIENT_ID);
        bodyQuery.addQueryItem("client_secret", PSNAuthV3::CLIENT_SECRET);
        bodyQuery.addQueryItem("redirect_uri", PSNAuthV3::REDIRECT_URI);
        bodyQuery.addQueryItem("scope", PSNAuthV3::SCOPES);
        QString body = bodyQuery.query(QUrl::FullyEncoded);

        JsonRequester* requester = new JsonRequester(this);
        connect(requester, &JsonRequester::requestFinished, this, &PSNAccountIDV3::handleTokenResponse);
        connect(requester, &JsonRequester::requestError, this, &PSNAccountIDV3::handleErrorResponse);
        // OAuth v3 doesn't use Basic Auth - pass empty string to avoid Authorization header
        requester->makePostRequest(PSNAuthV3::TOKEN_ENDPOINT_V3, "", "application/x-www-form-urlencoded", std::move(body));
    } else {
        // Check for errors
        QRegularExpression errorRegex("[?&]error=([^&]+)");
        QRegularExpressionMatch errorMatch = errorRegex.match(finalUrlString);
        
        QString errorMsg = "No authorization code found in redirect URL";
        if (errorMatch.hasMatch()) {
            errorMsg = QString("Authorization failed: %1").arg(errorMatch.captured(1));
        }
        
        qCWarning(chiakiGui) << "PSNAccountIDV3:" << errorMsg;
        emit AccountIDError(finalUrlString, errorMsg);
        emit Finished();
        
        currentAuthorizationReply->deleteLater();
        currentAuthorizationReply = nullptr;
    }
}

void PSNAccountIDV3::handleAuthorizationError(QNetworkReply::NetworkError error) {
    if (!currentAuthorizationReply) {
        emit AccountIDError("", "Authorization request failed");
        emit Finished();
        return;
    }

    QString errorString = currentAuthorizationReply->errorString();
    qCWarning(chiakiGui) << "PSNAccountIDV3: Authorization request error:" << error << errorString;
    
    emit AccountIDError(currentAuthorizationReply->url().toString(), errorString);
    emit Finished();
    
    currentAuthorizationReply->deleteLater();
    currentAuthorizationReply = nullptr;
}

void PSNAccountIDV3::handleTokenResponse(const QString& url, const QJsonDocument& jsonDocument) {
    QJsonObject object = jsonDocument.object();
    
    // Reference: research_docs/oauth/example_token_response.json for structure
    QString access_token = object.value("access_token").toString();
    QString refresh_token = object.value("refresh_token").toString();
    
    if (access_token.isEmpty()) {
        qCWarning(chiakiGui) << "PSNAccountIDV3: No access token in response";
        emit AccountIDError(url, "No access token in response");
        emit Finished();
        return;
    }

    QDateTime currentTime = QDateTime::currentDateTime();
    auto secondsLeft = object.value("expires_in").toInt();
    QDateTime expiry = currentTime.addSecs(secondsLeft);
    QString access_token_expiry = expiry.toString(settings->GetTimeFormat());
    
    // Save tokens to settings (same location as old flow)
    settings->SetPsnAuthToken(access_token);
    settings->SetPsnRefreshToken(std::move(refresh_token));
    settings->SetPsnAuthTokenExpiry(std::move(access_token_expiry));

    // Save the npsso token after successful authentication
    // This ensures we only save valid npsso tokens that have successfully authenticated
    if (!currentNpsso.isEmpty()) {
        settings->SetNpssoToken(currentNpsso);
        qCInfo(chiakiGui) << "PSNAccountIDV3: NPSSO token saved successfully";
        currentNpsso.clear(); // Clear it after saving
    }

    qCInfo(chiakiGui) << "PSNAccountIDV3: Tokens saved successfully";

    // Step 3: Fetch account ID using access token
    // Note: Account info endpoint still uses v2 API (v3 doesn't support this pattern)
    // Use the old v2 endpoint pattern: https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/{access_token}
    QString v2TokenEndpoint = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token";
    QString accountInfoUrl = QString("%1/%2").arg(v2TokenEndpoint).arg(access_token);
    JsonRequester* requester = new JsonRequester(this);
    connect(requester, &JsonRequester::requestFinished, this, &PSNAccountIDV3::handleAccountIdResponse);
    connect(requester, &JsonRequester::requestError, this, &PSNAccountIDV3::handleErrorResponse);
    // Account info endpoint requires Basic Auth (v2 API requirement)
    requester->makeGetRequest(accountInfoUrl, basicAuthHeader, "application/json");
}

void PSNAccountIDV3::handleAccountIdResponse(const QString& url, const QJsonDocument& jsonDocument) {
    QJsonObject object = jsonDocument.object();
    QString user_id = object.value("user_id").toString();
    
    if (user_id.isEmpty()) {
        qCWarning(chiakiGui) << "PSNAccountIDV3: No user_id in account info response";
        emit AccountIDError(url, "No user_id in account info response");
        emit Finished();
        return;
    }

    QByteArray byte_representation = to_bytes_little_endian(std::stoll(user_id.toStdString()), 8);
    settings->SetPsnAccountId(byte_representation.toBase64());
    
    qCInfo(chiakiGui) << "PSNAccountIDV3: Account ID retrieved and saved successfully";
    
    emit AccountIDResponse(byte_representation.toBase64());
    emit Finished();
}

void PSNAccountIDV3::handleErrorResponse(const QString& url, const QString& error, const QNetworkReply::NetworkError& err) {
    qCWarning(chiakiGui) << "PSNAccountIDV3: Request error:" << url << error << err;
    emit AccountIDError(url, error);
    emit Finished();
}

