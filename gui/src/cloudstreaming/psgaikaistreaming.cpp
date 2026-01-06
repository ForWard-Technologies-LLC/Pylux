// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/psgaikaistreaming.h"
#include "cloudstreaming/pskamajisession.h"
#include "cloudstreaming/datacenterping.h"
#include "chiaki/remote/holepunch.h"
#include "chiaki/common.h"

#include <QObject>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QUrlQuery>
#include <QTimer>
#include <QElapsedTimer>
#include <QSharedPointer>
#include <QTcpSocket>
#include <QHostAddress>
#include <QHash>
#include <functional>
#include <algorithm>
#include <vector>
#include <QTimeZone>
#include <QDateTime>

PSGaikaiStreaming::PSGaikaiStreaming(Settings *settings, QString deviceUid,
                                   QString serviceTypeParam, QString platformParam,
                                   QObject *parent)
    : QObject(parent)
    , settings(settings)
    , duid(deviceUid)
    , serviceType(serviceTypeParam.toLower())
    , platform(platformParam.toLower())
{
    // Determine virtType from platform
    if (platform == "ps3") {
        virtType = "konan";
    } else if (platform == "ps4") {
        virtType = "kratos";
    } else if (platform == "ps5") {
        virtType = "cronos";
    }
    
    // Set service-specific constants based on serviceType
    accountBaseUrl = "https://ca.account.sony.com";
    if (serviceType == "pscloud") {
        redirectUriUrl = GaikaiConsts::REDIRECT_URI;
        userAgentString = GaikaiConsts::USER_AGENT;
        oauthApiPath = "/api/authz/v3";
    } else {
        // PSNOW
        redirectUriUrl = KamajiConsts::REDIRECT_URI;
        userAgentString = KamajiConsts::USER_AGENT;
        oauthApiPath = "/api/v1";
    }
    
    manager = new QNetworkAccessManager(this);
    manager->setCookieJar(nullptr);  // Disable cookie jar - we use manual Cookie headers only
    
    // Initialize port to 0 (will be set from step12 response)
    selectedDatacenterPort = 0;
    
    // Initialize allocation wait state
    allocationMaxWaitSeconds = DEFAULT_ALLOCATION_WAIT_SECONDS;
    
    // Initialize retry counters
    lockSessionRetryCount = 0;
    allocationRetryCount = 0;
}

// Helper function to merge new ping results with existing datacenters in settings
// Updates existing datacenters with new ping data, adds new ones, and keeps old ones that aren't in new results
QJsonArray PSGaikaiStreaming::mergeDatacentersWithExisting(const QJsonArray &newPingResults)
{
    // Load existing datacenters from settings
    QString existingJson;
    if (serviceType == "pscloud") {
        existingJson = settings->GetCloudDatacentersJsonPSCloud();
    } else {
        existingJson = settings->GetCloudDatacentersJsonPSNOW();
    }
    
    // Parse existing datacenters
    QJsonArray existingDatacenters;
    if (!existingJson.isEmpty()) {
        QJsonParseError parseError;
        QJsonDocument existingDoc = QJsonDocument::fromJson(existingJson.toUtf8(), &parseError);
        if (parseError.error == QJsonParseError::NoError && existingDoc.isArray()) {
            existingDatacenters = existingDoc.array();
        }
    }
    
    // Create a map of existing datacenters by name
    QHash<QString, QJsonObject> existingMap;
    for (const QJsonValue &val : existingDatacenters) {
        QJsonObject dc = val.toObject();
        QString name = dc["dataCenter"].toString();
        if (!name.isEmpty()) {
            existingMap[name] = dc;
        }
    }
    
    // Update existing entries with new ping results, or add new ones
    for (const QJsonValue &val : newPingResults) {
        QJsonObject newResult = val.toObject();
        QString name = newResult["dataCenter"].toString();
        if (!name.isEmpty()) {
            // Update existing entry or add new one
            existingMap[name] = newResult;
        }
    }
    
    // Convert merged map back to array
    QJsonArray mergedResults;
    for (auto it = existingMap.begin(); it != existingMap.end(); ++it) {
        mergedResults.append(it.value());
    }
    
    return mergedResults;
}

QJsonObject PSGaikaiStreaming::buildRequestGameSpec(QString entitlementId)
{
    QJsonObject spec;
    
    // Get system timezone automatically
    QTimeZone systemTz = QTimeZone::systemTimeZone();
    QDateTime now = QDateTime::currentDateTime();
    int offsetSeconds = systemTz.offsetFromUtc(now);
    
    // Format as "UTC+HH:MM" or "UTC-HH:MM"
    int offsetHours = offsetSeconds / 3600;
    int offsetMinutes = qAbs((offsetSeconds % 3600) / 60);
    QString timezoneStr;
    if (offsetHours >= 0) {
        timezoneStr = QString("UTC+%1:%2").arg(offsetHours, 2, 10, QChar('0')).arg(offsetMinutes, 2, 10, QChar('0'));
    } else {
        timezoneStr = QString("UTC-%1:%2").arg(qAbs(offsetHours), 2, 10, QChar('0')).arg(offsetMinutes, 2, 10, QChar('0'));
    }
    
    // ============================================================================
    // COMMON FIELDS (apply to both PSCLOUD and PSNOW)
    // ============================================================================
    
    // Core Game Configuration
    spec["entitlementId"] = entitlementId;
    spec["npEnv"] = "np";
    
    // Read resolution and language from settings fresh each time (not cached)
    // Use unified language setting for both PSCloud and PSNOW
    QString language = settings->GetCloudLanguagePSCloud();
    int resolution;
    if (serviceType == "pscloud") {
        resolution = settings->GetCloudResolutionPSCloud();
    } else {
        // PSNOW
        resolution = settings->GetCloudResolutionPSNOW();
    }
    spec["language"] = language;
    
    // Cloud Infrastructure
    spec["cloudEndpoint"] = "https://cc.prod.gaikai.com";
    spec["redirectUri"] = redirectUriUrl;
    
    // Video Resolution (common calculation)
    QString resolutionSetting;
    int clientWidth, clientHeight;
    if (resolution == 720) {
        resolutionSetting = "720";
        clientWidth = 1280;
        clientHeight = 720;
    } else if (resolution == 1440) {
        resolutionSetting = "1440";
        clientWidth = 2560;
        clientHeight = 1440;
    } else if (resolution == 2160) {
        resolutionSetting = "2160";
        clientWidth = 3840;
        clientHeight = 2160;
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
    spec["useClientBwLadder"] = true;
    
    // Audio Upload (common)
    spec["audioUploadEnabled"] = true;
    spec["audioUploadNumChannels"] = 1;
    spec["audioUploadSamplingFrequency"] = 48000;
    
    // Input Configuration (common)
    spec["acceptButton"] = "X";
    
    // Protocol (common)
    spec["encryptionSupported"] = true;
    
    // Timezone (common) - automatically detected from system
    spec["summerTime"] = 0;
    spec["timeZone"] = timezoneStr;
    
    // HTTP User Agent (common)
    spec["httpUserAgent"] = userAgentString;
    
    // Auth Codes (common - will be updated later in step 9)
    spec["gkCloudAuthCode"] = gkCloudAuthCode;
    
    // Accessibility Features (common - all disabled)
    spec["accessibilityMarqueeSpeed"] = 0;
    spec["accessibilityLargeText"] = 0;
    spec["accessibilityBoldText"] = 0;
    spec["accessibilityContrast"] = 0;
    spec["accessibilityTtsEnable"] = 0;
    spec["accessibilityTtsSpeed"] = 0;
    spec["accessibilityTtsVolume"] = 0;
    
    // Capability Flags (common)
    spec["partyCapability"] = false;
    spec["homesharing"] = false;
    spec["isFirstBoot"] = false;
    spec["isPlusMember"] = true;
    spec["parentalLevel"] = 0;
    spec["yuvCoefficient"] = "";
    
    // Common Capabilities
    QJsonArray capabilitiesArray;
    capabilitiesArray.append("cloudDrivenSenkushaTest");
    
    // ============================================================================
    // PSCLOUD (PS5) SPECIFIC FIELDS
    // ============================================================================
    if (serviceType == "pscloud") {
        // Video Configuration
        spec["videoEncoderProfile"] = "hw5.0";
        
        // Input Configuration
        QJsonArray controllersArray;
        controllersArray.append("ds4");
        controllersArray.append("ds5");
        controllersArray.append("xinput");
        spec["connectedControllers"] = controllersArray;
        QJsonObject inputObj;
        inputObj["controllers"] = controllersArray;
        spec["input"] = inputObj;
        
        // Device/Platform Info
        spec["model"] = "portal";
        spec["platform"] = "qlite";
        
        // Protocol Settings
        spec["gaikaiPlayer"] = "16.4.0";
        spec["protocolVersion"] = 12;
        
        // Auth Codes
        spec["ps3AuthCode"] = "";
        spec["streamServerAuthCode"] = streamServerAuthCode;
        
        // Capabilities
        capabilitiesArray.append("cronos");
        
        // Video Stream Settings (PSCLOUD only)
        QJsonObject videoStreamSettings;
        videoStreamSettings["clientHeight"] = clientHeight;
        videoStreamSettings["supportedMaxResolution"] = clientHeight;
        QJsonArray videoProfiles;
        videoProfiles.append("hevc_hw4");
        videoStreamSettings["supportedVideoEncoderProfiles"] = videoProfiles;
        videoStreamSettings["supportedDynamicRange"] = "sdr";
        videoStreamSettings["preferredMaxResolution"] = clientHeight;
        videoStreamSettings["preferredDynamicRange"] = "sdr";
        videoStreamSettings["hqMode"] = 1;
        spec["videoStreamSettings"] = videoStreamSettings;
        
        // Audio Stream Settings (PSCLOUD only)
        spec["audioChannels"] = "2";
        // Note: audioEncoderProfile is set inside audioStreamSettings for PSCLOUD
        spec["audioEncoderProfile"] = "default";
        QJsonObject audioStreamSettings;
        audioStreamSettings["audioEncoderProfile"] = "default";
        audioStreamSettings["maxAudioChannels"] = "2";
        audioStreamSettings["preferredNumberAudioChannels"] = "2";

        // not sure if these should be here or at root level. Either way, not supporting for now
        // audioStreamSettings["enable3D"] = true;
        // audioStreamSettings["force3DMode"] = true;
        // audioStreamSettings["HRTF"] = true;

        spec["audioStreamSettings"] = audioStreamSettings;
    }
    
    // ============================================================================
    // PSNOW (PS3/PS4) SPECIFIC FIELDS
    // ============================================================================
    else {
        // Audio Configuration
        spec["audioChannels"] = "2.1";
        spec["audioEncoderProfile"] = "default";
        
        // Video Configuration
        spec["videoEncoderProfile"] = "hw4.1";
        
        // Input Configuration
        QJsonArray controllersArray = QJsonArray::fromStringList({"xinput"});
        spec["connectedControllers"] = controllersArray;
        QJsonObject inputObj;
        inputObj["controllers"] = controllersArray;
        spec["input"] = inputObj;
        
        // Device/Platform Info
        spec["model"] = "WINDOWS";
        spec["platform"] = "PC";
        
        // Protocol Settings
        spec["gaikaiPlayer"] = "12.5.0";
        spec["protocolVersion"] = 9;
        
        // Auth Codes
        spec["ps3AuthCode"] = ps3AuthCode;
        spec["streamServerAuthCode"] = ps3AuthCode;
        
        // Capabilities
        capabilitiesArray.append("kratos");
    }
    
    // Set capabilities (common, but content differs by service)
    spec["capabilities"] = capabilitiesArray;
    
    // Log the full JSON for inspection
    qInfo() << "=== buildRequestGameSpec - Full JSON ===";
    qInfo() << "Service:" << serviceType << "Platform:" << platform;
    QByteArray formattedJson = QJsonDocument(spec).toJson(QJsonDocument::Indented);
    QString jsonString = QString::fromUtf8(formattedJson);
    // Output each line separately so it's properly formatted in logs
    QStringList lines = jsonString.split('\n', Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        if (!line.trimmed().isEmpty()) {
            qInfo().noquote() << line;
        }
    }
    qInfo() << "========================================";
    
    return spec;
}

void PSGaikaiStreaming::updateSessionKey(QNetworkReply *reply)
{
    QString newKey = QString::fromUtf8(reply->rawHeader("x-gaikai-session"));
    if (!newKey.isEmpty()) {
        configKey = newKey;
        qInfo() << "Gaikai: Updated session key (length:" << configKey.length() << "):" << configKey;
    }
}

void PSGaikaiStreaming::logDebugRequest(const QString &stepName, const QNetworkRequest &request, const QByteArray &body)
{
    qInfo() << "=== Gaikai" << stepName << "Request ===";
    qInfo() << "URL:" << request.url().toString();
    qInfo() << "Method:" << (body.isEmpty() ? "GET" : "POST");
    qInfo() << "Request Headers:";
    
    // QNetworkRequest doesn't have rawHeaderPairs(), so we need to check for headers individually
    // Log common headers we set
    QByteArray userAgent = request.rawHeader("User-Agent");
    if (!userAgent.isEmpty()) {
        qInfo() << "  User-Agent:" << QString::fromUtf8(userAgent);
    }
    QByteArray accept = request.rawHeader("Accept");
    if (!accept.isEmpty()) {
        qInfo() << "  Accept:" << QString::fromUtf8(accept);
    }
    QByteArray contentType = request.rawHeader("Content-Type");
    if (!contentType.isEmpty()) {
        qInfo() << "  Content-Type:" << QString::fromUtf8(contentType);
    }
    QByteArray xGaikaiSession = request.rawHeader("X-Gaikai-Session");
    if (!xGaikaiSession.isEmpty()) {
        qInfo() << "  X-Gaikai-Session:" << QString::fromUtf8(xGaikaiSession).left(30) << "...";
    }
    QByteArray xGaikaiSessionId = request.rawHeader("X-Gaikai-SessionId");
    if (!xGaikaiSessionId.isEmpty()) {
        qInfo() << "  X-Gaikai-SessionId:" << QString::fromUtf8(xGaikaiSessionId);
    }
    // Log all headers using rawHeaderList (available in Qt 5.15+)
    QList<QByteArray> headerNames = request.rawHeaderList();
    for (const QByteArray &headerName : headerNames) {
        // Skip headers we already logged above
        QString headerNameStr = QString::fromUtf8(headerName);
        if (headerNameStr.compare("User-Agent", Qt::CaseInsensitive) != 0 &&
            headerNameStr.compare("Accept", Qt::CaseInsensitive) != 0 &&
            headerNameStr.compare("Content-Type", Qt::CaseInsensitive) != 0 &&
            headerNameStr.compare("X-Gaikai-Session", Qt::CaseInsensitive) != 0 &&
            headerNameStr.compare("X-Gaikai-SessionId", Qt::CaseInsensitive) != 0) {
            QByteArray headerValue = request.rawHeader(headerName);
            qInfo() << "  " << headerNameStr << ":" << QString::fromUtf8(headerValue);
        }
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
    // Get npsso fresh from settings at the start of each allocation attempt
    npsso = settings->GetNpssoToken();
    
    qInfo() << "Gaikai Allocation: Starting complete flow";
    qInfo() << "  Service Type:" << serviceType;
    qInfo() << "  Platform:" << platform;
    qInfo() << "  virtType:" << virtType;
    qInfo() << "  Entitlement ID:" << entitlementId;
    
    if (npsso.isEmpty()) {
        QString error = "NPSSO token is empty";
        qWarning() << "Gaikai Allocation:" << error;
        emit AllocationError(error);
        return;
    }
    
    finalCallback = callback;
    
    // Reset session keys for new allocation
    configKey.clear();
    lockSessionKey.clear();
    
    // Store entitlement for later use (will be updated with auth codes in step 8)
    requestGameSpec = buildRequestGameSpec(entitlementId);
    
    // Start with Step 0: Get Client IDs (MUST happen FIRST)
    step0_GetClientIds();
}

// Step 0: Get Client IDs (MUST happen FIRST before step7)
void PSGaikaiStreaming::step0_GetClientIds()
{
    emit AllocationProgress("Getting Client IDs - Step 1 of 10");
    qInfo() << "Gaikai Step 0: Getting client IDs for virtType:" << virtType;
    
    QString url = QString("%1/client_ids?virtType=%2").arg(GaikaiConsts::GAIKAI_BASE, virtType);
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("User-Agent", userAgentString.toUtf8());
    req.setRawHeader("Accept", "*/*");
    
    logDebugRequest("Step 0: GetClientIds", req);
    
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
    emit AllocationProgress("Getting Configuration - Step 2 of 10");
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
    QByteArray requestBody = doc.toJson();
    logDebugRequest("Step 7: GetConfig", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
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
    emit AllocationProgress("Starting Session - Step 3 of 10");
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
    QByteArray requestBody = doc.toJson();
    logDebugRequest("Step 8: StartSession", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
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
    emit AllocationProgress("Getting Tokens - Step 4 of 10");
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
    
    // Add npsso cookie for OAuth authorization
    if (!npsso.isEmpty()) {
        req.setRawHeader("Cookie", QString("npsso=%1").arg(npsso).toUtf8());
    }
    
    logDebugRequest("Step 8a: GetGkAuthCode", req);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QByteArray responseBody = reply->readAll();
        
        // Always log status code
        if (statusCode > 0) {
            qInfo() << "Gaikai Step 8a: HTTP" << statusCode;
        } else if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 8a: Network error:" << reply->errorString();
            emit AllocationError(QString("OAuth authorization failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        // Fail on HTTP errors
        if (statusCode >= 400) {
            qWarning() << "Gaikai Step 8a failed: HTTP" << statusCode;
            if (!responseBody.isEmpty()) {
                qWarning() << "Response:" << QString::fromUtf8(responseBody);
            }
            emit AllocationError(QString("OAuth authorization failed: HTTP %1").arg(statusCode));
            emit Finished();
            return;
        }
        
        // Must be 302 redirect
        if (statusCode != 302) {
            qWarning() << "Gaikai Step 8a failed: Expected 302, got HTTP" << statusCode;
            emit AllocationError(QString("OAuth authorization failed: Expected redirect, got HTTP %1").arg(statusCode));
            emit Finished();
            return;
        }
        
        // Extract auth code from redirect
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        if (redirectUrl.isEmpty()) {
            QByteArray locationHeader = reply->rawHeader("Location");
            if (!locationHeader.isEmpty()) {
                redirectUrl = QUrl::fromEncoded(locationHeader);
            }
        }
        
        gkCloudAuthCode = redirectUrl.isEmpty() ? QString() : QUrlQuery(redirectUrl).queryItemValue("code");
        
        if (gkCloudAuthCode.isEmpty()) {
            qWarning() << "Gaikai Step 8a failed: No auth code in redirect URL";
            emit AllocationError("OAuth authorization failed: No authorization code received");
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
    emit AllocationProgress("Getting Server Tokens - Step 5 of 10");
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
    
    // Add npsso cookie for OAuth authorization
    if (!npsso.isEmpty()) {
        req.setRawHeader("Cookie", QString("npsso=%1").arg(npsso).toUtf8());
    }
    
    logDebugRequest("Step 8b: GetPs3AuthCode", req);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QByteArray responseBody = reply->readAll();
        
        // Always log status code
        if (statusCode > 0) {
            qInfo() << "Gaikai Step 8b: HTTP" << statusCode;
        } else if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 8b: Network error:" << reply->errorString();
            emit AllocationError(QString("OAuth authorization failed: %1").arg(reply->errorString()));
            emit Finished();
            return;
        }
        
        // Fail on HTTP errors
        if (statusCode >= 400) {
            qWarning() << "Gaikai Step 8b failed: HTTP" << statusCode;
            if (!responseBody.isEmpty()) {
                qWarning() << "Response:" << QString::fromUtf8(responseBody);
            }
            emit AllocationError(QString("OAuth authorization failed: HTTP %1").arg(statusCode));
            emit Finished();
            return;
        }
        
        // Must be 302 redirect
        if (statusCode != 302) {
            qWarning() << "Gaikai Step 8b failed: Expected 302, got HTTP" << statusCode;
            emit AllocationError(QString("OAuth authorization failed: Expected redirect, got HTTP %1").arg(statusCode));
            emit Finished();
            return;
        }
        
        // Extract auth code from redirect
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        if (redirectUrl.isEmpty()) {
            QByteArray locationHeader = reply->rawHeader("Location");
            if (!locationHeader.isEmpty()) {
                redirectUrl = QUrl::fromEncoded(locationHeader);
            }
        }
        
        QString serverAuthCode = redirectUrl.isEmpty() ? QString() : QUrlQuery(redirectUrl).queryItemValue("code");
        
        if (serverAuthCode.isEmpty()) {
            qWarning() << "Gaikai Step 8b failed: No auth code in redirect URL";
            emit AllocationError("OAuth authorization failed: No authorization code received");
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
    emit AllocationProgress("Authorizing Session - Step 6 of 10");
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
    
    logDebugRequest("Step 9: AuthorizeSession", req, requestBody);
    
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
            
            // Check for PS Plus subscription error via event header
            QByteArray eventHeader = reply->rawHeader("x-gaikai-event");
            bool isPSPlusError = false;
            if (!eventHeader.isEmpty()) {
                qWarning() << "Gaikai event:" << QString::fromUtf8(eventHeader);
                // Parse event header JSON to check event code
                QJsonParseError parseError;
                QJsonDocument eventDoc = QJsonDocument::fromJson(eventHeader, &parseError);
                if (parseError.error == QJsonParseError::NoError && eventDoc.isObject()) {
                    QJsonObject eventObj = eventDoc.object();
                    QString eventCode = eventObj["eventCode"].toString();
                    if (eventCode == "002.2001") {
                        isPSPlusError = true;
                    }
                }
            }
            
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
                                    QString eventCode = error["eventCode"].toString();
                                    if (eventCode == "002.2001") {
                                        isPSPlusError = true;
                                    }
                                    errorDescriptions << QString("Event: %1").arg(eventCode);
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
            
            qWarning() << "Gaikai Step 9 failed:" << errorMsg;
            
            // Emit PS Plus subscription error if detected
            if (isPSPlusError) {
                emit psPlusSubscriptionError();
            }
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

// Helper function to parse x-gaikai-event header
static QString parseGaikaiEventName(QNetworkReply *reply)
{
    QByteArray eventHeader = reply->rawHeader("x-gaikai-event");
    if (eventHeader.isEmpty()) {
        return QString();
    }
    
    QJsonDocument eventDoc = QJsonDocument::fromJson(eventHeader);
    if (eventDoc.isNull() || !eventDoc.isObject()) {
        return QString();
    }
    
    QJsonObject eventObj = eventDoc.object();
    return eventObj["name"].toString();
}

// Step 10: Lock session
void PSGaikaiStreaming::step10_LockSession()
{
    if (lockSessionRetryCount == 0) {
        emit AllocationProgress("Locking Session - Step 7 of 10");
    }
    qInfo() << "Gaikai Step 10: Locking session... (attempt" << (lockSessionRetryCount + 1) << ")";
    
    QString urlStr = GaikaiConsts::GAIKAI_BASE + "/sessions/" + gaikaiSessionId + "/lock?forceLogout=true";
    
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
    logDebugRequest("Step 10: LockSession", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
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
        int pollFrequency = jsonObj["pollFrequency"].toInt(10); // Default 10 seconds
        
        qInfo() << "Gaikai Step 10 response - Lock acquired:" << lockAcquired << ", pollFrequency:" << pollFrequency;
        
        if (!lockAcquired) {
            // Extract event name from header if available
            QString eventName = parseGaikaiEventName(reply);
            lockSessionRetryCount++;
            
            if (lockSessionRetryCount > MAX_LOCK_SESSION_RETRIES) {
                qWarning() << "Lock session max retries exceeded:" << lockSessionRetryCount << "(max:" << MAX_LOCK_SESSION_RETRIES << ")";
                emit AllocationError(QString("Lock session failed: Could not acquire lock after %1 attempts").arg(MAX_LOCK_SESSION_RETRIES));
                emit Finished();
                return;
            }
            
            QString message;
            if (!eventName.isEmpty()) {
                message = QString("Closing old session (%1) - Attempt %2").arg(eventName).arg(lockSessionRetryCount);
            } else {
                message = QString("Closing old session - Attempt %1").arg(lockSessionRetryCount);
            }
            emit AllocationProgress(message);
            
            qInfo() << "Lock not acquired, retrying in" << pollFrequency << "seconds... (attempt" << lockSessionRetryCount << "of" << MAX_LOCK_SESSION_RETRIES << ")";
            
            // Retry after pollFrequency seconds
            QTimer::singleShot(pollFrequency * 1000, this, [this]() {
                step10_LockSession();
            });
            return;
        }
        
        // Lock acquired successfully - reset retry counter
        lockSessionRetryCount = 0;
        
        // Store the session key from LOCK response for use in ping
        lockSessionKey = configKey;
        qInfo() << "Gaikai Step 10: Stored LOCK session key for ping (length:" << lockSessionKey.length() << "):" << lockSessionKey.left(50) << "...";
        
        // Continue to Step 11
        step11_GetDatacenters();
    });
}

// Step 11: Get available datacenters
void PSGaikaiStreaming::step11_GetDatacenters()
{
    emit AllocationProgress("Getting Datacenters - Step 8 of 10");
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
    QByteArray requestBody = doc.toJson();
    logDebugRequest("Step 11: GetDatacenters", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
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
        
        if (datacenters.isEmpty()) {
            qWarning() << "Gaikai Step 11: No datacenters available";
            emit AllocationError("No datacenters available");
            emit Finished();
            return;
        }
        
        // Save datacenters to settings (without ping results yet) - use service-specific method
        QJsonDocument datacentersDoc(datacenters);
        if (serviceType == "pscloud") {
            settings->SetCloudDatacentersJsonPSCloud(datacentersDoc.toJson(QJsonDocument::Compact));
        } else {
            settings->SetCloudDatacentersJsonPSNOW(datacentersDoc.toJson(QJsonDocument::Compact));
        }

        // Check if a specific datacenter is selected (non-auto)
        QString selectedDatacenterSetting;
        if (serviceType == "pscloud") {
            selectedDatacenterSetting = settings->GetCloudDatacenterPSCloud();
        } else {
            selectedDatacenterSetting = settings->GetCloudDatacenterPSNOW();
        }

        if (selectedDatacenterSetting != "Auto" && !selectedDatacenterSetting.isEmpty()) {
            // Find the selected datacenter in the list
            QJsonObject selectedDc;
            bool found = false;
            for (const QJsonValue &dcValue : datacenters) {
                QJsonObject dc = dcValue.toObject();
                if (dc["dataCenter"].toString() == selectedDatacenterSetting) {
                    selectedDc = dc;
                    found = true;
                    break;
                }
            }

            if (!found) {
                qWarning() << "Selected datacenter" << selectedDatacenterSetting << "not found in available datacenters";
                emit AllocationError(QString("Selected datacenter '%1' not available").arg(selectedDatacenterSetting));
                emit Finished();
                return;
            }

            // Create dummy ping result with hardcoded values
            QJsonObject dummyPingResult;
            dummyPingResult["dataCenter"] = selectedDc["dataCenter"].toString();
            // Keep the dummy schema identical to DatacenterPing results, because /datacenters/select
            // appears to depend on fields like "rtts" (and may return an empty body otherwise).
            int dummyRttMs = 20;  // 20ms dummy RTT
            dummyPingResult["rtt"] = dummyRttMs;
            dummyPingResult["rtts"] = QJsonArray::fromVariantList({dummyRttMs});
            dummyPingResult["mtu_in"] = 1454;  // Hardcoded MTU in
            dummyPingResult["mtu_out"] = 1254;  // Hardcoded MTU out
            dummyPingResult["port"] = selectedDc["port"].toInt();
            dummyPingResult["publicIp"] = selectedDc["publicIp"].toString();
            dummyPingResult["maxBandwidth"] = selectedDc["maxBandwidth"].toInt();

            qInfo() << "Bypassing ping tests - using manually selected datacenter:" << selectedDatacenterSetting;
            qInfo() << "Using dummy ping values: RTT=20ms, MTU in=1454, MTU out=1254";
            qInfo() << "Note: Dummy ping values are NOT saved to settings (preserving existing real ping data)";

            // Create single result array for step12 (don't save dummy values to settings)
            QJsonArray singleResult;
            singleResult.append(dummyPingResult);

            // Skip ping and go directly to step 12 (using dummy values for this session only)
            step12_SelectDatacenter(singleResult);
            return;
        }

        // Auto mode: Use the session key from Step 10 (LOCK) for ping
        QString pingSessionKey = lockSessionKey;

        // Ping all datacenters using senkusha handshake
        emit AllocationProgress("Pinging Datacenters - Step 8 of 10");
        DatacenterPing::pingAllDatacentersWithTimeout(datacenters, pingSessionKey, serviceType, settings,
            [this, datacenters](QJsonArray pingResults) {
                qInfo() << "Gaikai Step 11: Ping callback invoked with" << pingResults.size() << "results";
                
                // IMPORTANT: Use the CURRENT session key (configKey) when calling step12, not the one from when ping started
                // The session key may have been updated during the ping, so we use the latest value
                qInfo() << "Gaikai Step 11: Using current session key for step 12:" << configKey.left(30) << "...";

                // Create a map of ping results by datacenter name
                QHash<QString, QJsonObject> pingResultsMap;
                for (const QJsonValue &val : pingResults) {
                    QJsonObject result = val.toObject();
                    pingResultsMap[result["dataCenter"].toString()] = result;
                }
                
                // Build final results: use ping results where available, dummy data for others
                QJsonArray allResults;
                for (const QJsonValue &dcValue : datacenters) {
                    QJsonObject dc = dcValue.toObject();
                    QString datacenterName = dc["dataCenter"].toString();
                    
                    if(pingResultsMap.contains(datacenterName)) {
                        // Use actual ping result
                        allResults.append(pingResultsMap[datacenterName]);
                    } else {
                        // Use dummy data (999ms RTT) for datacenters that weren't pinged
                        QJsonObject dummyResult;
                        dummyResult["dataCenter"] = datacenterName;
                        dummyResult["rtt"] = 999;
                        dummyResult["rtts"] = QJsonArray::fromVariantList({999});
                        dummyResult["mtu_in"] = 0;
                        dummyResult["mtu_out"] = 0;
                        dummyResult["port"] = dc["port"].toInt();
                        dummyResult["publicIp"] = dc["publicIp"].toString();
                        dummyResult["maxBandwidth"] = dc["maxBandwidth"].toInt();
                        allResults.append(dummyResult);
                    }
                }

                // Sort by RTT (lowest first)
                std::vector<QJsonObject> resultsList;
                for (const QJsonValue &val : allResults) {
                    resultsList.push_back(val.toObject());
                }
                std::sort(resultsList.begin(), resultsList.end(), [](const QJsonObject &a, const QJsonObject &b) {
                    return a["rtt"].toInt() < b["rtt"].toInt();
                });
                QJsonArray sortedResults;
                for (const QJsonObject &obj : resultsList) {
                    sortedResults.append(obj);
                }

                // Merge with existing datacenters (update existing, add new, keep old ones)
                QJsonArray mergedResults = mergeDatacentersWithExisting(sortedResults);
                
                // Save merged datacenters to settings - use service-specific method
                QJsonDocument pingResultsDoc(mergedResults);
                if (serviceType == "pscloud") {
                    settings->SetCloudDatacentersJsonPSCloud(pingResultsDoc.toJson(QJsonDocument::Compact));
                } else {
                    settings->SetCloudDatacentersJsonPSNOW(pingResultsDoc.toJson(QJsonDocument::Compact));
                }

                qInfo() << "Gaikai Step 11: Ping complete. Results:";
                for (const QJsonValue &val : sortedResults) {
                    QJsonObject dc = val.toObject();
                    qInfo() << "  -" << dc["dataCenter"].toString() << ":" << dc["rtt"].toInt() << "ms";
                }

                // Continue to Step 12 (will use current configKey value)
                step12_SelectDatacenter(sortedResults);
            });
    });
}

// Step 12: Select datacenter
void PSGaikaiStreaming::step12_SelectDatacenter(QJsonArray pingResults)
{
    // Determine which datacenter to select
    QString selectedDatacenterSetting;
    if (serviceType == "pscloud") {
        selectedDatacenterSetting = settings->GetCloudDatacenterPSCloud();
    } else {
        // PSNOW
        selectedDatacenterSetting = settings->GetCloudDatacenterPSNOW();
    }
    
    if (selectedDatacenterSetting == "Auto" || selectedDatacenterSetting.isEmpty()) {
        // Auto-select: choose the datacenter with the lowest RTT
        if (!pingResults.isEmpty()) {
            QJsonObject bestDc = pingResults[0].toObject();  // Already sorted by RTT
            selectedDatacenter = bestDc["dataCenter"].toString();
            selectedDatacenterPingResult = bestDc;  // Store full ping result
            qInfo() << "Auto-selected datacenter:" << selectedDatacenter << "with RTT:" << bestDc["rtt"].toInt() << "ms";
        } else {
            qWarning() << "No ping results available for auto-selection";
            emit AllocationError("No datacenters available");
            emit Finished();
            return;
        }
    } else {
        // Use the manually selected datacenter
        selectedDatacenter = selectedDatacenterSetting;
        qInfo() << "Using manually selected datacenter:" << selectedDatacenter;
        
        // Find the ping results for this datacenter
        bool found = false;
        for (const QJsonValue &val : pingResults) {
            QJsonObject pingResult = val.toObject();
            if (pingResult["dataCenter"].toString() == selectedDatacenter) {
                found = true;
                selectedDatacenterPingResult = pingResult;  // Store full ping result
                qInfo() << "Found ping results for" << selectedDatacenter << "- RTT:" << pingResult["rtt"].toInt() << "ms";
                break;
            }
        }
        
        if (!found) {
            qWarning() << "Selected datacenter" << selectedDatacenter << "not found in ping results, falling back to auto-select";
            if (!pingResults.isEmpty()) {
                QJsonObject bestDc = pingResults[0].toObject();
                selectedDatacenter = bestDc["dataCenter"].toString();
                selectedDatacenterPingResult = bestDc;  // Store full ping result
            } else {
                emit AllocationError("Selected datacenter not available");
                emit Finished();
                return;
            }
        }
    }
    
    // Validate ping for auto-selected datacenters (manual selection bypasses this check)
    bool isAutoSelected = (selectedDatacenterSetting == "Auto" || selectedDatacenterSetting.isEmpty());
    if (isAutoSelected) {
        int rtt_ms = selectedDatacenterPingResult["rtt"].toInt(0);
        if (rtt_ms > 80) {
            qWarning() << "Selected datacenter ping too high:" << selectedDatacenter << "RTT:" << rtt_ms << "ms (max: 80ms)";
            emit pingTimeoutError();
            emit AllocationError("Ping must be < 80ms to start a cloud session");
            emit Finished();
            return;
        }
    }
    
    emit AllocationProgress(QString("Selecting Datacenter (%1) - Step 9 of 10").arg(selectedDatacenter));
    qInfo() << "Gaikai Step 12: Selecting datacenter:" << selectedDatacenter;
    qInfo() << "Gaikai Step 12: Using session key:" << configKey.left(30) << "...";

    // IMPORTANT:
    // Step 12 responses are sometimes empty (no JSON body), but we already know the correct
    // datacenter port from Step 11 (datacenters list / ping results). Preserve it here so
    // Step 13 never falls back to a wrong default like 2053 when the real port is e.g. 40101.
    int portFromPing = selectedDatacenterPingResult["port"].toInt(0);
    if (portFromPing > 0) {
        selectedDatacenterPort = portFromPing;
        qInfo() << "Gaikai Step 12: Using port from ping results:" << selectedDatacenterPort;
    } else if (selectedDatacenterPort > 0) {
        qInfo() << "Gaikai Step 12: Using previously known port:" << selectedDatacenterPort;
    } else {
        selectedDatacenterPort = 2053; // final fallback (primarily PSNOW legacy)
        qWarning() << "Gaikai Step 12: No port in ping results; defaulting to" << selectedDatacenterPort;
    }
    
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
    QByteArray requestBody = doc.toJson();
    
    logDebugRequest("Step 12: SelectDatacenter", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            QByteArray errorData = reply->readAll();
            QString errorStr = QString::fromUtf8(errorData);
            qWarning() << "Gaikai Step 12 failed:" << reply->errorString();
            qWarning() << "Server response:" << errorStr;
            
            // Parse error response to get detailed error message
            QString detailedError = reply->errorString();
            QJsonParseError parseError;
            QJsonDocument errorDoc = QJsonDocument::fromJson(errorData, &parseError);
            if (parseError.error == QJsonParseError::NoError && errorDoc.isObject()) {
                QJsonObject errorObj = errorDoc.object();
                if (errorObj.contains("errors") && errorObj["errors"].isArray()) {
                    QJsonArray errors = errorObj["errors"].toArray();
                    if (!errors.isEmpty() && errors[0].isObject()) {
                        QJsonObject firstError = errors[0].toObject();
                        if (firstError.contains("description")) {
                            detailedError = firstError["description"].toString();
                        } else if (firstError.contains("eventCode")) {
                            detailedError = QString("Error %1: %2")
                                .arg(firstError["eventCode"].toString())
                                .arg(firstError.contains("description") ? firstError["description"].toString() : "Unknown error");
                        }
                    }
                }
            }
            
            emit AllocationError(QString("Select datacenter failed: %1").arg(detailedError));
            emit Finished();
            return;
        }
        
        updateSessionKey(reply);
        
        QByteArray data = reply->readAll();
        if (data.trimmed().isEmpty()) {
            qWarning() << "Gaikai Step 12 failed: Empty response body from /datacenters/select";
            qWarning() << "This usually indicates pingResults format mismatch (e.g. missing rtts) or an auth/session issue.";
            emit AllocationError("Select datacenter failed: empty response body (check pingResults format)");
            emit Finished();
            return;
        }

        QJsonParseError parseError;
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data, &parseError);
        if (parseError.error != QJsonParseError::NoError || !jsonDoc.isObject()) {
            qWarning() << "Gaikai Step 12 failed: Invalid JSON response from /datacenters/select:" << parseError.errorString();
            qWarning() << "Raw response:" << QString::fromUtf8(data);
            emit AllocationError(QString("Select datacenter failed: invalid JSON response (%1)").arg(parseError.errorString()));
            emit Finished();
            return;
        }

        QJsonObject selected = jsonDoc.object();
        
        // Log full response for debugging
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "=== Step 12: Select Datacenter Response ===";
            qInfo() << "Full response:" << QString::fromUtf8(data);
            qInfo() << "===========================================";
        }
        
        // Extract port from Step 12 response if present; otherwise keep the port we already had.
        // The port might be in the root object or in a nested "network" object.
        int portFromResponse = selected["port"].toInt(0);
        if (portFromResponse <= 0 && selected.contains("network") && selected["network"].isObject()) {
            QJsonObject network = selected["network"].toObject();
            portFromResponse = network["port"].toInt(0);
        }

        if (portFromResponse > 0) {
            selectedDatacenterPort = portFromResponse;
            qInfo() << "Gaikai Step 12: Using port from response:" << selectedDatacenterPort;
        } else if (selectedDatacenterPort <= 0) {
            qWarning() << "Gaikai Step 12: No valid port in response and no previously known port; defaulting to 2053";
            qWarning() << "Response keys:" << selected.keys();
            if (selected.contains("network")) {
                qWarning() << "Network object keys:" << selected["network"].toObject().keys();
            }
            selectedDatacenterPort = 2053;
        } else {
            qWarning() << "Gaikai Step 12: No valid port in response; keeping existing port:" << selectedDatacenterPort;
        }
        
        qInfo() << "Gaikai Step 12 complete - Selected:" << selectedDatacenter
                << selectedDatacenterPingResult["publicIp"].toString() << ":" << selectedDatacenterPort;
        
        // Continue to Step 13 (port will be used in network object and also extracted from allocate response)
        step13_AllocateSlot();
    });
}

// Step 13: Allocate streaming slot
void PSGaikaiStreaming::step13_AllocateSlot()
{
    if (allocationRetryCount == 0) {
        emit AllocationProgress("Allocating Streaming Slot - Step 10 of 10");
    }
    qInfo() << "Gaikai Step 13: Allocating streaming slot... (attempt" << (allocationRetryCount + 1) << ")";
    qInfo() << "Gaikai Step 13: Using session key:" << configKey.left(30) << "...";
    
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
    
    // Network info (use real values from ping results, port from step12 response)
    QJsonObject network;
    // High bandwidth values to ensure PS servers accept the connection
    network["bwKbpsSent"] = 50000;        // 50 Mbps upload (very high for server acceptance)
    network["bwLoss"] = 0.001;            // 0.1% packet loss (excellent)
    // Use real MTU values from ping results, with fallback to defaults
    network["mtu"] = selectedDatacenterPingResult["mtu_in"].toInt(1454);
    network["rtt"] = selectedDatacenterPingResult["rtt"].toInt(25);
    network["port"] = selectedDatacenterPort;  // Use port from step12 (dynamic)
    network["bwKbpsReceived"] = 200000;   // 200 Mbps download (very high for server acceptance)
    network["bwLossUpstream"] = 0;         // No upstream packet loss (excellent)
    // Use real outbound MTU from ping results, with fallback to default
    network["mtuUpstream"] = selectedDatacenterPingResult["mtu_out"].toInt(1254);
    body["network"] = network;
    
    qInfo() << "Gaikai Step 13: Using network values - RTT:" << network["rtt"].toInt() 
            << "ms, MTU in:" << network["mtu"].toInt() 
            << ", MTU out:" << network["mtuUpstream"].toInt();
    
    body["stateExecutionTime"] = 5974.7632;
    body["streamTestTime"] = 11262.8423;
    
    QJsonDocument doc(body);
    QByteArray requestBody = doc.toJson();
    
    logDebugRequest("Step 13: AllocateSlot", req, requestBody);
    
    QNetworkReply *reply = manager->post(req, requestBody);
    
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

        // Ensure every response can rotate the x-gaikai-session key, especially important
        // when the server returns queued/dataMigration and we need to poll/retry.
        updateSessionKey(reply);
        
        QByteArray data = reply->readAll();
        QJsonDocument jsonDoc = QJsonDocument::fromJson(data);
        QJsonObject allocation = jsonDoc.object();
        
        // Log the full allocation response for inspection
        qInfo() << "=== Step 13: Allocate Response - Full JSON ===";
        qInfo() << jsonDoc.toJson(QJsonDocument::Indented);
        qInfo() << "==============================================";
        
        // Check if we need to wait and retry (queued or data migration)
        bool queued = allocation["queued"].toBool();
        bool dataMigration = allocation["dataMigration"].toBool();
        int pollFrequency = allocation["pollFrequency"].toInt(15); // Default 15 seconds
        
        if (queued || dataMigration) {
            // Initialize timer and calculate max wait time on first wait
            if (!allocationWaitTimer.isValid()) {
                allocationWaitTimer.start();
                
                // Calculate max wait time from waitTimeEstimate (multiply by 2 for safety, cap at 15 min, fallback to 5 min)
                int waitTimeEstimate = allocation["waitTimeEstimate"].toInt(-1);
                if (waitTimeEstimate > 0) {
                    allocationMaxWaitSeconds = waitTimeEstimate * 2; // Multiply by 2 for safety
                    if (allocationMaxWaitSeconds > MAX_ALLOCATION_WAIT_SECONDS) {
                        allocationMaxWaitSeconds = MAX_ALLOCATION_WAIT_SECONDS; // Cap at 15 minutes
                    }
                    qInfo() << "Allocation queued/data migration. Using waitTimeEstimate:" << waitTimeEstimate 
                            << "seconds (doubled to" << allocationMaxWaitSeconds << "seconds for safety, max 15 min)";
                } else {
                    allocationMaxWaitSeconds = DEFAULT_ALLOCATION_WAIT_SECONDS; // Fallback to 5 minutes
                    qInfo() << "Allocation queued/data migration. No waitTimeEstimate, using default:" << allocationMaxWaitSeconds << "seconds (5 min)";
                }
            }
            
            int elapsedSeconds = allocationWaitTimer.elapsed() / 1000;
            
            if (elapsedSeconds >= allocationMaxWaitSeconds) {
                qWarning() << "Allocation wait timeout after" << elapsedSeconds << "seconds (max:" << allocationMaxWaitSeconds << "s)";
                emit AllocationError(QString("Allocation timeout: Server did not become ready within %1 seconds").arg(allocationMaxWaitSeconds));
                emit Finished();
                return;
            }
            
            int waitTime = pollFrequency;
            int remainingTime = allocationMaxWaitSeconds - elapsedSeconds;
            if (waitTime > remainingTime) {
                waitTime = remainingTime;
            }
            
            allocationRetryCount++;
            QString retryMessage;
            int queuePosition = -1;
            if (dataMigration) {
                int migrationPercent = allocation["dataMigrationPercentageComplete"].toInt(0);
                retryMessage = QString("Migrating data (%1%%) - Attempt %2").arg(migrationPercent).arg(allocationRetryCount);
                qInfo() << "Data migration progress:" << migrationPercent << "%";
            } else {
                // Extract queue position if available (prefer displayQueuePosition, fallback to queuePosition)
                if (allocation.contains("displayQueuePosition")) {
                    queuePosition = allocation["displayQueuePosition"].toInt(-1);
                } else if (allocation.contains("queuePosition")) {
                    queuePosition = allocation["queuePosition"].toInt(-1);
                }
                
                // Build retry message with queue position if available
                if (queuePosition >= 0) {
                    retryMessage = QString("Allocating streaming slot - Queue position: %1 - Attempt %2").arg(queuePosition).arg(allocationRetryCount);
                } else {
                    retryMessage = QString("Allocating streaming slot - Attempt %1").arg(allocationRetryCount);
                }
            }
            emit AllocationProgress(retryMessage, queuePosition);
            
            qInfo() << "Allocation queued/data migration. Waiting" << waitTime << "seconds before retry (elapsed:" << elapsedSeconds << "s, remaining:" << remainingTime << "s, max:" << allocationMaxWaitSeconds << "s, attempt:" << allocationRetryCount << ")";
            
            // Wait and retry
            QTimer::singleShot(waitTime * 1000, this, [this]() {
                qInfo() << "Retrying allocation request...";
                step13_AllocateSlot();
            });
            return;
        }
        
        // Allocation successful - reset retry counter
        allocationRetryCount = 0;
        
        // Allocation successful - extract connection info
        QJsonObject launchSlot = allocation["launchSlot"].toObject();
        if (launchSlot.isEmpty()) {
            qWarning() << "Allocation response missing launchSlot";
            emit AllocationError("Allocation response invalid: missing launchSlot");
            emit Finished();
            return;
        }
        
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
        int timeLimit = allocation["timeLimit"].toInt();
        int startGameTimeout = allocation["startGameTimeout"].toInt();
        
        qInfo() << "Time Limit:" << timeLimit << "minutes";
        qInfo() << "Start Timeout:" << startGameTimeout << "seconds";
        
        if (finalCallback.isCallable()) {
            finalCallback.call({true, QString("Streaming slot allocated: %1:%2").arg(allocatedServerIp).arg(allocatedServerPort), allocatedServerIp});
        }
        
        emit AllocationComplete(allocatedServerIp, allocatedServerPort, allocatedHandshakeKey, allocatedLaunchSpec, allocatedSessionId);
        emit Finished();
    });
}

