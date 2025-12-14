// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/psgaikaistreaming.h"
#include "chiaki/remote/holepunch.h"

#include <QObject>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QUrlQuery>

// ============================================================================
// GAIKAI CONFIG - Gaikai-specific base URLs only
// ============================================================================
namespace GaikaiConsts {
    static const QString CONFIG_BASE = "https://config.cc.prod.gaikai.com/v1";
    static const QString GAIKAI_BASE = "https://cc.prod.gaikai.com/v1";
}

PSGaikaiStreaming::PSGaikaiStreaming(Settings *settings, QString npsso, QString deviceUid, QNetworkCookieJar *cookieJar,
                                   QString accountBase, QString redirectUri, QString userAgent, QObject *parent)
    : QObject(parent)
    , settings(settings)
    , npsso(npsso)
    , duid(deviceUid)
    , cookieJar(cookieJar)
    , accountBaseUrl(accountBase)
    , redirectUriUrl(redirectUri)
    , userAgentString(userAgent)
{
    manager = new QNetworkAccessManager(this);
    manager->setCookieJar(cookieJar);
}

QJsonObject PSGaikaiStreaming::buildRequestGameSpec(QString entitlementId)
{
    // Build as raw JSON string - easy to edit and compare with PowerShell script
    // Only auth codes are parameterized, rest is hardcoded for visibility
    QString jsonStr = QString(R"({
        "entitlementId": "%1",
        "audioChannels": "2.1",
        "language": "en-US",
        "acceptButton": "X",
        "audioEncoderProfile": "default",
        "videoEncoderProfile": "hw4.1",
        "adaptiveStreamMode": "resize",
        "gkCloudAuthCode": "%2",
        "ps3AuthCode": "%3",
        "streamServerAuthCode": "%4",
        "resolutionSetting": 1080,
        "npEnv": "np",
        "parentalLevel": 0,
        "yuvCoefficient": "",
        "timeZone": "UTC-08:00",
        "summerTime": 0,
        "encryptionSupported": true,
        "homeSharing": false,
        "gaikaiPlayer": "12.5.0",
        "protocolVersion": 9,
        "audioUploadSamplingFrequency": 48000,
        "audioUploadNumChannels": 1,
        "audioUploadEnabled": 1,
        "accessibilityTtsEnable": 0,
        "accessibilityTtsSpeed": 0,
        "accessibilityTtsVolume": 0,
        "accessibilityMarqueeSpeed": 0,
        "accessibilityLargeText": 0,
        "accessibilityBoldText": 0,
        "accessibilityContrast": 0,
        "partyCapability": false,
        "capabilities": ["cloudDrivenSenkushaTest", "kratos"],
            "redirectUri": "%5",
        "connectedControllers": ["xinput"],
        "model": "WINDOWS",
        "platform": "PC"
    })")
        .arg(entitlementId)
        .arg(gkCloudAuthCode)
        .arg(ps3AuthCode)
        .arg(streamServerAuthCode)
        .arg(redirectUriUrl);
    
    QJsonDocument doc = QJsonDocument::fromJson(jsonStr.toUtf8());
    QJsonObject obj = doc.object();
    
    // Log the full JSON for inspection
    qInfo() << "=== buildRequestGameSpec - Full JSON ===";
    qInfo() << QJsonDocument(obj).toJson(QJsonDocument::Indented);
    qInfo() << "========================================";
    
    return obj;
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
    qInfo() << "Gaikai Allocation: Starting complete flow for entitlement:" << entitlementId;
    finalCallback = callback;
    
    // Store entitlement for later use
    requestGameSpec = buildRequestGameSpec(entitlementId);
    
    // Start with Step 7
    step7_GetConfig();
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
    body["product"] = "psnow";
    body["platform"] = "PC";
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
        gkClientId = jsonObj["gkClientId"].toString();
        ps3GkClientId = jsonObj["ps3GkClientId"].toString();
        streamServerClientId = jsonObj["streamServerClientId"].toString();
        
        qInfo() << "Gaikai Step 8 complete:";
        qInfo() << "  sessionId:" << gaikaiSessionId;
        qInfo() << "  gkClientId:" << gkClientId;
        qInfo() << "  ps3GkClientId:" << ps3GkClientId;
        
        // Continue to Step 8a
        step8a_GetGkAuthCode();
    });
}

// Step 8a: Get gkClientId authorization code
void PSGaikaiStreaming::step8a_GetGkAuthCode()
{
    qInfo() << "Gaikai Step 8a: Getting gkClientId auth code...";
    
    QUrl url(accountBaseUrl + "/v1/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("smcid", "pc:psnow");
    query.addQueryItem("applicationId", "psnow");
    query.addQueryItem("response_type", "code");
    query.addQueryItem("scope", "kamaji:commerce_native versa:user_update_entitlements_first_play kamaji:lists");
    query.addQueryItem("client_id", gkClientId);
    query.addQueryItem("redirect_uri", "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html");
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("renderMode", "mobilePortrait");
    query.addQueryItem("hidePageElements", "forgotPasswordLink");
    query.addQueryItem("displayFooter", "none");
    query.addQueryItem("disableLinks", "qriocityLink");
    query.addQueryItem("mid", "PSNOW");
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("service_logo", "ps");
    query.addQueryItem("tp_psn", "true");
    query.addQueryItem("noEVBlock", "true");
    url.setQuery(query);
    
    QNetworkRequest req(url);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        gkCloudAuthCode = QUrlQuery(redirectUrl).queryItemValue("code");
        
        if (gkCloudAuthCode.isEmpty()) {
            qWarning() << "Gaikai Step 8a failed: No auth code in redirect";
            emit AllocationError("Failed to get gkClientId auth code");
            emit Finished();
            return;
        }
        
        qInfo() << "Gaikai Step 8a complete - Got gkCloudAuthCode:" << gkCloudAuthCode;
        
        // Continue to Step 8b
        step8b_GetPs3AuthCode();
    });
}

// Step 8b: Get ps3GkClientId authorization code
void PSGaikaiStreaming::step8b_GetPs3AuthCode()
{
    qInfo() << "Gaikai Step 8b: Getting ps3GkClientId auth code...";
    
    QUrl url(accountBaseUrl + "/v1/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("smcid", "pc:psnow");
    query.addQueryItem("applicationId", "psnow");
    query.addQueryItem("response_type", "code");
    query.addQueryItem("scope", "sso:none");
    query.addQueryItem("client_id", ps3GkClientId);
    query.addQueryItem("redirect_uri", "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html");
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("renderMode", "mobilePortrait");
    query.addQueryItem("hidePageElements", "forgotPasswordLink");
    query.addQueryItem("displayFooter", "none");
    query.addQueryItem("disableLinks", "qriocityLink");
    query.addQueryItem("mid", "PSNOW");
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("service_logo", "ps");
    query.addQueryItem("tp_psn", "true");
    query.addQueryItem("noEVBlock", "true");
    url.setQuery(query);
    
    QNetworkRequest req(url);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    QNetworkReply *reply = manager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
        ps3AuthCode = QUrlQuery(redirectUrl).queryItemValue("code");
        streamServerAuthCode = ps3AuthCode; // Same code used for both
        
        if (ps3AuthCode.isEmpty()) {
            qWarning() << "Gaikai Step 8b failed: No auth code in redirect";
            emit AllocationError("Failed to get ps3GkClientId auth code");
            emit Finished();
            return;
        }
        
        qInfo() << "Gaikai Step 8b complete - Got ps3AuthCode:" << ps3AuthCode;
        
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
    QNetworkReply *reply = manager->post(req, doc.toJson());
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "Gaikai Step 9 failed:" << reply->errorString();
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
        
        // Build fake ping results (for testing)
        QJsonArray pingResults;
        QJsonObject pingResult;
        pingResult["dataCenter"] = selectedDatacenter;
        pingResult["rtt"] = 25;
        QJsonArray rtts;
        for (int i = 0; i < 10; i++) rtts.append(25 + (i % 5));
        pingResult["rtts"] = rtts;
        pingResult["port"] = 2053;
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
        
        qInfo() << "Gaikai Step 12 complete - Selected:" << selected["dataCenter"].toString()
                << selected["publicIp"].toString() << ":" << selected["port"].toInt();
        
        // Continue to Step 13
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
    
    // Network info
    QJsonObject network;
    network["bwKbpsSent"] = 22794;
    network["bwLoss"] = 0.056522;
    network["mtu"] = 1454;
    network["rtt"] = 25;
    network["port"] = 2053;
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

