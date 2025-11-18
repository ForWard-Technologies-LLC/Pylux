// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreamingbackend.h"
#include "cloudstreaming/pskamajisession.h"
#include "cloudstreaming/psgaikaistreaming.h"
#include "chiaki/remote/holepunch.h"

#include <QObject>
#include <QDateTime>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// ============================================================================
// CONFIGURATION - Shared settings and values used by multiple classes
// ============================================================================
namespace CloudConfig {
    // Test values (will be passed as parameters when ready for production)
    static const QString TEST_NPSSO = "qg7lzIy8Rg3zYu7FPQ9WAhcrEP1zceCuhYdIqRLuxazz4s8V0CT78AS8NTXs0PhC";
    static const QString TEST_ENTITLEMENT_ID = "UP0082-CUSA16704_00-PSRSVD0000000000";
    
    // User preferences (will be settings later)
    static const int RESOLUTION = 1080;
    static const QString LANGUAGE = "en-US";
    static const QString TIMEZONE = "UTC-08:00";
    
    // Shared values (used by both Kamaji and Gaikai classes)
    static const QString ACCOUNT_BASE = "https://ca.account.sony.com/api";
    static const QString REDIRECT_URI = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html";
    static const QString USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo";
}

CloudStreamingBackend::CloudStreamingBackend(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
{
}

// ============================================================================
// MAIN ENTRY POINT - Single method to complete entire flow (Steps 1-13)
// ============================================================================

void CloudStreamingBackend::startCompleteCloudSession(const QJSValue &callback)
{
    qInfo() << "=== Starting Complete Cloud Streaming Session ===";
    qInfo() << "Using NPSSO:" << CloudConfig::TEST_NPSSO.left(20) << "...";
    qInfo() << "Game:" << CloudConfig::TEST_ENTITLEMENT_ID;
    
    // Generate DUID once - shared between Kamaji and Gaikai
    size_t duid_size = CHIAKI_DUID_STR_SIZE;
    char duid_arr[duid_size];
    chiaki_holepunch_generate_client_device_uid(duid_arr, &duid_size);
    QString sharedDuid = QString(duid_arr);
    qInfo() << "Generated DUID:" << sharedDuid;
    
    // Create Kamaji session handler (Steps 1-6)
    // Pass only shared config values - Kamaji has its own class-specific constants
    PSKamajiSession *kamajiSession = new PSKamajiSession(
        settings,
        CloudConfig::TEST_NPSSO,
        sharedDuid,
        CloudConfig::ACCOUNT_BASE,
        CloudConfig::REDIRECT_URI,
        CloudConfig::USER_AGENT,
        this
    );
    
    // When Kamaji completes, continue to Gaikai allocation
    connect(kamajiSession, &PSKamajiSession::sessionComplete, this, 
            [this, kamajiSession, callback, sharedDuid](bool success, QString message) {
        if (!success) {
            qWarning() << "Kamaji session creation failed:" << message;
            if (callback.isCallable()) {
                callback.call({false, QString("Session creation failed: %1").arg(message)});
            }
            kamajiSession->deleteLater();
            return;
        }
        
        qInfo() << "=== Kamaji Session Created, Starting Allocation ===";
        
        // Step 7-13: Complete Gaikai allocation with Kamaji's cookie jar and shared DUID
        PSGaikaiStreaming *gaikaiStreaming = new PSGaikaiStreaming(
            settings,
            CloudConfig::TEST_NPSSO,
            sharedDuid,
            kamajiSession->getCookieJar(),
            CloudConfig::ACCOUNT_BASE,
            CloudConfig::REDIRECT_URI,
            CloudConfig::USER_AGENT,
            this
        );
        
        // When Gaikai completes successfully
        connect(gaikaiStreaming, &PSGaikaiStreaming::AllocationComplete, this,
                [this, gaikaiStreaming, kamajiSession, callback](QString serverIp, int serverPort, QString handshakeKey, QString launchSpec, QString sessionId) {
            qInfo() << "=== COMPLETE CLOUD SESSION SUCCESS ===";
            qInfo() << "Ready to connect to streaming server:";
            qInfo() << "  IP:" << serverIp;
            qInfo() << "  Port:" << serverPort;
            
            if (callback.isCallable()) {
                callback.call({
                    true, 
                    "Cloud session ready",
                    serverIp
                });
            }
            
            // Clean up
            gaikaiStreaming->deleteLater();
            kamajiSession->deleteLater();
        });
        
        // When Gaikai allocation fails
        connect(gaikaiStreaming, &PSGaikaiStreaming::AllocationError, this,
                [this, gaikaiStreaming, kamajiSession, callback](QString error) {
            qWarning() << "Gaikai allocation failed:" << error;
            if (callback.isCallable()) {
                callback.call({false, QString("Allocation failed: %1").arg(error)});
            }
            gaikaiStreaming->deleteLater();
            kamajiSession->deleteLater();
        });
        
        // Start Gaikai allocation with test entitlement
        gaikaiStreaming->StartAllocationFlow(CloudConfig::TEST_ENTITLEMENT_ID, QJSValue());
    });
    
    // Start the Kamaji authentication flow
    kamajiSession->startSessionCreation();
}

