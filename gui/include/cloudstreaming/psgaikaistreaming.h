// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef PSGAIKAISTREAMING_H
#define PSGAIKAISTREAMING_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QNetworkAccessManager>
#include <QJSValue>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QElapsedTimer>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// Complete Gaikai streaming allocation flow (Steps 7-13)
class PSGaikaiStreaming : public QObject {
    Q_OBJECT

public:
    explicit PSGaikaiStreaming(Settings *settings, QString duid, 
                              QString serviceType, QString platform,
                              QObject *parent = nullptr);
    
    // Complete allocation flow - calls all steps in sequence
    void StartAllocationFlow(QString entitlementId, const QJSValue &callback);

signals:
    void AllocationComplete(QString serverIp, int serverPort, QString handshakeKey, QString launchSpec, QString sessionId);
    void AllocationError(QString error);
    void AllocationProgress(QString message, int queuePosition = -1);
    void psPlusSubscriptionError();
    void pingTimeoutError();
    void Finished();

public:
    // Accessors for allocation results (available after AllocationComplete signal)
    QString getServerIp() const { return allocatedServerIp; }
    int getServerPort() const { return allocatedServerPort; }
    QString getHandshakeKey() const { return allocatedHandshakeKey; }
    QString getLaunchSpec() const { return allocatedLaunchSpec; }
    uint8_t getPsnWrapperType() const { return allocatedPsnWrapperType; }
    QString getGaikaiSessionId() const { return allocatedSessionId; }
    QJsonObject getSelectedDatacenterPingResult() const { return selectedDatacenterPingResult; }

private:
    Settings *settings;
    QString npsso;
    QNetworkAccessManager *manager;
    
    // Service/platform configuration
    QString serviceType;      // "psnow" or "pscloud"
    QString platform;         // "ps3", "ps4", or "ps5"
    QString virtType;         // "konan" (PS3), "kratos" (PS4), "cronos" (PS5)
    
    // Shared config (passed from CloudConfig)
    QString accountBaseUrl;
    QString redirectUriUrl;
    QString userAgentString;
    QString oauthApiPath;     // "/api/v1" (PSNOW) or "/api/authz/v3" (PSCLOUD)
    
    // Allocation results (stored as class members)
    QString allocatedServerIp;
    int allocatedServerPort;
    QString allocatedHandshakeKey;
    QString allocatedLaunchSpec;
    uint8_t allocatedPsnWrapperType;
    QString allocatedSessionId;
    
    // State management
    QString configKey;        // x-gaikai-session key (updates with each response)
    QString lockSessionKey;   // x-gaikai-session key from Step 10 (LOCK) - used for ping
    QString gaikaiSessionId;
    QString gkClientId;
    QString ps3GkClientId;
    QString streamServerClientId;
    QString gkCloudAuthCode;
    QString ps3AuthCode;
    QString streamServerAuthCode;
    QString selectedDatacenter;
    int selectedDatacenterPort;  // Port from step12 response (dynamic)
    QJsonObject selectedDatacenterPingResult;  // Store full ping result for selected datacenter (includes MTU values)
    QString duid;
    QJsonObject requestGameSpec;
    QJSValue finalCallback;
    
    // Helper to build request game specification (service/platform-specific)
    QJsonObject buildRequestGameSpec(QString entitlementId);
    
    // Helper to merge new ping results with existing datacenters in settings
    // Updates existing datacenters with new ping data, adds new ones, and keeps old ones that aren't in new results
    QJsonArray mergeDatacentersWithExisting(const QJsonArray &newPingResults);
    
    // Step 0: Get client IDs (MUST happen FIRST before step7)
    void step0_GetClientIds();
    
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
    
    // Allocation polling state
    QElapsedTimer allocationWaitTimer;
    int allocationMaxWaitSeconds; // Max wait time for current allocation attempt
    static const int MAX_ALLOCATION_WAIT_SECONDS = 900; // 15 minutes (max)
    static const int DEFAULT_ALLOCATION_WAIT_SECONDS = 300; // 5 minutes (fallback)
    
    // Retry counters
    int lockSessionRetryCount;
    int allocationRetryCount;
    static const int MAX_LOCK_SESSION_RETRIES = 12; // Max retries for lock session
    
    // Helper to extract and update session key from response
    void updateSessionKey(QNetworkReply *reply);
    
    // Debug logging helpers
    void logDebugRequest(const QString &stepName, const QNetworkRequest &request, const QByteArray &body = QByteArray());
    void logDebugResponse(const QString &stepName, QNetworkReply *reply);
};

#endif // PSGAIKAISTREAMING_H

