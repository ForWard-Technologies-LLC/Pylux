// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/pskamajisession.h"
#include "chiaki/remote/holepunch.h"

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QNetworkCookie>
#include <QNetworkCookieJar>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QUrl>
#include <QRegularExpression>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// ============================================================================
// Kamaji-specific constants
// ============================================================================
namespace KamajiConsts {
    static const QString KAMAJI_BASE = "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000";
    static const QString CLIENT_ID = "bc6b0777-abb5-40da-92ca-e133cf18e989";
    
    // PS3 scopes (different from PS4)
    static const QString PS3_SCOPES = "kamaji:commerce_native";
    
    // PS4 scopes
    static const QString PS4_SCOPES = "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get";
}

PSKamajiSession::PSKamajiSession(
    Settings *settings,
    QString npsso,
    QString deviceUid,
    QString platformParam,
    QString productIdParam,
    QString accountBaseUrl,
    QString redirectUri,
    QString userAgent,
    QObject *parent
)
    : QObject(parent)
    , settings(settings)
    , npssoToken(npsso)
    , duid(deviceUid)
    , platform(platformParam.toLower())
    , productId(productIdParam)
    , kamajiBase(KamajiConsts::KAMAJI_BASE)
    , accountBase(accountBaseUrl)
    , kamajiClientId(KamajiConsts::CLIENT_ID)
    , redirectUriUrl(redirectUri)
    , userAgentString(userAgent)
{
    // Determine scopes based on platform
    if (platform == "ps3") {
        scopesStr = KamajiConsts::PS3_SCOPES;
    } else {
        scopesStr = KamajiConsts::PS4_SCOPES; // Default to PS4 scopes
    }
    
    manager = new QNetworkAccessManager(this);
    cookieJar = new QNetworkCookieJar(this);
    manager->setCookieJar(cookieJar);
    
    // Add NPSSO cookie to account session early (needed for authorizeCheck)
    // Use leading dot for subdomain matching (works for ca.account.sony.com)
    QNetworkCookie npssoCookie("npsso", npssoToken.toUtf8());
    npssoCookie.setDomain(".account.sony.com");  // Leading dot allows subdomain matching
    npssoCookie.setPath("/");
    cookieJar->insertCookie(npssoCookie);
    
    // Also add cookie for ca.account.sony.com specifically (Qt cookie jar can be picky)
    QNetworkCookie npssoCookieCa("npsso", npssoToken.toUtf8());
    npssoCookieCa.setDomain("ca.account.sony.com");
    npssoCookieCa.setPath("/");
    cookieJar->insertCookie(npssoCookieCa);
    
    qInfo() << "NPSSO cookie added to cookie jar for authorizeCheck";
}

void PSKamajiSession::startSessionCreation()
{
    qInfo() << "Kamaji Session: Starting simplified authentication flow (Steps 0.5a-0.5d, 5-6)...";
    qInfo() << "Platform:" << platform;
    qInfo() << "Product ID:" << productId;
    
    if (npssoToken.isEmpty()) {
        QString error = "NPSSO token is empty";
        qWarning() << "Kamaji Session:" << error;
        emit sessionComplete(false, error, QString());
        return;
    }
    
    // Step 0.5a: POST /authorizeCheck (FIRST step)
    step0_5a_AuthorizeCheck();
}

// ============================================================================
// Step 0.5a: POST /authorizeCheck (FIRST step after NPSSO setup)
// ============================================================================
void PSKamajiSession::step0_5a_AuthorizeCheck()
{
    QString url = accountBase + "/authz/v3/oauth/authorizeCheck";
    
    QJsonObject body;
    body["client_id"] = kamajiClientId;
    body["scope"] = scopesStr;
    body["redirect_uri"] = redirectUriUrl;
    body["response_type"] = "code";
    body["service_entity"] = "urn:service-entity:psn";
    body["duid"] = duid;
    
    QJsonDocument doc(body);
    
    qInfo() << "Kamaji Step 0.5a: POST /authorizeCheck";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: POST";
        qInfo() << "  Content-Type: application/json; charset=UTF-8";
        qInfo() << "  Body:" << doc.toJson(QJsonDocument::Compact);
    }
    
    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json; charset=UTF-8");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAuthorizeCheckResponse(reply);
    });
}

void PSKamajiSession::handleAuthorizeCheckResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    if (settings && settings->GetLogVerbose()) {
        int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qInfo() << "=== Kamaji Step 0.5a Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
        QByteArray response = reply->readAll();
        if (!response.isEmpty()) {
            qInfo() << "  Body:" << QString(response);
        }
    }
    
    if (reply->error() != QNetworkReply::NoError) {
        emit sessionComplete(false, QString("authorizeCheck failed: %1").arg(reply->errorString()), QString());
        return;
    }
    
    // Continue to Step 0.5b: Get anonymous session OAuth code
    step0_5b_GetAnonymousAuthCode();
}

// ============================================================================
// Step 0.5b: GET /oauth/authorize (for anonymous session OAuth code)
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
    
    // Create a new empty cookie jar for this request (no cookies)
    QNetworkCookieJar *emptyCookieJar = new QNetworkCookieJar(this);
    QNetworkAccessManager *tempManager = new QNetworkAccessManager(this);
    tempManager->setCookieJar(emptyCookieJar);
    
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
    
    QNetworkReply *reply = tempManager->post(req, body.toUtf8());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, tempManager, emptyCookieJar]() {
        handleAnonSessionResponse(reply);
        tempManager->deleteLater();
        emptyCookieJar->deleteLater();
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
                
                // Add JSESSIONID to main cookie jar
                QNetworkCookie jsessionCookie("JSESSIONID", jsessionId.toUtf8());
                jsessionCookie.setDomain("psnow.playstation.com");
                jsessionCookie.setPath("/");
                cookieJar->insertCookie(jsessionCookie);
                
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
// GET /store/api/pcnow/00_09_000/container/US/en/19/{PRODUCT_ID}?useOffers=true&gkb=1&gkb2=1
// ============================================================================
void PSKamajiSession::step0_5d_ConvertProductId()
{
    QString url = QString("https://psnow.playstation.com/store/api/pcnow/00_09_000/container/US/en/19/%1?useOffers=true&gkb=1&gkb2=1")
        .arg(productId);
    
    qInfo() << "Kamaji Step 0.5d: Convert Product ID to Entitlement ID";
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: GET";
        qInfo() << "  Product ID:" << productId;
    }
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    
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
    
    // Look for streaming SKU and entitlement
    if (obj.contains("skus") && obj["skus"].isArray()) {
        QJsonArray skus = obj["skus"].toArray();
        for (const QJsonValue &skuValue : skus) {
            QJsonObject skuObj = skuValue.toObject();
            QString skuId = skuObj["id"].toString();
            
            // Look for streaming SKUs (end in -UC0X where X is any digit)
            QRegularExpression streamingSkuRegex("-UC0\\d+$");
            QRegularExpressionMatch skuMatch = streamingSkuRegex.match(skuId);
            if (skuMatch.hasMatch()) {
                sku = skuId;
                streamingSku = sku;  // Store for entitlement check
                qInfo() << "Found streaming SKU:" << sku;
                
                if (skuObj.contains("entitlements") && skuObj["entitlements"].isArray()) {
                    QJsonArray entitlements = skuObj["entitlements"].toArray();
                    for (const QJsonValue &entValue : entitlements) {
                        QJsonObject ent = entValue.toObject();
                        QString entId = ent["id"].toString();
                        QString packageType = ent["packageType"].toString();
                        
                        // Check if this is a streaming entitlement
                        QRegularExpression psnwRegex("PSNW\\d+$");
                        bool isStreamingEnt = (packageType == "PS4GS") ||
                                            entId.endsWith("PSRSVD0000000000") ||
                                            psnwRegex.match(entId).hasMatch();
                        
                        if (isStreamingEnt) {
                            streamingEntitlementId = entId;
                            qInfo() << "Found Entitlement ID:" << streamingEntitlementId;
                            qInfo() << "Package Type:" << packageType;
                            break;
                        }
                    }
                }
                if (!streamingEntitlementId.isEmpty()) break;
            }
        }
    }
    
    // Fallback: infer entitlement ID if not found in API
    if (streamingEntitlementId.isEmpty()) {
        qWarning() << "Entitlement ID not found in API response, inferring from Product ID...";
        QString titleIdPrefix;
        
        // Extract title ID prefix (e.g., "UP2026-NPUB30498_00" from "UP2026-NPUB30498_00-PS3SAMMAXBTSEP04")
        QRegularExpression titleIdRegex("^([A-Z]{2}\\d{4}-[A-Z]{4}\\d{5}_\\d{2}).*");
        QRegularExpressionMatch titleMatch = titleIdRegex.match(productId);
        if (titleMatch.hasMatch()) {
            titleIdPrefix = titleMatch.captured(1);
            
            // Infer based on product ID pattern
            if (productId.contains("CUSA") || productId.contains("PPSA")) {
                streamingEntitlementId = titleIdPrefix + "-PSRSVD0000000000";
            } else if (productId.contains("NPU")) {
                streamingEntitlementId = titleIdPrefix + "-PSNW01";
            }
            
            if (!streamingEntitlementId.isEmpty()) {
                qInfo() << "Inferred Entitlement ID:" << streamingEntitlementId;
            }
        }
    }
    
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
    
    // Only use npsso cookie, NOT JSESSIONID
    QList<QNetworkCookie> cookies = cookieJar->cookiesForUrl(QUrl("https://ca.account.sony.com"));
    QByteArray cookieHeader;
    for (const QNetworkCookie &cookie : cookies) {
        if (cookie.name() == "npsso") {
            if (!cookieHeader.isEmpty()) cookieHeader += "; ";
            cookieHeader += cookie.name() + "=" + cookie.value();
        }
    }
    if (!cookieHeader.isEmpty()) {
        req.setRawHeader("Cookie", cookieHeader);
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
    
    // Continue to check entitlement
    step0_5e_CheckEntitlementExists();
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
    
    // Add JSESSIONID cookie
    QList<QNetworkCookie> cookies = cookieJar->cookiesForUrl(QUrl("https://psnow.playstation.com"));
    QByteArray cookieHeader;
    for (const QNetworkCookie &cookie : cookies) {
        if (cookie.name() == "JSESSIONID") {
            cookieHeader = cookie.name() + "=" + cookie.value();
            break;
        }
    }
    if (!cookieHeader.isEmpty()) {
        req.setRawHeader("Cookie", cookieHeader);
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
    
    // Note: Qt's QNetworkReply may automatically decompress gzip responses
    // If we get invalid JSON, may need to add explicit gzip decompression later
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Checkout Preview Response ===";
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
                    QNetworkCookie jsessionCookie("JSESSIONID", newJsessionId.toUtf8());
                    jsessionCookie.setDomain("psnow.playstation.com");
                    jsessionCookie.setPath("/");
                    cookieJar->insertCookie(jsessionCookie);
                    qInfo() << "Updated JSESSIONID from checkout preview response";
                }
            }
        }
    }
    
    if (statusCode != 200) {
        QString errorMsg = QString("Checkout preview failed with status %1").arg(statusCode);
        if (!data.isEmpty()) {
            errorMsg += ": " + QString::fromUtf8(data);
        }
        qWarning() << errorMsg;
        emit sessionComplete(false, errorMsg, entitlementId);
        return;
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (doc.isNull() || !doc.isObject()) {
        emit sessionComplete(false, "Invalid JSON in checkout preview response", entitlementId);
        return;
    }
    
    QJsonObject obj = doc.object();
    QJsonObject header = obj["header"].toObject();
    QString statusCodeHex = header["status_code"].toString();
    
    if (statusCodeHex != "0x0000") {
        QString message = header["message_key"].toString();
        qWarning() << "Checkout preview failed - Status:" << statusCodeHex << "Message:" << message;
        emit sessionComplete(false, QString("Checkout preview failed: %1").arg(message), entitlementId);
        return;
    }
    
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
    
    // Add JSESSIONID cookie
    QList<QNetworkCookie> cookies = cookieJar->cookiesForUrl(QUrl("https://psnow.playstation.com"));
    QByteArray cookieHeader;
    for (const QNetworkCookie &cookie : cookies) {
        if (cookie.name() == "JSESSIONID") {
            cookieHeader = cookie.name() + "=" + cookie.value();
            break;
        }
    }
    if (!cookieHeader.isEmpty()) {
        req.setRawHeader("Cookie", cookieHeader);
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
                    QNetworkCookie jsessionCookie("JSESSIONID", newJsessionId.toUtf8());
                    jsessionCookie.setDomain("psnow.playstation.com");
                    jsessionCookie.setPath("/");
                    cookieJar->insertCookie(jsessionCookie);
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
    
    QNetworkReply *reply = manager->post(req, body.toUtf8());
    
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
