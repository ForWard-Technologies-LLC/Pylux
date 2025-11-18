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
#include <QUrlQuery>

// ============================================================================
// Kamaji-specific constants
// ============================================================================
namespace KamajiConsts {
    static const QString KAMAJI_BASE = "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000";
    static const QString CLIENT_ID = "bc6b0777-abb5-40da-92ca-e133cf18e989";
    static const QString WEBDUID = "000000070006010086b3d2db5216ebc265b15051c798360de8420d507a1ca34f58504a9fcaabfbfb";
    static const QString SCOPES = "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get";
}

PSKamajiSession::PSKamajiSession(
    Settings *settings,
    QString npsso,
    QString deviceUid,
    QString accountBaseUrl,
    QString redirectUri,
    QString userAgent,
    QObject *parent
)
    : QObject(parent)
    , settings(settings)
    , npssoToken(npsso)
    , duid(deviceUid)
    , kamajiBase(KamajiConsts::KAMAJI_BASE)
    , accountBase(accountBaseUrl)
    , kamajiClientId(KamajiConsts::CLIENT_ID)
    , redirectUriUrl(redirectUri)
    , scopesStr(KamajiConsts::SCOPES)
    , userAgentString(userAgent)
{
    manager = new QNetworkAccessManager(this);
    cookieJar = new QNetworkCookieJar(this);
    manager->setCookieJar(cookieJar);
    
    // Set WEBDUID cookie
    QNetworkCookie webduidCookie("WEBDUID", KamajiConsts::WEBDUID.toUtf8());
    webduidCookie.setDomain("psnow.playstation.com");
    webduidCookie.setPath("/");
    cookieJar->insertCookie(webduidCookie);
}

void PSKamajiSession::startSessionCreation()
{
    qInfo() << "Kamaji Session: Starting authentication flow (Steps 1-6)...";
    
    if (npssoToken.isEmpty()) {
        QString error = "NPSSO token is empty";
        qWarning() << "Kamaji Session:" << error;
        emit sessionComplete(false, error);
        return;
    }
    
    step1_DeleteExisting();
}

// ============================================================================
// Step 1: DELETE existing session
// ============================================================================
void PSKamajiSession::step1_DeleteExisting()
{
    qInfo() << "Kamaji Step 1: DELETE existing session";
    
    QString url = kamajiBase + "/user/session";
    QNetworkRequest req{QUrl(url)};
    QNetworkReply *reply = manager->deleteResource(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleDeleteResponse(reply);
    });
}

void PSKamajiSession::handleDeleteResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    // Deletion success/failure doesn't matter - proceed to next step
    step2_CreateAnonymous();
}

// ============================================================================
// Step 2: POST anonymous session
// ============================================================================
void PSKamajiSession::step2_CreateAnonymous()
{
    qInfo() << "Kamaji Step 2: POST anonymous session";
    
    QString url = kamajiBase + "/user/session";
    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    
    QString body = "country_code=US&language_code=en&date_of_birth=1981-01-01";
    QNetworkReply *reply = manager->post(req, body.toUtf8());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleCreateResponse(reply);
    });
}

void PSKamajiSession::handleCreateResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    if (reply->error() != QNetworkReply::NoError) {
        emit sessionComplete(false, QString("Anonymous session failed: %1").arg(reply->errorString()));
        return;
    }
    
    step3_SignOut();
}

// ============================================================================
// Step 3: GET /signOut
// ============================================================================
void PSKamajiSession::step3_SignOut()
{
    qInfo() << "Kamaji Step 3: GET /signOut";
    
    QUrl url(accountBase + "/authn/v3/signOut");
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
    url.setQuery(query);
    
    QNetworkRequest req(url);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleSignOutResponse(reply);
    });
}

void PSKamajiSession::handleSignOutResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    // Add NPSSO cookie
    QNetworkCookie npssoCookie("npsso", npssoToken.toUtf8());
    npssoCookie.setDomain(".account.sony.com");
    npssoCookie.setPath("/");
    cookieJar->insertCookie(npssoCookie);
    
    step4_AuthorizeCheck();
}

// ============================================================================
// Step 4: POST /authorizeCheck
// ============================================================================
void PSKamajiSession::step4_AuthorizeCheck()
{
    qInfo() << "Kamaji Step 4: POST /authorizeCheck";
    
    QString url = accountBase + "/authz/v3/oauth/authorizeCheck";
    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json; charset=UTF-8");
    
    QJsonObject body;
    body["client_id"] = kamajiClientId;
    body["scope"] = scopesStr;
    body["redirect_uri"] = redirectUriUrl;
    body["response_type"] = "code";
    body["service_entity"] = "urn:service-entity:psn";
    body["duid"] = duid;
    
    QJsonDocument doc(body);
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAuthorizeCheckResponse(reply);
    });
}

void PSKamajiSession::handleAuthorizeCheckResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    if (reply->error() != QNetworkReply::NoError) {
        emit sessionComplete(false, QString("authorizeCheck failed: %1").arg(reply->errorString()));
        return;
    }
    
    step5_GetAuthCode();
}

// ============================================================================
// Step 5: GET /oauth/authorize (get auth code from redirect)
// ============================================================================
void PSKamajiSession::step5_GetAuthCode()
{
    qInfo() << "Kamaji Step 5: GET /oauth/authorize";
    
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
    
    QNetworkRequest req(url);
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
    if (statusCode != 302) {
        emit sessionComplete(false, QString("Expected 302 redirect, got: %1").arg(statusCode));
        return;
    }
    
    QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
    QString code = QUrlQuery(redirectUrl).queryItemValue("code");
    
    if (code.isEmpty()) {
        emit sessionComplete(false, "No authorization code in redirect");
        return;
    }
    
    qInfo() << "Kamaji Step 5 complete - Got auth code:" << code;
    authorizationCode = code;
    step6_CreateAuthSession();
}

// ============================================================================
// Step 6: POST authenticated session with auth code
// ============================================================================
void PSKamajiSession::step6_CreateAuthSession()
{
    qInfo() << "Kamaji Step 6: POST authenticated session";
    
    QString url = kamajiBase + "/user/session";
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Content-Type", "text/plain;charset=UTF-8");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Alt-Referer", redirectUriUrl.toUtf8());
    req.setRawHeader("Origin", "https://psnow.playstation.com");
    req.setRawHeader("Referer", "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/");
    
    QString body = QString("code=%1&client_id=%2&duid=%3")
        .arg(authorizationCode)
        .arg(kamajiClientId)
        .arg(duid);
    
    QNetworkReply *reply = manager->post(req, body.toUtf8());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAuthSessionResponse(reply);
    });
}

void PSKamajiSession::handleAuthSessionResponse(QNetworkReply *reply)
{
    reply->deleteLater();
    
    // DEBUG: Log full response
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    qDebug() << "=== Kamaji Step 6 Response ===";
    qDebug() << "HTTP Status:" << statusCode;
    qDebug() << "Headers:";
    for (const auto &header : reply->rawHeaderPairs()) {
        qDebug() << "  " << header.first << ":" << header.second;
    }
    
    if (reply->error() != QNetworkReply::NoError) {
        qDebug() << "Network Error:" << reply->error() << reply->errorString();
        emit sessionComplete(false, QString("Auth session failed: %1").arg(reply->errorString()));
        return;
    }
    
    QByteArray response = reply->readAll();
    qDebug() << "Response Body:" << QString(response);
    qDebug() << "Response Body (hex):" << response.toHex();
    
    QJsonDocument doc = QJsonDocument::fromJson(response);
    
    if (doc.isNull() || !doc.isObject()) {
        qDebug() << "ERROR: Invalid JSON in response";
        emit sessionComplete(false, "Invalid JSON in session response");
        return;
    }
    
    QJsonObject obj = doc.object();
    qDebug() << "Parsed JSON keys:" << obj.keys();
    
    // Parse Kamaji response format (has header/data structure)
    QJsonObject header = obj["header"].toObject();
    QJsonObject data = obj["data"].toObject();
    
    qDebug() << "Header keys:" << header.keys();
    qDebug() << "Data keys:" << data.keys();
    
    if (header["status_code"].toString() != "0x0000") {
        QString statusCode = header["status_code"].toString();
        qDebug() << "ERROR: Session failed with status:" << statusCode;
        emit sessionComplete(false, QString("Session failed with status: %1").arg(statusCode));
        return;
    }
    
    // Store session data in class members (not persisted to settings)
    accountId = data["accountId"].toString();
    onlineId = data["onlineId"].toString();
    sessionUrl = data["sessionUrl"].toString();
    
    qDebug() << "Account ID:" << accountId;
    qDebug() << "Online ID:" << onlineId;
    qDebug() << "Session URL:" << sessionUrl;
    
    qInfo() << "=== Kamaji Session Created Successfully ===";
    qInfo() << "Authenticated as:" << onlineId;
    qInfo() << "Account ID:" << accountId;
    
    emit sessionComplete(true, "Kamaji authentication complete");
}

