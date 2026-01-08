// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/pskamajisession.h"
#include "chiaki/remote/holepunch.h"

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QUrl>
#include <QRegularExpression>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// Helper function to log request headers
static void logKamajiRequest(const QString &stepName, const QNetworkRequest &request, const QByteArray &body = QByteArray())
{
    qInfo() << "=== Kamaji" << stepName << "Request ===";
    qInfo() << "URL:" << request.url().toString();
    qInfo() << "Method:" << (body.isEmpty() ? "GET" : "POST");
    qInfo() << "Request Headers:";
    
    // QNetworkRequest doesn't have rawHeaderPairs(), so we use rawHeaderList() and rawHeader()
    QList<QByteArray> headerNames = request.rawHeaderList();
    for (const QByteArray &headerName : headerNames) {
        QByteArray headerValue = request.rawHeader(headerName);
        QString headerNameStr = QString::fromUtf8(headerName);
        QString headerValueStr = QString::fromUtf8(headerValue);
        
        // Truncate long values for readability
        if (headerNameStr.compare("X-Gaikai-Session", Qt::CaseInsensitive) == 0 ||
            headerNameStr.compare("Authorization", Qt::CaseInsensitive) == 0) {
            headerValueStr = headerValueStr.left(30) + "...";
        }
        
        qInfo() << "  " << headerNameStr << ":" << headerValueStr;
    }
    
    // Also check Content-Type header (might be set via setHeader instead of setRawHeader)
    QVariant contentType = request.header(QNetworkRequest::ContentTypeHeader);
    if (contentType.isValid() && !contentType.toString().isEmpty()) {
        qInfo() << "  Content-Type:" << contentType.toString();
    }
    
    if (!body.isEmpty()) {
        // Try to parse as JSON and format it nicely
        QJsonParseError parseError;
        QJsonDocument jsonDoc = QJsonDocument::fromJson(body, &parseError);
        if (parseError.error == QJsonParseError::NoError) {
            qInfo() << "Request Body:";
            QByteArray formattedJson = jsonDoc.toJson(QJsonDocument::Indented);
            QString jsonString = QString::fromUtf8(formattedJson);
            // Output each line separately so it's properly formatted in logs
            QStringList lines = jsonString.split('\n', Qt::SkipEmptyParts);
            for (const QString &line : lines) {
                if (!line.trimmed().isEmpty()) {
                    qInfo().noquote() << line;
                }
            }
        } else {
            // If not valid JSON, just output as-is
            qInfo() << "Request Body:" << QString::fromUtf8(body);
        }
    }
    qInfo() << "========================================";
}

PSKamajiSession::PSKamajiSession(
    Settings *settings,
    QString deviceUid,
    QString productIdParam,
    QString accountBaseUrl,
    QString redirectUri,
    QString userAgent,
    QObject *parent
)
    : QObject(parent)
    , settings(settings)
    , duid(deviceUid)
    , platform("ps4")  // Default, will be detected from API response
    , productId(productIdParam)
    , kamajiBase(KamajiConsts::KAMAJI_BASE)
    , accountBase(accountBaseUrl)
    , kamajiClientId(KamajiConsts::CLIENT_ID)
    , redirectUriUrl(redirectUri)
    , userAgentString(userAgent)
    , scopesStr(KamajiConsts::PS4_SCOPES)  // Default to PS4 scopes, will be updated when platform is detected
{
    manager = new QNetworkAccessManager(this);
    manager->setCookieJar(nullptr);  // Disable cookie jar - we use manual Cookie headers only
}

void PSKamajiSession::startSessionCreation()
{
    // Get npsso fresh from settings at the start of each session attempt
    npssoToken = settings->GetNpssoToken();
    
    // Clear jsessionId to ensure we start fresh
    jsessionId.clear();
    
    qInfo() << "Kamaji Session: Starting authentication flow (Steps 0.5b-0.5d, 5-6)...";
    qInfo() << "Platform:" << platform;
    qInfo() << "Product ID:" << productId;
    qInfo() << "Note: Authorization check is now handled centrally by CloudStreamingBackend";
    
    if (npssoToken.isEmpty()) {
        QString error = "NPSSO token is empty";
        qWarning() << "Kamaji Session:" << error;
        emit sessionComplete(false, error, QString());
        return;
    }
    
    // Authorization check is now done centrally by CloudStreamingBackend before creating PSKamajiSession
    // Start directly with Step 0.5b: Get anonymous session OAuth code
    step0_5b_GetAnonymousAuthCode();
}

// ============================================================================
// Step 0.5b: GET /oauth/authorize (for anonymous session OAuth code)
// Note: Step 0.5a (authorizeCheck) is now handled centrally by CloudStreamingBackend
// ============================================================================
void PSKamajiSession::step0_5b_GetAnonymousAuthCode()
{
    QUrl url(accountBase + "/v1/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("smcid", "pc:psnow");
    query.addQueryItem("applicationId", "psnow");
    query.addQueryItem("response_type", "code");
    query.addQueryItem("scope", scopesStr);
    query.addQueryItem("client_id", kamajiClientId);
    query.addQueryItem("redirect_uri", redirectUriUrl);
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("renderMode", "mobilePortrait");
    query.addQueryItem("hidePageElements", "forgotPasswordLink");
    query.addQueryItem("displayFooter", "none");
    query.addQueryItem("disableLinks", "qriocityLink");
    query.addQueryItem("mid", "PSNOW");
    query.addQueryItem("duid", duid);
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("service_logo", "ps");
    query.addQueryItem("tp_psn", "true");
    query.addQueryItem("noEVBlock", "true");
    url.setQuery(query);
    
    qInfo() << "Kamaji Step 0.5b: GET /oauth/authorize (for anonymous session code)";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url.toString();
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    // Add npsso cookie for OAuth authorization (required even for anonymous session)
    if (!npssoToken.isEmpty()) {
        req.setRawHeader("Cookie", QString("npsso=%1").arg(npssoToken).toUtf8());
    }
    
    logKamajiRequest("Step 0.5b: GetAnonymousAuthCode", req);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAnonAuthCodeResponse(reply);
    });
}

void PSKamajiSession::handleAnonAuthCodeResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Kamaji Step 0.5b Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        if (!redirectUrl.isEmpty()) {
            qInfo() << "  Redirect URL:" << redirectUrl.toString();
        }
        QByteArray response = reply->readAll();
        if (!response.isEmpty()) {
            qInfo() << "  Body:" << QString(response);
        }
    }
    
    // Handle redirect to get OAuth code
    QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
    if (!redirectUrl.isEmpty()) {
        QUrlQuery query(redirectUrl);
        QString code = query.queryItemValue("code");
        if (!code.isEmpty()) {
            anonAuthCode = code;
            qInfo() << "Kamaji Step 0.5b complete - Got anonymous auth code:" << anonAuthCode.left(20) << "...";
            step0_5c_CreateAnonymousSession();
            return;
        } else {
            QString error = query.queryItemValue("error");
            if (!error.isEmpty()) {
                emit sessionComplete(false, QString("OAuth error: %1").arg(error), QString());
                return;
            }
        }
    }
    
    emit sessionComplete(false, "No authorization code in redirect for anonymous session", QString());
}

// ============================================================================
// Step 0.5c: POST /user/session (anonymous) - with OAuth code body
// ============================================================================
void PSKamajiSession::step0_5c_CreateAnonymousSession()
{
    QString url = kamajiBase + "/user/session";
    QString body = QString("code=%1&client_id=%2&duid=%3")
        .arg(anonAuthCode)
        .arg(kamajiClientId)
        .arg(duid);
    
    qInfo() << "Kamaji Step 0.5c: POST /user/session (anonymous) - with OAuth code body";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: POST";
        qInfo() << "  Content-Type: text/plain;charset=UTF-8";
        qInfo() << "  User-Agent:" << userAgentString;
        qInfo() << "  X-Alt-Referer:" << redirectUriUrl;
        qInfo() << "  Origin: https://psnow.playstation.com";
        qInfo() << "  Referer: https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/";
        qInfo() << "  Body:" << body;
        qInfo() << "  Note: Using empty cookie session";
    }
    
    // Use a temporary network manager with no cookie jar (no cookies needed for anonymous session)
    QNetworkAccessManager *tempManager = new QNetworkAccessManager(this);
    tempManager->setCookieJar(nullptr);
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Content-Type", "text/plain;charset=UTF-8");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Alt-Referer", redirectUriUrl.toUtf8());
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("Origin", "https://psnow.playstation.com");
    req.setRawHeader("Sec-Fetch-Site", "same-origin");
    req.setRawHeader("Sec-Fetch-Mode", "cors");
    req.setRawHeader("Sec-Fetch-Dest", "empty");
    req.setRawHeader("Referer", "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/");
    
    QByteArray requestBody = body.toUtf8();
    logKamajiRequest("Step 0.5c: CreateAnonymousSession", req, requestBody);
    
    QNetworkReply *reply = tempManager->post(req, requestBody);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, tempManager]() {
        handleAnonSessionResponse(reply);
        tempManager->deleteLater();
    });
}

void PSKamajiSession::handleAnonSessionResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray response = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Kamaji Step 0.5c Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
        qInfo() << "  Body:" << QString(response);
    }
    
    if (reply->error() != QNetworkReply::NoError) {
        emit sessionComplete(false, QString("Anonymous session failed: %1").arg(reply->errorString()), QString());
        return;
    }
    
    // Extract JSESSIONID from Set-Cookie header
    QList<QNetworkReply::RawHeaderPair> headers = reply->rawHeaderPairs();
    for (const auto &header : headers) {
        if (header.first.toLower() == "set-cookie") {
            QString setCookieValue = QString::fromUtf8(header.second);
            // Parse JSESSIONID=...; from Set-Cookie header
            QRegularExpression jsessionRegex("JSESSIONID=([^;]+)");
            QRegularExpressionMatch match = jsessionRegex.match(setCookieValue);
            if (match.hasMatch()) {
                jsessionId = match.captured(1);
                qInfo() << "Kamaji Step 0.5c complete - Got JSESSIONID:" << jsessionId.left(20) << "...";
                
                // Continue to Step 0.5d: Convert Product ID to Entitlement ID
                step0_5d_ConvertProductId();
                return;
            }
        }
    }
    
    emit sessionComplete(false, "No JSESSIONID in Set-Cookie header", QString());
}

// ============================================================================
// Step 0.5d: Convert Product ID → Entitlement ID
// GET /store/api/pcnow/00_09_000/container/{COUNTRY}/{LANGUAGE}/19/{PRODUCT_ID}?useOffers=true&gkb=1&gkb2=1
// ============================================================================
void PSKamajiSession::step0_5d_ConvertProductId()
{
    // Get locale from unified language setting
    QString localeSetting = settings ? settings->GetCloudLanguagePSCloud() : "en-US";
    QString locale = localeSetting.toLower(); // Convert "en-US" to "en-us"
    
    // Extract country and language from locale (e.g., "en-us" -> "US", "en")
    QStringList localeParts = locale.split("-");
    QString country = localeParts.size() > 1 ? localeParts[1].toUpper() : "US";
    QString language = localeParts[0].toLower();
    
    QString url = QString("https://psnow.playstation.com/store/api/pcnow/00_09_000/container/%1/%2/19/%3?useOffers=true&gkb=1&gkb2=1")
        .arg(country, language, productId);
    
    qInfo() << "Kamaji Step 0.5d: Convert Product ID to Entitlement ID";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: GET";
        qInfo() << "  Product ID:" << productId;
    }
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    
    logKamajiRequest("Step 0.5d: ConvertProductId", req);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleProductIdConversionResponse(reply);
    });
}

void PSKamajiSession::handleProductIdConversionResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    // Handle 404 (Product ID not found) with user-friendly message
    // Check status code first, as 404 is a valid HTTP response (not a network error)
    if (statusCode == 404) {
        QByteArray response = reply->readAll();
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "=== Kamaji Step 0.5d Response ===";
            qInfo() << "  Status:" << statusCode;
            if (!response.isEmpty()) {
                qInfo() << "  Body:" << QString(response);
            }
        }
        emit sessionComplete(false, QString("Game not found: Product ID '%1' does not exist or is not available for cloud streaming").arg(productId), QString());
        return;
    }
    
    if (reply->error() != QNetworkReply::NoError) {
        QByteArray response = reply->readAll();
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "=== Kamaji Step 0.5d Response ===";
            qInfo() << "  Status:" << statusCode;
            if (!response.isEmpty()) {
                qInfo() << "  Body:" << QString(response);
            }
        }
        emit sessionComplete(false, QString("Failed to lookup game: Product ID '%1' - %2").arg(productId).arg(reply->errorString()), QString());
        return;
    }
    
    QByteArray response = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Kamaji Step 0.5d Response ===";
        qInfo() << "  Status:" << statusCode;
        if (!response.isEmpty()) {
            qInfo() << "  Body:" << QString(response);
        }
    }
    QJsonDocument doc = QJsonDocument::fromJson(response);
    
    if (doc.isNull() || !doc.isObject()) {
        emit sessionComplete(false, "Invalid JSON in product lookup response", QString());
        return;
    }
    
    QJsonObject obj = doc.object();
    QString streamingEntitlementId;
    QString sku;
    
    // Extract platform from playable_platform field (contains strings like "PS3™", "PS4™")
    // Pick highest available platform (PS4 > PS3)
    QString detectedPlatform = "ps4"; // Default to PS4
    QJsonArray playablePlatformArray;
    
    // Try to get playable_platform from root level first
    if (obj.contains("playable_platform") && obj["playable_platform"].isArray()) {
        playablePlatformArray = obj["playable_platform"].toArray();
    }
    // Fallback to metadata.playable_platform.values
    else if (obj.contains("metadata") && obj["metadata"].isObject()) {
        QJsonObject metadata = obj["metadata"].toObject();
        if (metadata.contains("playable_platform") && metadata["playable_platform"].isObject()) {
            QJsonObject playablePlatformObj = metadata["playable_platform"].toObject();
            if (playablePlatformObj.contains("values") && playablePlatformObj["values"].isArray()) {
                playablePlatformArray = playablePlatformObj["values"].toArray();
            }
        }
    }
    
    // Look for streaming entitlement - check default_sku first, then skus array
    // Streaming entitlements have license_type == 4
    QJsonObject defaultSku = obj["default_sku"].toObject();
    if (!defaultSku.isEmpty() && defaultSku.contains("entitlements") && defaultSku["entitlements"].isArray()) {
        QJsonArray entitlements = defaultSku["entitlements"].toArray();
        for (const QJsonValue &entValue : entitlements) {
            QJsonObject ent = entValue.toObject();
            int licenseType = ent["license_type"].toInt();
            
            // Streaming entitlements have license_type == 4
            if (licenseType == 4) {
                QString entId = ent["id"].toString();
                if (!entId.isEmpty()) {
                    streamingEntitlementId = entId;
                    sku = defaultSku["id"].toString();
                    streamingSku = sku;
                    qInfo() << "Found streaming Entitlement ID from default_sku:" << streamingEntitlementId;
                    qInfo() << "License Type:" << licenseType;
                    qInfo() << "SKU:" << sku;
                    break;
                }
            }
        }
    }
    
    // If not found in default_sku, check all SKUs in the skus array
    if (streamingEntitlementId.isEmpty() && obj.contains("skus") && obj["skus"].isArray()) {
        QJsonArray skus = obj["skus"].toArray();
        for (const QJsonValue &skuValue : skus) {
            QJsonObject skuObj = skuValue.toObject();
            
            if (skuObj.contains("entitlements") && skuObj["entitlements"].isArray()) {
                QJsonArray entitlements = skuObj["entitlements"].toArray();
                for (const QJsonValue &entValue : entitlements) {
                    QJsonObject ent = entValue.toObject();
                    int licenseType = ent["license_type"].toInt();
                    
                    // Streaming entitlements have license_type == 4
                    if (licenseType == 4) {
                        QString entId = ent["id"].toString();
                        if (!entId.isEmpty()) {
                            streamingEntitlementId = entId;
                            sku = skuObj["id"].toString();
                            streamingSku = sku;
                            qInfo() << "Found streaming Entitlement ID from skus array:" << streamingEntitlementId;
                            qInfo() << "License Type:" << licenseType;
                            qInfo() << "SKU:" << sku;
                            break;
                        }
                    }
                }
            }
            if (!streamingEntitlementId.isEmpty()) break;
        }
    }
    
    // Determine platform from playable_platform strings (pick highest: PS4 > PS3)
    if (!playablePlatformArray.isEmpty()) {
        bool hasPS4 = false;
        bool hasPS3 = false;
        for (const QJsonValue &platformValue : playablePlatformArray) {
            QString platformStr = platformValue.toString();
            // Check for PS4 (handles "PS4™" and "PS4")
            if (platformStr.contains("PS4", Qt::CaseInsensitive)) {
                hasPS4 = true;
            }
            // Check for PS3 (handles "PS3™" and "PS3")
            else if (platformStr.contains("PS3", Qt::CaseInsensitive)) {
                hasPS3 = true;
            }
        }
        if (hasPS4) {
            detectedPlatform = "ps4";
        } else if (hasPS3) {
            detectedPlatform = "ps3";
        }
        qInfo() << "Detected platform from playable_platform:" << detectedPlatform;
    } else {
        qWarning() << "No playable_platform found in response, defaulting to PS4";
    }
    
    platform = detectedPlatform;
    
    // Update scopes based on detected platform
    if (platform == "ps3") {
        scopesStr = KamajiConsts::PS3_SCOPES;
    } else {
        scopesStr = KamajiConsts::PS4_SCOPES;
    }
    qInfo() << "Updated scopes for platform" << platform << ":" << scopesStr;
    
    if (streamingEntitlementId.isEmpty()) {
        emit sessionComplete(false, QString("Could not determine Entitlement ID from Product ID '%1'. Game may not be available for cloud streaming.").arg(productId), QString());
        return;
    }
    
    entitlementId = streamingEntitlementId;
    qInfo() << "Kamaji Step 0.5d complete - Entitlement ID:" << entitlementId;
    if (!streamingSku.isEmpty()) {
        qInfo() << "  Streaming SKU:" << streamingSku;
    }
    
    // Continue to Step 0.5e: Check and acquire entitlement if needed
    step0_5e_CheckEntitlement();
}

// ============================================================================
// Step 0.5e: Check and Acquire Entitlement (entitlement_check.py flow)
// ============================================================================
void PSKamajiSession::step0_5e_CheckEntitlement()
{
    qInfo() << "Kamaji Step 0.5e: Starting entitlement check/acquisition flow";
    qInfo() << "  Entitlement ID:" << entitlementId;
    if (!streamingSku.isEmpty()) {
        qInfo() << "  SKU:" << streamingSku;
    }
    
    // First, get OAuth token for Commerce API
    step0_5e_GetCommerceOAuthToken();
}

void PSKamajiSession::step0_5e_GetCommerceOAuthToken()
{
    qInfo() << "Kamaji Step 0.5e.1: Getting OAuth token for Commerce API...";
    
    QUrl url(accountBase + "/v1/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("smcid", "pc:psnow");
    query.addQueryItem("applicationId", "psnow");
    query.addQueryItem("response_type", "token");  // Use token, not code
    query.addQueryItem("scope", "kamaji:get_internal_entitlements user:account.attributes.validate kamaji:get_privacy_settings user:account.settings.privacy.get kamaji:s2s.subscriptionsPremium.get");
    query.addQueryItem("client_id", "dc523cc2-b51b-4190-bff0-3397c06871b3");  // Commerce API client ID
    query.addQueryItem("redirect_uri", redirectUriUrl);
    query.addQueryItem("grant_type", "authorization_code");
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("renderMode", "mobilePortrait");
    query.addQueryItem("hidePageElements", "forgotPasswordLink");
    query.addQueryItem("displayFooter", "none");
    query.addQueryItem("disableLinks", "qriocityLink");
    query.addQueryItem("mid", "PSNOW");
    query.addQueryItem("duid", duid);
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("service_logo", "ps");
    query.addQueryItem("tp_psn", "true");
    query.addQueryItem("noEVBlock", "true");
    url.setQuery(query);
    
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    logKamajiRequest("Step 0.5e.1: GetCommerceOAuthToken", req);
    
    // Only use npsso cookie, NOT JSESSIONID
    if (!npssoToken.isEmpty()) {
        req.setRawHeader("Cookie", QString("npsso=%1").arg(npssoToken).toUtf8());
    }
    
    QNetworkReply *reply = manager->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCommerceOAuthTokenResponse(reply);
    });
}

void PSKamajiSession::handleCommerceOAuthTokenResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Commerce OAuth Token Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
    }
    
    if (statusCode != 302) {
        qWarning() << "Commerce OAuth token request failed: Expected 302, got" << statusCode;
        emit sessionComplete(false, QString("Failed to get Commerce OAuth token (status %1)").arg(statusCode), entitlementId);
        return;
    }
    
    QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
    if (redirectUrl.isEmpty()) {
        QByteArray locationHeader = reply->rawHeader("Location");
        if (!locationHeader.isEmpty()) {
            redirectUrl = QUrl::fromEncoded(locationHeader);
        }
    }
    
    if (redirectUrl.isEmpty()) {
        emit sessionComplete(false, "No redirect URL in Commerce OAuth response", entitlementId);
        return;
    }
    
    // Extract access_token from URL fragment (#access_token=...)
    QString fragment = redirectUrl.fragment();
    QRegularExpression tokenRegex("#access_token=([^&]+)");
    QRegularExpressionMatch match = tokenRegex.match(fragment);
    if (!match.hasMatch()) {
        // Try query string as fallback
        tokenRegex = QRegularExpression("[?&#]access_token=([^&]+)");
        match = tokenRegex.match(redirectUrl.toString());
    }
    
    if (!match.hasMatch()) {
        qWarning() << "Could not extract access_token from redirect URL";
        qWarning() << "Redirect URL:" << redirectUrl.toString();
        emit sessionComplete(false, "Could not extract access token from Commerce OAuth response", entitlementId);
        return;
    }
    
    commerceOAuthToken = match.captured(1);
    qInfo() << "Kamaji Step 0.5e.1 complete - Got Commerce OAuth token:" << commerceOAuthToken.left(30) << "...";
    
    // Continue to check account attributes
    step0_5e_CheckAccountAttributes();
}

void PSKamajiSession::step0_5e_CheckAccountAttributes()
{
    // Skip check if it has already passed previously
    if (settings && settings->GetAccountAttributesCheckPassed()) {
        qInfo() << "Kamaji Step 0.5e.1a: Skipping account attributes check (previously passed)";
        step0_5e_CheckEntitlementExists();
        return;
    }
    
    qInfo() << "Kamaji Step 0.5e.1a: Checking account attributes...";
    
    QString url = "https://accounts.api.playstation.com/api/v2/accounts/me/attributes";
    
    // Create JSON payload
    QJsonObject payload;
    QJsonArray attributes;
    attributes.append("ONLINE_ID");
    attributes.append("BIRTH_DATE");
    attributes.append("CITY");
    attributes.append("REAL_NAME");
    attributes.append("PRIVACY_SETTING_ACTIVITYSTREAM");
    attributes.append("PRIVACY_SETTING_FRIENDSLIST");
    attributes.append("PRIVACY_SETTING_FRIENDREQUESTS");
    attributes.append("PRIVACY_SETTING_MESSAGES");
    attributes.append("PRIVACY_SETTING_TRUENAME");
    attributes.append("PRIVACY_SETTING_SEARCH");
    attributes.append("PRIVACY_SETTING_RECOMMENDUSERS");
    attributes.append("PRIVACY_SETTING_BROADCAST");
    payload["attributes"] = attributes;
    
    QJsonDocument doc(payload);
    QByteArray postData = doc.toJson(QJsonDocument::Compact);
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Authorization", QString("Bearer %1").arg(commerceOAuthToken).toUtf8());
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("Content-Type", "application/json");
    
    logKamajiRequest("Step 0.5e.1a: CheckAccountAttributes", req, postData);
    
    QNetworkReply *reply = manager->post(req, postData);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAccountAttributesResponse(reply);
    });
}

void PSKamajiSession::handleAccountAttributesResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray data = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Account Attributes Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Body:" << QString::fromUtf8(data);
    }
    
    // Check for successful response (200 or 204)
    if (statusCode == 200 || statusCode == 204) {
        qInfo() << "Kamaji Step 0.5e.1a complete - Account attributes check successful";
        
        // Mark check as passed so we don't need to do it again
        if (settings) {
            settings->SetAccountAttributesCheckPassed(true);
        }
        
        // Continue to check entitlement
        step0_5e_CheckEntitlementExists();
        return;
    }
    
    // Any other status code is an error - parse missing elements and construct upgrade URL
    QString errorMsg = QString("Account attributes check failed with status %1").arg(statusCode);
    if (!data.isEmpty()) {
        errorMsg += ": " + QString::fromUtf8(data);
    }
    qWarning() << errorMsg;
    
    // Parse missing elements from error response
    QStringList missingElements;
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isNull() && doc.isObject()) {
        QJsonObject obj = doc.object();
        QJsonObject error = obj["error"].toObject();
        QJsonArray validationErrors = error["validationErrors"].toArray();
        
        for (const QJsonValue &validationError : validationErrors) {
            QJsonObject validationObj = validationError.toObject();
            QJsonArray missingElementsArray = validationObj["missingElements"].toArray();
            
            for (const QJsonValue &missingElement : missingElementsArray) {
                QJsonObject elementObj = missingElement.toObject();
                QString elementName = elementObj["name"].toString();
                if (!elementName.isEmpty()) {
                    missingElements.append(elementName);
                }
            }
        }
    }
    
    // Construct Sony upgrade URL
    QString upgradeUrl;
    if (!missingElements.isEmpty()) {
        QString missingElementsParam = missingElements.join(",");
        
        QUrl url("https://id.sonyentertainmentnetwork.com/id/upgrade_account_ca/");
        QUrlQuery query;
        query.addQueryItem("entry", "upgrade_account");
        query.addQueryItem("pr_referer", "upgrade");
        query.addQueryItem("redirect_uri", redirectUriUrl);
        query.addQueryItem("applicationId", "psnow");
        query.addQueryItem("refererPage", "websso");
        query.addQueryItem("service_logo", "ps");
        query.addQueryItem("tp_console", "true");
        query.addQueryItem("disableLinks", "SENLink");
        query.addQueryItem("renderMode", "mobilePortrait");
        query.addQueryItem("noEVBlock", "true");
        query.addQueryItem("displayFooter", "none");
        query.addQueryItem("hidePageElements", "SENLogo");
        query.addQueryItem("layout_type", "popup");
        query.addQueryItem("missing_elements", missingElementsParam);
        query.addQueryItem("response_type", "code");
        query.addQueryItem("service_entity", "urn:service-entity:psn");
        query.addQueryItem("smcid", "pc:psnow");
        query.addQueryItem("tp_psn", "true");
        query.addQueryItem("tp_social", "true");
        query.addQueryItem("elements_visibility_upgrade", "no_cancel");
        url.setQuery(query);
        
        upgradeUrl = url.toString();
        qInfo() << "Sony upgrade URL:" << upgradeUrl;
    }
    
    // Show warning dialog to user - session is STOPPED
    // User can click "Ignore Forever" to skip this check in future sessions
    emit accountPrivacySettingsError(upgradeUrl);
    emit sessionComplete(false, "Account privacy settings check failed. Please complete privacy settings or click 'Ignore Forever' and try again.", entitlementId);
}

void PSKamajiSession::step0_5e_CheckEntitlementExists()
{
    qInfo() << "Kamaji Step 0.5e.2: Checking if entitlement exists...";
    
    QString url = QString("https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements/%1?fields=game_meta")
        .arg(entitlementId);
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Authorization", QString("Bearer %1").arg(commerceOAuthToken).toUtf8());
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("Accept", "application/json");
    
    logKamajiRequest("Step 0.5e.2: CheckEntitlementExists", req);
    
    QNetworkReply *reply = manager->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCheckEntitlementResponse(reply);
    });
}

void PSKamajiSession::handleCheckEntitlementResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray data = reply->readAll();
    
    // Note: Qt's QNetworkReply may automatically decompress gzip responses
    // If we get invalid JSON, may need to add explicit gzip decompression later
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Check Entitlement Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Body:" << QString::fromUtf8(data);
    }
    
    if (statusCode == 200) {
        // User has entitlement
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isNull() && doc.isObject()) {
            QJsonObject obj = doc.object();
            QJsonObject gameMeta = obj["game_meta"].toObject();
            QString gameName = gameMeta["name"].toString();
            qInfo() << "Kamaji Step 0.5e.2 complete - User has entitlement";
            qInfo() << "  Game Name:" << gameName;
        } else {
            qInfo() << "Kamaji Step 0.5e.2 complete - User has entitlement";
        }
        
        // Continue to Step 5: Get authenticated session OAuth code
        step5_GetAuthCode();
        return;
    } else if (statusCode == 404) {
        // User doesn't have entitlement - try to acquire it
        qInfo() << "Kamaji Step 0.5e.2 - Entitlement not found (404), will attempt to acquire";
        
        // Continue to checkout preview
        step0_5e_CheckoutPreview();
        return;
    } else {
        // Other error
        QString errorMsg = QString("Entitlement check failed with status %1").arg(statusCode);
        if (!data.isEmpty()) {
            errorMsg += ": " + QString::fromUtf8(data);
        }
        qWarning() << errorMsg;
        emit sessionComplete(false, errorMsg, entitlementId);
        return;
    }
}

void PSKamajiSession::step0_5e_CheckoutPreview()
{
    qInfo() << "Kamaji Step 0.5e.3: Checking checkout preview...";
    
    if (streamingSku.isEmpty()) {
        qWarning() << "No SKU available for checkout preview, using entitlement ID";
        // Can still try with entitlement ID - API may return correct SKU
        streamingSku = entitlementId;
    }
    
    QString url = "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000/user/checkout/buynow/preview";
    
    QUrlQuery formData;
    formData.addQueryItem("sku", streamingSku);
    QByteArray postData = formData.query(QUrl::FullyEncoded).toUtf8();
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Host", "psnow.playstation.com");
    req.setRawHeader("Connection", "keep-alive");
    req.setRawHeader("Content-Length", QByteArray::number(postData.size()));
    req.setRawHeader("Accept", "application/json, text/javascript, */*; q=0.01");
    req.setRawHeader("X-Requested-With", "XMLHttpRequest");
    req.setRawHeader("Authorization", QString("Bearer %1").arg(commerceOAuthToken).toUtf8());
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded; charset=UTF-8");
    req.setRawHeader("Origin", "https://psnow.playstation.com");
    req.setRawHeader("Sec-Fetch-Site", "same-origin");
    req.setRawHeader("Sec-Fetch-Mode", "cors");
    req.setRawHeader("Sec-Fetch-Dest", "empty");
    req.setRawHeader("Referer", "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/");
    req.setRawHeader("Accept-Encoding", "identity");
    req.setRawHeader("Accept-Language", "en-US");
    
    logKamajiRequest("Step 0.5e.3: CheckoutPreview", req, postData);
    
    // Add JSESSIONID cookie
    if (!jsessionId.isEmpty()) {
        req.setRawHeader("Cookie", QString("JSESSIONID=%1").arg(jsessionId).toUtf8());
    }
    
    QNetworkReply *reply = manager->post(req, postData);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCheckoutPreviewResponse(reply);
    });
}

void PSKamajiSession::handleCheckoutPreviewResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray data = reply->readAll();
    
    // Verbose log errors
    if (settings && settings->GetLogVerbose()) {
        if (statusCode != 200 || reply->error() != QNetworkReply::NoError) {
            qInfo() << "=== Checkout Preview Error Response ===";
            qInfo() << "  HTTP Status Code:" << statusCode;
            qInfo() << "  Network Error:" << reply->error();
            qInfo() << "  Error String:" << reply->errorString();
            qInfo() << "  Response Body:" << QString::fromUtf8(data);
        }
    }
    
    // Immediately check for errors and fail
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isNull() && doc.isObject()) {
        QJsonObject obj = doc.object();
        QJsonObject header = obj["header"].toObject();
        QString statusCodeHex = header["status_code"].toString();
        
        // Fail immediately if API error detected
        if (statusCodeHex != "0x0000") {
            QString message = header["message_key"].toString();
            if (settings && settings->GetLogVerbose()) {
                qInfo() << "  API Status Code:" << statusCodeHex;
                qInfo() << "  Message:" << message;
            }
            // Checkout preview errors indicate PS Plus subscription issue
            emit psPlusSubscriptionError();
            emit sessionComplete(false, "Checkout preview failed", entitlementId);
            return;
        }
    }
    
    // Check for HTTP errors
    if (statusCode != 200) {
        // Checkout preview HTTP errors indicate PS Plus subscription issue
        emit psPlusSubscriptionError();
        emit sessionComplete(false, QString("Checkout preview failed with HTTP status %1").arg(statusCode), entitlementId);
        return;
    }
    
    // Check for network errors
    if (reply->error() != QNetworkReply::NoError) {
        emit psPlusSubscriptionError();
        emit sessionComplete(false, QString("Checkout preview failed: %1").arg(reply->errorString()), entitlementId);
        return;
    }
    
    // Update JSESSIONID from Set-Cookie if present
    QList<QByteArray> cookieHeaders = reply->rawHeaderList();
    for (const QByteArray &headerName : cookieHeaders) {
        if (headerName.toLower() == "set-cookie") {
            QByteArray cookieValue = reply->rawHeader(headerName);
            QRegularExpression jsessionRegex("JSESSIONID=([^;]+)");
            QRegularExpressionMatch match = jsessionRegex.match(QString::fromUtf8(cookieValue));
            if (match.hasMatch()) {
                QString newJsessionId = match.captured(1);
                if (newJsessionId != jsessionId) {
                    jsessionId = newJsessionId;
                    qInfo() << "Updated JSESSIONID from checkout preview response";
                }
            }
        }
    }
    
    // Parse JSON for successful response
    if (doc.isNull() || !doc.isObject()) {
        emit sessionComplete(false, "Invalid JSON in checkout preview response", entitlementId);
        return;
    }
    
    QJsonObject obj = doc.object();
    
    QJsonObject dataObj = obj["data"].toObject();
    QJsonObject cart = dataObj["cart"].toObject();
    int totalPriceValue = cart["total_price_value"].toInt();
    QString totalPrice = cart["total_price"].toString();
    
    qInfo() << "Checkout preview - Total Price Value:" << totalPriceValue;
    qInfo() << "Checkout preview - Total Price:" << totalPrice;
    
    if (totalPriceValue != 0) {
        qWarning() << "Game is not free (price:" << totalPrice << "), cannot proceed";
        emit sessionComplete(false, QString("Game is not free (price: %1), cannot acquire entitlement").arg(totalPrice), entitlementId);
        return;
    }
    
    // Extract actual SKU from response (authoritative source)
    QJsonArray items = cart["items"].toArray();
    if (!items.isEmpty()) {
        QJsonObject firstItem = items[0].toObject();
        QString actualSku = firstItem["sku_id"].toString();
        if (!actualSku.isEmpty() && actualSku != streamingSku) {
            qInfo() << "Using SKU from preview response:" << actualSku;
            streamingSku = actualSku;
        }
    }
    
    qInfo() << "Kamaji Step 0.5e.3 complete - Game is free, proceeding to checkout";
    
    // Continue to checkout buynow
    step0_5e_CheckoutBuynow();
}

void PSKamajiSession::step0_5e_CheckoutBuynow()
{
    qInfo() << "Kamaji Step 0.5e.4: Completing checkout to acquire entitlement...";
    
    QString url = "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000/user/checkout/buynow";
    
    QUrlQuery formData;
    formData.addQueryItem("sku", streamingSku);
    formData.addQueryItem("skipEmail", "true");
    QByteArray postData = formData.query(QUrl::FullyEncoded).toUtf8();
    
    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("Authorization", QString("Bearer %1").arg(commerceOAuthToken).toUtf8());
    
    logKamajiRequest("Step 0.5e.4: CheckoutBuynow", req, postData);
    
    // Add JSESSIONID cookie
    if (!jsessionId.isEmpty()) {
        req.setRawHeader("Cookie", QString("JSESSIONID=%1").arg(jsessionId).toUtf8());
    }
    
    QNetworkReply *reply = manager->post(req, postData);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCheckoutBuynowResponse(reply);
    });
}

void PSKamajiSession::handleCheckoutBuynowResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray data = reply->readAll();
    
    // Note: Qt's QNetworkReply may automatically decompress gzip responses
    // If we get invalid JSON, may need to add explicit gzip decompression later
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Checkout Buynow Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Body:" << QString::fromUtf8(data);
    }
    
    // Update JSESSIONID from Set-Cookie if present
    QList<QByteArray> cookieHeaders = reply->rawHeaderList();
    for (const QByteArray &headerName : cookieHeaders) {
        if (headerName.toLower() == "set-cookie") {
            QByteArray cookieValue = reply->rawHeader(headerName);
            QRegularExpression jsessionRegex("JSESSIONID=([^;]+)");
            QRegularExpressionMatch match = jsessionRegex.match(QString::fromUtf8(cookieValue));
            if (match.hasMatch()) {
                QString newJsessionId = match.captured(1);
                if (newJsessionId != jsessionId) {
                    jsessionId = newJsessionId;
                    qInfo() << "Updated JSESSIONID from checkout buynow response";
                }
            }
        }
    }
    
    if (statusCode != 200) {
        QString errorMsg = QString("Checkout buynow failed with status %1").arg(statusCode);
        if (!data.isEmpty()) {
            errorMsg += ": " + QString::fromUtf8(data);
        }
        qWarning() << errorMsg;
        emit sessionComplete(false, errorMsg, entitlementId);
        return;
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (doc.isNull() || !doc.isObject()) {
        emit sessionComplete(false, "Invalid JSON in checkout buynow response", entitlementId);
        return;
    }
    
    QJsonObject obj = doc.object();
    QJsonObject header = obj["header"].toObject();
    QString statusCodeHex = header["status_code"].toString();
    
    if (statusCodeHex != "0x0000") {
        QString message = header["message_key"].toString();
        qWarning() << "Checkout buynow failed - Status:" << statusCodeHex << "Message:" << message;
        emit sessionComplete(false, QString("Checkout failed: %1").arg(message), entitlementId);
        return;
    }
    
    QJsonObject dataObj = obj["data"].toObject();
    QString transactionId = dataObj["transaction_id"].toString();
    
    qInfo() << "Kamaji Step 0.5e.4 complete - Entitlement successfully acquired!";
    qInfo() << "  Transaction ID:" << transactionId;
    qInfo() << "Kamaji Step 0.5e complete - Entitlement check/acquisition successful";
    
    // Continue to Step 5: Get authenticated session OAuth code
    step5_GetAuthCode();
}

// ============================================================================
// Step 5: GET /oauth/authorize (for authenticated session OAuth code)
// ============================================================================
void PSKamajiSession::step5_GetAuthCode()
{
    QUrl url(accountBase + "/v1/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("smcid", "pc:psnow");
    query.addQueryItem("applicationId", "psnow");
    query.addQueryItem("response_type", "code");
    query.addQueryItem("scope", scopesStr);
    query.addQueryItem("client_id", kamajiClientId);
    query.addQueryItem("redirect_uri", redirectUriUrl);
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("mid", "PSNOW");
    query.addQueryItem("duid", duid);
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("service_logo", "ps");
    query.addQueryItem("tp_psn", "true");
    query.addQueryItem("noEVBlock", "true");
    url.setQuery(query);
    
    qInfo() << "Kamaji Step 5: GET /oauth/authorize (for authenticated session code)";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url.toString();
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    // Add npsso cookie for OAuth authorization
    if (!npssoToken.isEmpty()) {
        req.setRawHeader("Cookie", QString("npsso=%1").arg(npssoToken).toUtf8());
    }
    
    logKamajiRequest("Step 5: GetAuthCode", req);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAuthCodeResponse(reply);
    });
}

void PSKamajiSession::handleAuthCodeResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Kamaji Step 5 Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        if (!redirectUrl.isEmpty()) {
            qInfo() << "  Redirect URL:" << redirectUrl.toString();
        }
        QByteArray response = reply->readAll();
        if (!response.isEmpty()) {
            qInfo() << "  Body:" << QString(response);
        }
    }
    
    if (statusCode != 302) {
        emit sessionComplete(false, QString("Expected 302 redirect, got: %1").arg(statusCode), QString());
        return;
    }
    
    QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
    QString code = QUrlQuery(redirectUrl).queryItemValue("code");
    
    if (code.isEmpty()) {
        emit sessionComplete(false, "No authorization code in redirect", QString());
        return;
    }
    
    qInfo() << "Kamaji Step 5 complete - Got authenticated auth code:" << code.left(20) << "...";
    authorizationCode = code;
    step6_CreateAuthSession();
}

// ============================================================================
// Step 6: POST authenticated session with auth code
// ============================================================================
void PSKamajiSession::step6_CreateAuthSession()
{
    QString url = kamajiBase + "/user/session";
    QString body = QString("code=%1&client_id=%2&duid=%3")
        .arg(authorizationCode)
        .arg(kamajiClientId)
        .arg(duid);
    
    qInfo() << "Kamaji Step 6: POST authenticated session";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: POST";
        qInfo() << "  Content-Type: text/plain;charset=UTF-8";
        qInfo() << "  User-Agent:" << userAgentString;
        qInfo() << "  X-Alt-Referer:" << redirectUriUrl;
        qInfo() << "  Origin: https://psnow.playstation.com";
        qInfo() << "  Referer: https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/";
        qInfo() << "  Body:" << body;
    }
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Content-Type", "text/plain;charset=UTF-8");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Alt-Referer", redirectUriUrl.toUtf8());
    req.setRawHeader("Origin", "https://psnow.playstation.com");
    req.setRawHeader("Referer", "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/");
    
    QByteArray requestBody = body.toUtf8();
    logKamajiRequest("Step 6: CreateAuthSession", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAuthSessionResponse(reply);
    });
}

void PSKamajiSession::handleAuthSessionResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray response = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Kamaji Step 6 Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
        qInfo() << "  Body:" << QString(response);
    }
    
    if (reply->error() != QNetworkReply::NoError) {
        emit sessionComplete(false, QString("Auth session failed: %1").arg(reply->errorString()), entitlementId);
        return;
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(response);
    
    if (doc.isNull() || !doc.isObject()) {
        emit sessionComplete(false, "Invalid JSON in session response", entitlementId);
        return;
    }
    
    QJsonObject obj = doc.object();
    
    // Parse Kamaji response format (has header/data structure)
    QJsonObject header = obj["header"].toObject();
    QJsonObject data = obj["data"].toObject();
    
    if (header["status_code"].toString() != "0x0000") {
        QString statusCode = header["status_code"].toString();
        emit sessionComplete(false, QString("Session failed with status: %1").arg(statusCode), entitlementId);
        return;
    }
    
    // Store session data in class members (not persisted to settings)
    accountId = data["accountId"].toString();
    onlineId = data["onlineId"].toString();
    sessionUrl = data["sessionUrl"].toString();
    
    qInfo() << "=== Kamaji Session Created Successfully ===";
    qInfo() << "Authenticated as:" << onlineId;
    qInfo() << "Account ID:" << accountId;
    qInfo() << "Entitlement ID:" << entitlementId;
    
    emit sessionComplete(true, "Kamaji authentication complete", entitlementId);
}
