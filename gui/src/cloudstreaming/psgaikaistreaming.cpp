// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/psgaikaistreaming.h"
#include "chiaki/remote/holepunch.h"
#include "chiaki/common.h"

#include <QObject>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QNetworkCookie>
#include <QUrlQuery>

// ============================================================================
// GAIKAI CONFIG - Gaikai-specific base URLs only
// ============================================================================
namespace GaikaiConsts {
    static const QString CONFIG_BASE = "https://config.cc.prod.gaikai.com/v1";
    static const QString GAIKAI_BASE = "https://cc.prod.gaikai.com/v1";
}

PSGaikaiStreaming::PSGaikaiStreaming(Settings *settings, QString npsso, QString deviceUid,
                                   QString serviceTypeParam, QString platformParam,
                                   QNetworkCookieJar *cookieJar,
                                   QString accountBase, QString redirectUri, QString userAgent, QString oauthApiPathParam,
                                   QObject *parent)
    : QObject(parent)
    , settings(settings)
    , npsso(npsso)
    , duid(deviceUid)
    , serviceType(serviceTypeParam.toLower())
    , platform(platformParam.toLower())
    , cookieJar(cookieJar)
    , accountBaseUrl(accountBase)
    , redirectUriUrl(redirectUri)
    , userAgentString(userAgent)
    , oauthApiPath(oauthApiPathParam)
{
    // Determine virtType from platform
    if (platform == "ps3") {
        virtType = "konan";
    } else if (platform == "ps4") {
        virtType = "kratos";
    } else if (platform == "ps5") {
        virtType = "cronos";
    }
    
    manager = new QNetworkAccessManager(this);
    manager->setCookieJar(cookieJar);
    
    // Ensure NPSSO cookie is in the cookie jar for OAuth requests (needed for PSCLOUD)
    // For PSNOW, this should already be set by Kamaji session, but adding here ensures it's there
    QList<QNetworkCookie> existingCookies = cookieJar->cookiesForUrl(QUrl("https://ca.account.sony.com"));
    bool hasNpsso = false;
    for (const QNetworkCookie &cookie : existingCookies) {
        if (cookie.name() == "npsso") {
            hasNpsso = true;
            break;
        }
    }
    
    if (!hasNpsso && !npsso.isEmpty()) {
        // Add NPSSO cookie for account.sony.com domains
        QNetworkCookie npssoCookie("npsso", npsso.toUtf8());
        npssoCookie.setDomain(".account.sony.com");
        npssoCookie.setPath("/");
        cookieJar->insertCookie(npssoCookie);
        
        // Also add for ca.account.sony.com specifically
        QNetworkCookie npssoCookieCa("npsso", npsso.toUtf8());
        npssoCookieCa.setDomain("ca.account.sony.com");
        npssoCookieCa.setPath("/");
        cookieJar->insertCookie(npssoCookieCa);
        
        qInfo() << "Added NPSSO cookie to cookie jar for Gaikai OAuth requests";
    }
    
    // Initialize port to 0 (will be set from step12 response)
    selectedDatacenterPort = 0;
}

QJsonObject PSGaikaiStreaming::buildRequestGameSpec(QString entitlementId)
{
    QJsonObject spec;
    
    // Configuration constants (matching CloudConfig in cloudstreamingbackend.cpp)
    // TODO: Pass these as parameters from CloudStreamingBackend when ready
    static const int RESOLUTION = 1080;  // Supported values: 720 or 1080 only
    static const QString LANGUAGE = "en-US";
    static const QString TIMEZONE = "UTC-08:00";
    
    // Core Game Configuration
    spec["entitlementId"] = entitlementId;
    spec["npEnv"] = "np";
    spec["language"] = LANGUAGE;
    
    // Cloud Infrastructure
    spec["cloudEndpoint"] = "https://cc.prod.gaikai.com";
    spec["redirectUri"] = redirectUriUrl;
    
    // Audio Configuration
    spec["audioChannels"] = (serviceType == "pscloud") ? "2" : "2.1";
    spec["audioEncoderProfile"] = "default";
    spec["audioUploadEnabled"] = true;
    spec["audioUploadNumChannels"] = 1;
    spec["audioUploadSamplingFrequency"] = 48000;
    
    // Video Configuration - Only support 720 or 1080
    int resolution = RESOLUTION;
    QString resolutionSetting;
    int clientWidth, clientHeight;
    if (resolution == 720) {
        resolutionSetting = "720";
        clientWidth = 1280;
        clientHeight = 720;
    } else {
        // Default to 1080 (or if invalid value)
        resolutionSetting = "1080";
        clientWidth = 1920;
        clientHeight = 1080;
    }
    
    spec["resolutionSetting"] = resolutionSetting;
    spec["clientWidth"] = clientWidth;
    spec["clientHeight"] = clientHeight;
    spec["adaptiveStreamMode"] = "resize";
    
    // Service/platform-specific video encoder
    if (serviceType == "pscloud") {
        spec["videoEncoderProfile"] = "hw5.0";  // PSCLOUD PS5
    } else {
        spec["videoEncoderProfile"] = "hw4.1";  // PSNOW PS3/PS4
    }
    spec["useClientBwLadder"] = true;
    
    // Input Configuration
    QJsonObject inputObj;
    QJsonArray controllersArray;
    if (serviceType == "pscloud") {
        controllersArray.append("ds4");
        controllersArray.append("ds5");
        controllersArray.append("xinput");
        spec["connectedControllers"] = controllersArray;
    } else {
        spec["connectedControllers"] = QJsonArray::fromStringList({"xinput"});
    }
    inputObj["controllers"] = controllersArray;
    spec["input"] = inputObj;
    spec["acceptButton"] = "X";
    
    // Device/Platform Info
    if (serviceType == "pscloud") {
        spec["model"] = "portal";
        spec["platform"] = "qlite";
    } else {
        spec["model"] = "WINDOWS";
        spec["platform"] = "PC";
    }
    spec["httpUserAgent"] = userAgentString;
    
    // Protocol Settings
    if (serviceType == "pscloud") {
        spec["gaikaiPlayer"] = "16.4.0";      // PSCLOUD PS5
        spec["protocolVersion"] = 12;
    } else {
        spec["gaikaiPlayer"] = "12.5.0";      // PSNOW PS3/PS4
        spec["protocolVersion"] = 9;
    }
    spec["encryptionSupported"] = true;
    
    // Timezone
    spec["summerTime"] = 0;
    spec["timeZone"] = TIMEZONE;
    
    // Accessibility Features (all disabled)
    spec["accessibilityMarqueeSpeed"] = 0;
    spec["accessibilityLargeText"] = 0;
    spec["accessibilityBoldText"] = 0;
    spec["accessibilityContrast"] = 0;
    spec["accessibilityTtsEnable"] = 0;
    spec["accessibilityTtsSpeed"] = 0;
    spec["accessibilityTtsVolume"] = 0;
    
    // Capability Flags
    spec["partyCapability"] = false;
    spec["homesharing"] = false;
    spec["isFirstBoot"] = false;
    spec["isPlusMember"] = true;
    spec["parentalLevel"] = 0;
    spec["yuvCoefficient"] = "";
    
    // Auth Codes (will be updated later in step 9)
    spec["gkCloudAuthCode"] = gkCloudAuthCode;
    if (serviceType == "pscloud") {
        spec["ps3AuthCode"] = "";  // PSCLOUD: empty
        spec["streamServerAuthCode"] = streamServerAuthCode;
    } else {
        spec["ps3AuthCode"] = ps3AuthCode;  // PSNOW: use ps3AuthCode
        spec["streamServerAuthCode"] = ps3AuthCode;  // PSNOW: same as ps3AuthCode
    }
    
    // Capabilities (service/platform-specific)
    QJsonArray capabilitiesArray;
    capabilitiesArray.append("cloudDrivenSenkushaTest");
    if (serviceType == "pscloud") {
        capabilitiesArray.append("cronos");  // PSCLOUD PS5
    } else {
        capabilitiesArray.append("kratos");  // PSNOW PS3/PS4 (both use kratos)
    }
    spec["capabilities"] = capabilitiesArray;
    
    // Conditionally add video/audio stream settings for PSCLOUD (PS5) only
    // PSNOW does not use these settings - it uses H.264 with hw4.1
    if (serviceType == "pscloud") {
        QJsonObject videoStreamSettings;
        videoStreamSettings["clientHeight"] = clientHeight;
        videoStreamSettings["supportedMaxResolution"] = clientHeight;
        QJsonArray videoProfiles;
        videoProfiles.append("hevc_hw4");
        videoStreamSettings["supportedVideoEncoderProfiles"] = videoProfiles;
        videoStreamSettings["supportedDynamicRange"] = "sdr";
        videoStreamSettings["preferredMaxResolution"] = clientHeight;
        videoStreamSettings["preferredDynamicRange"] = "sdr";
        videoStreamSettings["hqMode"] = 0;
        spec["videoStreamSettings"] = videoStreamSettings;
        
        QJsonObject audioStreamSettings;
        audioStreamSettings["audioEncoderProfile"] = "default";
        audioStreamSettings["maxAudioChannels"] = "2";
        audioStreamSettings["preferredNumberAudioChannels"] = "2";
        spec["audioStreamSettings"] = audioStreamSettings;
    }
    
    // Log the full JSON for inspection
    qInfo() << "=== buildRequestGameSpec - Full JSON ===";
    qInfo() << "Service:" << serviceType << "Platform:" << platform;
    qInfo() << QJsonDocument(spec).toJson(QJsonDocument::Indented);
    qInfo() << "========================================";
    
    return spec;
}

void PSGaikaiStreaming::updateSessionKey(QNetworkReply *reply)
{
    QString newKey = QString::fromUtf8(reply->rawHeader("x-gaikai-session"));
    if (!newKey.isEmpty()) {
        configKey = newKey;
        qInfo() << "Gaikai: Updated session key:" << configKey.left(30) << "...";
    }
}

void PSGaikaiStreaming::logDebugResponse(const QString &stepName, QNetworkReply *reply)
{
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    qDebug() << "=== Gaikai" << stepName << "Response ===";
    qDebug() << "HTTP Status:" << statusCode;
    qDebug() << "Headers:";
    for (const auto &header : reply->rawHeaderPairs()) {
        qDebug() << "  " << header.first << ":" << header.second;
    }
    
    QByteArray responseBody = reply->peek(reply->bytesAvailable());
    qDebug() << "Response Body:" << QString(responseBody);
    
    if (reply->error() != QNetworkReply::NoError) {
        qDebug() << "Network Error:" << reply->error() << reply->errorString();
    }
}

void PSGaikaiStreaming::StartAllocationFlow(QString entitlementId, const QJSValue &callback)
{
    qInfo() << "Gaikai Allocation: Starting complete flow";
    qInfo() << "  Service Type:" << serviceType;
    qInfo() << "  Platform:" << platform;
    qInfo() << "  virtType:" << virtType;
    qInfo() << "  Entitlement ID:" << entitlementId;
    finalCallback = callback;
    
    // Store entitlement for later use (will be updated with auth codes in step 8)
    requestGameSpec = buildRequestGameSpec(entitlementId);
    
    // Start with Step 0: Get Client IDs (MUST happen FIRST)
    step0_GetClientIds();
}

// Step 0: Get Client IDs (MUST happen FIRST before step7)
void PSGaikaiStreaming::step0_GetClientIds()
{
    qInfo() << "Gaikai Step 0: Getting client IDs for virtType:" << virtType;
    
    QString url = QString("https://cc.prod.gaikai.com/v1/client_ids?virtType=%1").arg(virtType);
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("Accept", "*/*");
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 0 failed:" << reply->errorString();
            emit AllocationError(QString("Client IDs failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject jsonObj = jsonDoc.object();
        
        gkClientId = jsonObj["gkClientId"].toString();
        ps3GkClientId = jsonObj["ps3GkClientId"].toString();  // Present for PSNOW (PS3/PS4)
        streamServerClientId = jsonObj["streamServerClientId"].toString();  // Present for PSCLOUD (PS5)
        
        qInfo() << "Gaikai Step 0 complete:";
        qInfo() << "  gkClientId:" << gkClientId;
        if (!ps3GkClientId.isEmpty()) {
            qInfo() << "  ps3GkClientId:" << ps3GkClientId;
        }
        if (!streamServerClientId.isEmpty()) {
            qInfo() << "  streamServerClientId:" << streamServerClientId;
        }
        
        // Continue to Step 7
        step7_GetConfig();
    });
}

// Step 7: Get Gaikai configuration
void PSGaikaiStreaming::step7_GetConfig()
{
    qInfo() << "Gaikai Step 7: Getting configuration...";
    
    QString url = GaikaiConsts::CONFIG_BASE + "/config";
    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    
    QJsonObject body;
    // Set product/platform based on service type
    if (serviceType == "pscloud") {
        body["product"] = "qlite";
        body["platform"] = "qlite";
    } else {
        body["product"] = "psnow";
        body["platform"] = "PC";
    }
    body["sessionId"] = "";
    
    QJsonDocument doc(body);
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        logDebugResponse("Step 7: GetConfig", reply);
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 7 failed:" << reply->errorString();
            emit AllocationError(QString("Config failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject jsonObj = jsonDoc.object();
        
        qDebug() << "Step 7 parsed JSON keys:" << jsonObj.keys();
        
        configKey = jsonObj["configKey"].toString();
        qInfo() << "Gaikai Step 7 complete - Got configKey:" << configKey.left(30) << "...";
        
        // Continue to Step 8
        step8_StartSession("");
    });
}

// Step 8: Start Gaikai session
void PSGaikaiStreaming::step8_StartSession(QString entitlementId)
{
    qInfo() << "Gaikai Step 8: Starting session...";
    
    QUrl url(GaikaiConsts::GAIKAI_BASE + "/sessions/start");
    url.setQuery("npEnv=np");
    
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Gaikai-Session", configKey.toUtf8());
    
    // For initial session start, we don't have auth codes yet
    QJsonObject initialSpec = requestGameSpec;
    initialSpec["gkCloudAuthCode"] = "";
    initialSpec["ps3AuthCode"] = "";
    initialSpec["streamServerAuthCode"] = "";
    
    QJsonObject body;
    body["requestGameSpecification"] = initialSpec;
    
    QJsonDocument doc(body);
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 8 failed:" << reply->errorString();
            QByteArray errorData = reply->readAll();
            qWarning() << "Server response:" << QString::fromUtf8(errorData);
            emit AllocationError(QString("Session start failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        updateSessionKey(reply);
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject jsonObj = jsonDoc.object();
        
        gaikaiSessionId = jsonObj["sessionId"].toString();
        // Client IDs are already set from Step 0, but log them for verification
        
        qInfo() << "Gaikai Step 8 complete:";
        qInfo() << "  sessionId:" << gaikaiSessionId;
        qInfo() << "  gkClientId:" << gkClientId;
        if (!ps3GkClientId.isEmpty()) {
            qInfo() << "  ps3GkClientId:" << ps3GkClientId;
        }
        if (!streamServerClientId.isEmpty()) {
            qInfo() << "  streamServerClientId:" << streamServerClientId;
        }
        
        // Continue to Step 8a
        step8a_GetGkAuthCode();
    });
}

// Step 8a: Get gkClientId authorization code (cloudAuthCode)
void PSGaikaiStreaming::step8a_GetGkAuthCode()
{
    qInfo() << "Gaikai Step 8a: Getting gkClientId auth code (cloudAuthCode)...";
    
    QUrl url(accountBaseUrl + oauthApiPath + "/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("response_type", "code");
    query.addQueryItem("client_id", gkClientId);
    query.addQueryItem("redirect_uri", redirectUriUrl);
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("duid", duid);
    
    if (serviceType == "pscloud") {
        // PSCLOUD (PS5) configuration
        query.addQueryItem("smcid", "qlite");
        query.addQueryItem("applicationId", "qlite");
        query.addQueryItem("mid", "qlite");
        query.addQueryItem("scope", "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s");
    } else {
        // PSNOW (PS3/PS4) configuration
        query.addQueryItem("smcid", "pc:psnow");
        query.addQueryItem("applicationId", "psnow");
        query.addQueryItem("mid", "PSNOW");
        query.addQueryItem("scope", "kamaji:commerce_native versa:user_update_entitlements_first_play kamaji:lists");
        query.addQueryItem("renderMode", "mobilePortrait");
        query.addQueryItem("hidePageElements", "forgotPasswordLink");
        query.addQueryItem("displayFooter", "none");
        query.addQueryItem("disableLinks", "qriocityLink");
        query.addQueryItem("layout_type", "popup");
        query.addQueryItem("service_logo", "ps");
        query.addQueryItem("tp_psn", "true");
        query.addQueryItem("noEVBlock", "true");
    }
    
    url.setQuery(query);
    
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "=== Gaikai Step 8a Response ===";
            qInfo() << "  Status:" << statusCode;
            qInfo() << "  Headers:";
            for (const auto &header : reply->rawHeaderPairs()) {
                qInfo() << "    " << header.first << ":" << header.second;
            }
            QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
            if (!redirectUrl.isEmpty()) {
                qInfo() << "  Redirect URL:" << redirectUrl.toString();
            }
        }
        
        // OAuth redirect should return 302
        if (statusCode != 302) {
            qWarning() << "Gaikai Step 8a failed: Expected 302 redirect, got:" << statusCode;
            QByteArray response = reply->readAll();
            qWarning() << "Response body:" << QString(response);
            emit AllocationError(QString("OAuth request failed with status %1").arg(statusCode));
            emit Finished();
            return;
        }
        
        // Extract auth code from redirect URL (Location header)
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        
        // If redirectUrl is empty, try getting Location header directly
        if (redirectUrl.isEmpty()) {
            QByteArray locationHeader = reply->rawHeader("Location");
            if (!locationHeader.isEmpty()) {
                redirectUrl = QUrl::fromEncoded(locationHeader);
                qInfo() << "Got Location header:" << redirectUrl.toString();
            }
        }
        
        if (!redirectUrl.isEmpty()) {
            gkCloudAuthCode = QUrlQuery(redirectUrl).queryItemValue("code");
        }
        
        if (gkCloudAuthCode.isEmpty()) {
            qWarning() << "Gaikai Step 8a failed: No auth code in redirect";
            qWarning() << "  Status Code:" << statusCode;
            qWarning() << "  Redirect URL:" << redirectUrl.toString();
            emit AllocationError("Failed to get gkClientId auth code - no code parameter in redirect");
            emit Finished();
            return;
        }
        
        qInfo() << "Gaikai Step 8a complete - Got gkCloudAuthCode:" << gkCloudAuthCode.left(20) << "...";
        
        // Continue to Step 8b
        step8b_GetPs3AuthCode();
    });
}

// Step 8b: Get ps3GkClientId/streamServerClientId authorization code (serverAuthCode)
void PSGaikaiStreaming::step8b_GetPs3AuthCode()
{
    qInfo() << "Gaikai Step 8b: Getting server auth code...";
    
    QUrl url(accountBaseUrl + oauthApiPath + "/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("response_type", "code");
    query.addQueryItem("redirect_uri", redirectUriUrl);
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    
    if (serviceType == "pscloud") {
        // PSCLOUD (PS5): Use streamServerClientId
        qInfo() << "  Using streamServerClientId for PSCLOUD";
        query.addQueryItem("client_id", streamServerClientId);
        query.addQueryItem("smcid", "qlite");
        query.addQueryItem("applicationId", "qlite");
        query.addQueryItem("mid", "qlite");
        query.addQueryItem("scope", "id_token:duid id_token:online_id openid oauth:create_authn_ticket_for_cloud_console_signin");
        query.addQueryItem("duid", duid);
    } else {
        // PSNOW (PS3/PS4): Use ps3GkClientId
        qInfo() << "  Using ps3GkClientId for PSNOW";
        query.addQueryItem("client_id", ps3GkClientId);
        query.addQueryItem("smcid", "pc:psnow");
        query.addQueryItem("applicationId", "psnow");
        query.addQueryItem("mid", "PSNOW");
        
        // Platform-specific scope
        if (platform == "ps3") {
            query.addQueryItem("scope", "kamaji:commerce_native");
        } else {
            query.addQueryItem("scope", "sso:none");  // PS4
        }
        
        // Include DUID for PS4, omit for PS3
        if (platform != "ps3") {
            query.addQueryItem("duid", duid);
        }
        
        query.addQueryItem("renderMode", "mobilePortrait");
        query.addQueryItem("hidePageElements", "forgotPasswordLink");
        query.addQueryItem("displayFooter", "none");
        query.addQueryItem("disableLinks", "qriocityLink");
        query.addQueryItem("layout_type", "popup");
        query.addQueryItem("service_logo", "ps");
        query.addQueryItem("tp_psn", "true");
        query.addQueryItem("noEVBlock", "true");
    }
    
    url.setQuery(query);
    
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "=== Gaikai Step 8b Response ===";
            qInfo() << "  Status:" << statusCode;
            qInfo() << "  Headers:";
            for (const auto &header : reply->rawHeaderPairs()) {
                qInfo() << "    " << header.first << ":" << header.second;
            }
            QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
            if (!redirectUrl.isEmpty()) {
                qInfo() << "  Redirect URL:" << redirectUrl.toString();
            }
        }
        
        // OAuth redirect should return 302
        if (statusCode != 302) {
            qWarning() << "Gaikai Step 8b failed: Expected 302 redirect, got:" << statusCode;
            QByteArray response = reply->readAll();
            qWarning() << "Response body:" << QString(response);
            emit AllocationError(QString("OAuth request failed with status %1").arg(statusCode));
            emit Finished();
            return;
        }
        
        // Extract auth code from redirect URL (Location header)
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        
        // If redirectUrl is empty, try getting Location header directly
        if (redirectUrl.isEmpty()) {
            QByteArray locationHeader = reply->rawHeader("Location");
            if (!locationHeader.isEmpty()) {
                redirectUrl = QUrl::fromEncoded(locationHeader);
                qInfo() << "Got Location header:" << redirectUrl.toString();
            }
        }
        
        QString serverAuthCode;
        if (!redirectUrl.isEmpty()) {
            serverAuthCode = QUrlQuery(redirectUrl).queryItemValue("code");
        }
        
        if (serverAuthCode.isEmpty()) {
            qWarning() << "Gaikai Step 8b failed: No auth code in redirect";
            qWarning() << "  Status Code:" << statusCode;
            qWarning() << "  Redirect URL:" << redirectUrl.toString();
            emit AllocationError("Failed to get server auth code - no code parameter in redirect");
            emit Finished();
            return;
        }
        
        // Set auth codes based on service type
        if (serviceType == "pscloud") {
            // PSCLOUD: Use serverAuthCode for streamServer, leave ps3AuthCode empty
            streamServerAuthCode = serverAuthCode;
            ps3AuthCode = "";
            qInfo() << "Gaikai Step 8b complete - Got streamServerAuthCode:" << streamServerAuthCode.left(20) << "...";
        } else {
            // PSNOW: Both ps3AuthCode AND streamServerAuthCode use the same code
            ps3AuthCode = serverAuthCode;
            streamServerAuthCode = serverAuthCode;
            qInfo() << "Gaikai Step 8b complete - Got ps3AuthCode (used for both):" << ps3AuthCode.left(20) << "...";
        }
        
        // Update requestGameSpec with auth codes
        requestGameSpec["gkCloudAuthCode"] = gkCloudAuthCode;
        requestGameSpec["ps3AuthCode"] = ps3AuthCode;
        requestGameSpec["streamServerAuthCode"] = streamServerAuthCode;
        
        // Continue to Step 9
        step9_AuthorizeSession();
    });
}

// Step 9: Authorize Gaikai session
void PSGaikaiStreaming::step9_AuthorizeSession()
{
    qInfo() << "Gaikai Step 9: Authorizing session...";
    
    QString urlStr = GaikaiConsts::GAIKAI_BASE + "/sessions/" + gaikaiSessionId + "/authorize";
    
    QNetworkRequest req{QUrl(urlStr)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Gaikai-SessionId", gaikaiSessionId.toUtf8());
    req.setRawHeader("X-Gaikai-Session", configKey.toUtf8());
    
    QJsonObject body;
    body["requestGameSpecification"] = requestGameSpec;
    
    QJsonDocument doc(body);
    QByteArray requestBody = doc.toJson();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== Gaikai Step 9 Request ===";
        qInfo() << "  URL:" << urlStr;
        qInfo() << "  X-Gaikai-SessionId:" << gaikaiSessionId;
        qInfo() << "  X-Gaikai-Session:" << configKey.left(30) << "...";
        qInfo() << "  Body:" << QString::fromUtf8(requestBody);
    }
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QByteArray responseBody = reply->readAll();
        
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "=== Gaikai Step 9 Response ===";
            qInfo() << "  Status:" << statusCode;
            qInfo() << "  Headers:";
            for (const auto &header : reply->rawHeaderPairs()) {
                qInfo() << "    " << header.first << ":" << header.second;
            }
            if (!responseBody.isEmpty()) {
                qInfo() << "  Body:" << QString::fromUtf8(responseBody);
            }
        }
        
        // Check for HTTP errors (401, 400, etc.)
        if (statusCode != 200) {
            QString errorMsg = QString("Authorize failed with status %1").arg(statusCode);
            
            // Parse JSON error response for detailed error messages
            if (!responseBody.isEmpty()) {
                QJsonParseError parseError;
                QJsonDocument errorDoc = QJsonDocument::fromJson(responseBody, &parseError);
                if (parseError.error == QJsonParseError::NoError && errorDoc.isObject()) {
                    QJsonObject errorObj = errorDoc.object();
                    
                    // Extract errors array
                    if (errorObj.contains("errors") && errorObj["errors"].isArray()) {
                        QJsonArray errorsArray = errorObj["errors"].toArray();
                        QStringList errorDescriptions;
                        for (const QJsonValue &errorValue : errorsArray) {
                            if (errorValue.isObject()) {
                                QJsonObject error = errorValue.toObject();
                                if (error.contains("description")) {
                                    errorDescriptions << error["description"].toString();
                                } else if (error.contains("eventCode")) {
                                    errorDescriptions << QString("Event: %1").arg(error["eventCode"].toString());
                                }
                            }
                        }
                        if (!errorDescriptions.isEmpty()) {
                            errorMsg += "\n" + errorDescriptions.join("\n");
                        }
                    } else if (errorObj.contains("description")) {
                        errorMsg += ": " + errorObj["description"].toString();
                    } else {
                        // Fallback to raw body if we can't parse
                        errorMsg += ": " + QString::fromUtf8(responseBody);
                    }
                } else {
                    // Not JSON, use raw body
                    errorMsg += ": " + QString::fromUtf8(responseBody);
                }
            }
            
            // Check for x-gaikai-event header for additional context
            QByteArray eventHeader = reply->rawHeader("x-gaikai-event");
            if (!eventHeader.isEmpty()) {
                qWarning() << "Gaikai event:" << QString::fromUtf8(eventHeader);
            }
            
            qWarning() << "Gaikai Step 9 failed:" << errorMsg;
            emit AllocationError(errorMsg);
            emit Finished();
            return;
        }
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 9 failed:" << reply->errorString();
            if (!responseBody.isEmpty()) {
                qWarning() << "Response body:" << QString::fromUtf8(responseBody);
            }
            emit AllocationError(QString("Authorize failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        updateSessionKey(reply);
        
        qInfo() << "Gaikai Step 9 complete - Session authorized";
        
        // Continue to Step 10
        step10_LockSession();
    });
}

// Step 10: Lock session
void PSGaikaiStreaming::step10_LockSession()
{
    qInfo() << "Gaikai Step 10: Locking session...";
    
    QString urlStr = GaikaiConsts::GAIKAI_BASE + "/sessions/" + gaikaiSessionId + "/lock?forceLogout=false";
    
    QNetworkRequest req{QUrl(urlStr)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Gaikai-SessionId", gaikaiSessionId.toUtf8());
    req.setRawHeader("X-Gaikai-Session", configKey.toUtf8());
    
    QJsonObject body;
    body["requestGameSpecification"] = requestGameSpec;
    
    QJsonDocument doc(body);
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 10 failed:" << reply->errorString();
            emit AllocationError(QString("Lock failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        updateSessionKey(reply);
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject jsonObj = jsonDoc.object();
        
        bool lockAcquired = jsonObj["lockAcquired"].toBool();
        qInfo() << "Gaikai Step 10 complete - Lock acquired:" << lockAcquired;
        
        // Continue to Step 11
        step11_GetDatacenters();
    });
}

// Step 11: Get available datacenters
void PSGaikaiStreaming::step11_GetDatacenters()
{
    qInfo() << "Gaikai Step 11: Getting available datacenters...";
    
    QString urlStr = GaikaiConsts::GAIKAI_BASE + "/sessions/" + gaikaiSessionId + "/datacenters";
    
    QNetworkRequest req{QUrl(urlStr)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Gaikai-SessionId", gaikaiSessionId.toUtf8());
    req.setRawHeader("X-Gaikai-Session", configKey.toUtf8());
    
    QJsonObject body;
    body["requestGameSpecification"] = requestGameSpec;
    
    QJsonDocument doc(body);
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 11 failed:" << reply->errorString();
            emit AllocationError(QString("Get datacenters failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        updateSessionKey(reply);
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonArray datacenters = jsonDoc.array();
        
        qInfo() << "Gaikai Step 11 complete - Available datacenters:" << datacenters.size();
        for (const QJsonValue &dc : datacenters) {
            QJsonObject dcObj = dc.toObject();
            qInfo() << "  -" << dcObj["dataCenter"].toString() 
                    << dcObj["publicIp"].toString() << ":" << dcObj["port"].toInt()
                    << "maxBw:" << dcObj["maxBandwidth"].toInt();
        }
        
        // For now, auto-select first datacenter
        // In production, you'd ping all and choose lowest latency
        if (datacenters.isEmpty()) {
            qWarning() << "Gaikai Step 11: No datacenters available";
            emit AllocationError("No datacenters available");
            emit Finished();
            return;
        }
        
        QJsonObject firstDc = datacenters[0].toObject();
        selectedDatacenter = firstDc["dataCenter"].toString();
        
        // Extract port from datacenter response (dynamic, not hardcoded)
        int dcPort = firstDc["port"].toInt();
        if (dcPort <= 0) {
            qWarning() << "Gaikai Step 11: Invalid port in datacenter response, defaulting to 2053";
            dcPort = 2053;
        }
        qInfo() << "  Selected datacenter:" << selectedDatacenter << "Port:" << dcPort;
        
        // Build fake ping results (for testing)
        QJsonArray pingResults;
        QJsonObject pingResult;
        pingResult["dataCenter"] = selectedDatacenter;
        pingResult["rtt"] = 25;
        QJsonArray rtts;
        for (int i = 0; i < 10; i++) rtts.append(25 + (i % 5));
        pingResult["rtts"] = rtts;
        pingResult["port"] = dcPort;  // Use extracted port
        pingResults.append(pingResult);
        
        // Continue to Step 12
        step12_SelectDatacenter(pingResults);
    });
}

// Step 12: Select datacenter
void PSGaikaiStreaming::step12_SelectDatacenter(QJsonArray pingResults)
{
    qInfo() << "Gaikai Step 12: Selecting datacenter:" << selectedDatacenter;
    
    QString urlStr = GaikaiConsts::GAIKAI_BASE + "/sessions/" + gaikaiSessionId + "/datacenters/select";
    
    QNetworkRequest req{QUrl(urlStr)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Gaikai-SessionId", gaikaiSessionId.toUtf8());
    req.setRawHeader("X-Gaikai-Session", configKey.toUtf8());
    
    QJsonObject body;
    body["requestGameSpecification"] = requestGameSpec;
    body["pingResults"] = pingResults;
    
    QJsonDocument doc(body);
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 12 failed:" << reply->errorString();
            emit AllocationError(QString("Select datacenter failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        updateSessionKey(reply);
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject selected = jsonDoc.object();
        
        // Extract port from selected datacenter response (dynamic, not hardcoded)
        selectedDatacenterPort = selected["port"].toInt();
        if (selectedDatacenterPort <= 0) {
            qWarning() << "Gaikai Step 12: Invalid port in response, defaulting to 2053";
            selectedDatacenterPort = 2053;
        }
        
        qInfo() << "Gaikai Step 12 complete - Selected:" << selected["dataCenter"].toString()
                << selected["publicIp"].toString() << ":" << selectedDatacenterPort;
        
        // Continue to Step 13 (port will be used in network object and also extracted from allocate response)
        step13_AllocateSlot();
    });
}

// Step 13: Allocate streaming slot
void PSGaikaiStreaming::step13_AllocateSlot()
{
    qInfo() << "Gaikai Step 13: Allocating streaming slot...";
    
    QString urlStr = GaikaiConsts::GAIKAI_BASE + "/sessions/" + gaikaiSessionId + "/allocate";
    
    QNetworkRequest req{QUrl(urlStr)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "*/*");
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("X-Gaikai-SessionId", gaikaiSessionId.toUtf8());
    req.setRawHeader("X-Gaikai-Session", configKey.toUtf8());
    
    QJsonObject body;
    body["requestGameSpecification"] = requestGameSpec;
    body["dataCenter"] = selectedDatacenter;
    
    // Network info (use port from step12 response, not hardcoded)
    QJsonObject network;
    network["bwKbpsSent"] = 22794;
    network["bwLoss"] = 0.056522;
    network["mtu"] = 1454;
    network["rtt"] = 25;
    network["port"] = selectedDatacenterPort;  // Use port from step12 (dynamic)
    network["bwKbpsReceived"] = 4678;
    network["bwLossUpstream"] = 0;
    network["mtuUpstream"] = 1254;
    body["network"] = network;
    
    body["stateExecutionTime"] = 5974.7632;
    body["streamTestTime"] = 11262.8423;
    
    QJsonDocument doc(body);
    
    // Log the full allocate request JSON for inspection
    qInfo() << "=== Step 13: Allocate Request - Full JSON ===";
    qInfo() << "URL:" << urlStr;
    qInfo() << "Body:";
    qInfo() << doc.toJson(QJsonDocument::Indented);
    qInfo() << "=============================================";
    
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 13 failed:" << reply->errorString();
            QByteArray errorData = reply->readAll();
            qWarning() << "Server response:" << QString::fromUtf8(errorData);
            emit AllocationError(QString("Allocate failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject allocation = jsonDoc.object();
        
        // Log the full allocation response for inspection
        qInfo() << "=== Step 13: Allocate Response - Full JSON ===";
        qInfo() << jsonDoc.toJson(QJsonDocument::Indented);
        qInfo() << "==============================================";
        
        // Extract critical connection info
        QJsonObject launchSlot = allocation["launchSlot"].toObject();
        allocatedServerIp = launchSlot["publicIp"].toString();
        allocatedServerPort = launchSlot["port"].toInt();
        QString privateIp = launchSlot["privateIp"].toString();
        allocatedHandshakeKey = allocation["handshakeKey"].toString();
        allocatedLaunchSpec = allocation["launchSpecification"].toString();
        allocatedSessionId = allocation["sessionId"].toString();
        
        // Extract PSN wrapper type from private IP's last octet
        allocatedPsnWrapperType = 0x01; // default fallback
        if (!privateIp.isEmpty()) {
            int lastDotPos = privateIp.lastIndexOf('.');
            if (lastDotPos != -1) {
                QString lastOctet = privateIp.mid(lastDotPos + 1);
                bool ok;
                int octetValue = lastOctet.toInt(&ok);
                if (ok && octetValue >= 0 && octetValue <= 255) {
                    allocatedPsnWrapperType = static_cast<uint8_t>(octetValue);
                    qInfo() << "Private IP:" << privateIp << "-> PSN wrapper type:" << QString("0x%1").arg(allocatedPsnWrapperType, 2, 16, QChar('0'));
                }
            }
        }
        
        qInfo() << "=== Gaikai Step 13: ALLOCATION SUCCESSFUL ===";
        qInfo() << "Server IP:" << allocatedServerIp;
        qInfo() << "Server Port:" << allocatedServerPort;
        qInfo() << "Handshake Key:" << allocatedHandshakeKey;
        qInfo() << "Session ID:" << allocatedSessionId;
        qInfo() << "Launch Spec (FULL):" << allocatedLaunchSpec;
        qInfo() << "Launch Spec Length:" << allocatedLaunchSpec.length();
        qInfo() << "[Allocation results stored in class for Takion connection]";
        
        // Extract additional info
        bool queued = allocation["queued"].toBool();
        int timeLimit = allocation["timeLimit"].toInt();
        int startGameTimeout = allocation["startGameTimeout"].toInt();
        
        qInfo() << "Stream Queued:" << (queued ? "Yes" : "No");
        qInfo() << "Time Limit:" << timeLimit << "minutes";
        qInfo() << "Start Timeout:" << startGameTimeout << "seconds";
        
        if (finalCallback.isCallable()) {
            finalCallback.call({true, QString("Streaming slot allocated: %1:%2").arg(allocatedServerIp).arg(allocatedServerPort), allocatedServerIp});
        }
        
        emit AllocationComplete(allocatedServerIp, allocatedServerPort, allocatedHandshakeKey, allocatedLaunchSpec, allocatedSessionId);
        emit Finished();
    });
}

