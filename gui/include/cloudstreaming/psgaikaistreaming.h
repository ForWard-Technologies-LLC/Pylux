// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef PSGAIKAISTREAMING_H
#define PSGAIKAISTREAMING_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QNetworkAccessManager>
#include <QNetworkCookieJar>
#include <QJSValue>
#include <QJsonObject>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// Complete Gaikai streaming allocation flow (Steps 7-13)
class PSGaikaiStreaming : public QObject {
    Q_OBJECT

public:
    explicit PSGaikaiStreaming(Settings *settings, QString npsso, QString duid, QNetworkCookieJar *cookieJar, 
                              QString accountBase, QString redirectUri, QString userAgent, QObject *parent = nullptr);
    
    // Complete allocation flow - calls all steps in sequence
    void StartAllocationFlow(QString entitlementId, const QJSValue &callback);

signals:
    void AllocationComplete(QString serverIp, int serverPort, QString handshakeKey, QString launchSpec, QString sessionId);
    void AllocationError(QString error);
    void Finished();

public:
    // Accessors for allocation results (available after AllocationComplete signal)
    QString getServerIp() const { return allocatedServerIp; }
    int getServerPort() const { return allocatedServerPort; }
    QString getHandshakeKey() const { return allocatedHandshakeKey; }
    QString getLaunchSpec() const { return allocatedLaunchSpec; }
    uint8_t getPsnWrapperType() const { return allocatedPsnWrapperType; }
    QString getGaikaiSessionId() const { return allocatedSessionId; }

private:
    Settings *settings;
    QString npsso;
    QNetworkAccessManager *manager;
    QNetworkCookieJar *cookieJar;
    
    // Shared config (passed from CloudConfig)
    QString accountBaseUrl;
    QString redirectUriUrl;
    QString userAgentString;
    
    // Allocation results (stored as class members)
    QString allocatedServerIp;
    int allocatedServerPort;
    QString allocatedHandshakeKey;
    QString allocatedLaunchSpec;
    uint8_t allocatedPsnWrapperType;
    QString allocatedSessionId;
    
    // State management
    QString configKey;        // x-gaikai-session key (updates with each response)
    QString gaikaiSessionId;
    QString gkClientId;
    QString ps3GkClientId;
    QString streamServerClientId;
    QString gkCloudAuthCode;
    QString ps3AuthCode;
    QString streamServerAuthCode;
    QString selectedDatacenter;
    QString duid;
    QJsonObject requestGameSpec;
    QJSValue finalCallback;
    
    // Helper to build request game specification
    QJsonObject buildRequestGameSpec(QString entitlementId);
    
    // Step 7: Get config
    void step7_GetConfig();
    
    // Step 8: Start session
    void step8_StartSession(QString entitlementId);
    
    // Step 8a: Get gkClientId auth code
    void step8a_GetGkAuthCode();
    
    // Step 8b: Get ps3GkClientId auth code
    void step8b_GetPs3AuthCode();
    
    // Step 9: Authorize session
    void step9_AuthorizeSession();
    
    // Step 10: Lock session
    void step10_LockSession();
    
    // Step 11: Get datacenters
    void step11_GetDatacenters();
    
    // Step 12: Select datacenter (for now, auto-select first one)
    void step12_SelectDatacenter(QJsonArray pingResults);
    
    // Step 13: Allocate slot
    void step13_AllocateSlot();
    
    // Helper to extract and update session key from response
    void updateSessionKey(QNetworkReply *reply);
    
    // Debug logging helper
    void logDebugResponse(const QString &stepName, QNetworkReply *reply);
};

#endif // PSGAIKAISTREAMING_H

