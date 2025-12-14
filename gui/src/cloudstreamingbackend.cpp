// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreamingbackend.h"
#include "cloudstreaming/pskamajisession.h"
#include "cloudstreaming/psgaikaistreaming.h"
#include "streamsession.h"
#include "exception.h"
#include "chiaki/remote/holepunch.h"
#include "chiaki/session.h"

#include <QObject>
#include <QDateTime>
#include <QLoggingCategory>
#include <QSet>

extern "C" {
#include <libavcodec/avcodec.h>
}

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// ============================================================================
// CONFIGURATION - Shared settings and values used by multiple classes
// ============================================================================
namespace CloudConfig {
    // Test values (will be passed as parameters when ready for production)
    static const QString TEST_NPSSO = "3CQAgA4utomnErZT2wNQVylUSqF2wqXjrKGnTKOrYBMrvQdbb4LBY0RXacRZmQ1w";
    
    // User preferences (configurable at top of file for now)
    // Resolution: 720 or 1080 (integer value for resolutionSetting field)
    static const int RESOLUTION = 1080;
    static const QString LANGUAGE = "en-US";
    static const QString TIMEZONE = "UTC-08:00";
    
    // Shared base values
    static const QString ACCOUNT_BASE = "https://ca.account.sony.com/api";
    
    // Service-specific constants
    static const QString PSNOW_REDIRECT_URI = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html";
    static const QString PSNOW_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo";
    
    static const QString PSCLOUD_REDIRECT_URI = "gaikai://local";
    static const QString PSCLOUD_USER_AGENT = "PlayStation Portal/6.0.0-rel.444+6a9cea6f5";
}

CloudStreamingBackend::CloudStreamingBackend(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
{
}

// ============================================================================
// MAIN ENTRY POINT - Single method to complete entire flow (Steps 1-13)
// ============================================================================

void CloudStreamingBackend::startCompleteCloudSession(QString serviceType, QString platform, QString gameIdentifier, const QJSValue &callback)
{
    qInfo() << "=== Starting Complete Cloud Streaming Session ===";
    qInfo() << "Service Type:" << serviceType;
    qInfo() << "Platform:" << platform;
    qInfo() << "Game Identifier:" << gameIdentifier;
    qInfo() << "Using NPSSO:" << CloudConfig::TEST_NPSSO.left(20) << "...";
    
    // Normalize service type and platform to lowercase
    serviceType = serviceType.toLower();
    platform = platform.toLower();
    
    // Validate parameters
    if (serviceType != "psnow" && serviceType != "pscloud") {
        qWarning() << "Invalid serviceType:" << serviceType << "Must be 'psnow' or 'pscloud'";
        if (callback.isCallable()) {
            callback.call({false, QString("Invalid serviceType: %1").arg(serviceType)});
        }
        return;
    }
    
    if (platform != "ps3" && platform != "ps4" && platform != "ps5") {
        qWarning() << "Invalid platform:" << platform << "Must be 'ps3', 'ps4', or 'ps5'";
        if (callback.isCallable()) {
            callback.call({false, QString("Invalid platform: %1").arg(platform)});
        }
        return;
    }
    
    // Validate service/platform combination
    if (serviceType == "pscloud" && platform != "ps5") {
        qWarning() << "PSCLOUD only supports PS5 platform";
        if (callback.isCallable()) {
            callback.call({false, "PSCLOUD only supports PS5 platform"});
        }
        return;
    }
    
    if (serviceType == "psnow" && platform == "ps5") {
        qWarning() << "PSNOW does not support PS5 platform";
        if (callback.isCallable()) {
            callback.call({false, "PSNOW does not support PS5 platform"});
        }
        return;
    }
    
    // Determine service-specific configuration
    QString redirectUri;
    QString userAgent;
    QString oauthApiPath;
    
    if (serviceType == "pscloud") {
        redirectUri = CloudConfig::PSCLOUD_REDIRECT_URI;
        userAgent = CloudConfig::PSCLOUD_USER_AGENT;
        oauthApiPath = "/authz/v3";  // ACCOUNT_BASE already includes /api
    } else { // psnow
        redirectUri = CloudConfig::PSNOW_REDIRECT_URI;
        userAgent = CloudConfig::PSNOW_USER_AGENT;
        oauthApiPath = "/v1";  // ACCOUNT_BASE already includes /api
    }
    
    // Determine ChiakiTarget based on service+platform
    ChiakiTarget target;
    if (serviceType == "pscloud") {
        target = CHIAKI_TARGET_PS5_1;
    } else { // psnow
        // PSNOW uses PS4 target (protocol v9)
        target = CHIAKI_TARGET_PS4_9;
    }
    
    // Generate DUID once - shared between Kamaji and Gaikai
    size_t duid_size = CHIAKI_DUID_STR_SIZE;
    char duid_arr[duid_size];
    chiaki_holepunch_generate_client_device_uid(duid_arr, &duid_size);
    QString sharedDuid = QString(duid_arr);
    qInfo() << "Generated DUID:" << sharedDuid;
    qInfo() << "Determined ChiakiTarget:" << target;
    
    // For PSNOW: Create Kamaji session handler (Steps 0.5a-0.5d)
    // For PSCLOUD: Skip Kamaji entirely
    PSKamajiSession *kamajiSession = nullptr;
    QString finalEntitlementId = gameIdentifier;
    
    if (serviceType == "psnow") {
        qInfo() << "=== PSNOW Flow: Starting Kamaji Session ===";
        // Create Kamaji session with productId (will be converted to entitlementId)
        kamajiSession = new PSKamajiSession(
            settings,
            CloudConfig::TEST_NPSSO,
            sharedDuid,
            platform,
            gameIdentifier, // productId for PSNOW
            CloudConfig::ACCOUNT_BASE,
            redirectUri,
            userAgent,
            this
        );
        
        // When Kamaji completes, continue to Gaikai allocation
        connect(kamajiSession, &PSKamajiSession::sessionComplete, this, 
                [this, kamajiSession, callback, sharedDuid, serviceType, platform, gameIdentifier, target, redirectUri, userAgent, oauthApiPath](bool success, QString message, QString entitlementId) {
            if (!success) {
                qWarning() << "Kamaji session creation failed:" << message;
                if (callback.isCallable()) {
                    callback.call({false, QString("Session creation failed: %1").arg(message)});
                }
                kamajiSession->deleteLater();
                return;
            }
            
            qInfo() << "=== Kamaji Session Created, Starting Allocation ===";
            qInfo() << "Converted Entitlement ID:" << entitlementId;
            
            // Continue to Gaikai allocation with converted entitlementId
            startGaikaiAllocation(serviceType, platform, entitlementId, sharedDuid, kamajiSession->getCookieJar(), 
                                  redirectUri, userAgent, oauthApiPath, target, callback, kamajiSession);
        });
        
        // Start the Kamaji authentication flow
        kamajiSession->startSessionCreation();
    } else {
        // PSCLOUD: Skip Kamaji, start directly with Gaikai
        qInfo() << "=== PSCLOUD Flow: Skipping Kamaji, Starting Gaikai Directly ===";
        startGaikaiAllocation(serviceType, platform, finalEntitlementId, sharedDuid, nullptr,
                              redirectUri, userAgent, oauthApiPath, target, callback, nullptr);
    }
}

void CloudStreamingBackend::startGaikaiAllocation(QString serviceType, QString platform, QString entitlementId, 
                                                   QString duid, QNetworkCookieJar *cookieJar,
                                                   QString redirectUri, QString userAgent, QString oauthApiPath,
                                                   ChiakiTarget target, const QJSValue &callback, QObject *kamajiSession)
{
    // Create cookie jar if not provided (for PSCLOUD)
    QNetworkCookieJar *gaikaiCookieJar = cookieJar;
    if (!gaikaiCookieJar) {
        gaikaiCookieJar = new QNetworkCookieJar(this);
    }
    
    // Step 7-13: Complete Gaikai allocation
    PSGaikaiStreaming *gaikaiStreaming = new PSGaikaiStreaming(
        settings,
        CloudConfig::TEST_NPSSO,
        duid,
        serviceType,
        platform,
        gaikaiCookieJar,
        CloudConfig::ACCOUNT_BASE,
        redirectUri,
        userAgent,
        oauthApiPath,
        this
    );
    
    // When Gaikai completes successfully
    connect(gaikaiStreaming, &PSGaikaiStreaming::AllocationComplete, this,
            [this, gaikaiStreaming, kamajiSession, callback, target, serviceType](QString serverIp, int serverPort, QString handshakeKey, QString launchSpec, QString sessionId) {
        qInfo() << "=== COMPLETE CLOUD SESSION SUCCESS ===";
        qInfo() << "Ready to connect to streaming server:";
        qInfo() << "  IP:" << serverIp;
        qInfo() << "  Port:" << serverPort;
        qInfo() << "  Session ID:" << sessionId;
        
        qInfo() << "Creating StreamSessionConnectInfo for cloud streaming";
        qInfo() << "  Server IP:" << serverIp;
        qInfo() << "  Server Port:" << serverPort;
        qInfo() << "  Session ID length:" << sessionId.length();
        qInfo() << "  Handshake key length:" << handshakeKey.length();
        qInfo() << "  Launch spec length:" << launchSpec.length();
        
        // Create StreamSessionConnectInfo with cloud parameters
        // Pass host as "IP:PORT" format - StreamSession will extract port for cloud mode
        StreamSessionConnectInfo connect_info(
            settings,
            target, // Use determined target (PS5 for PSCLOUD, PS4 for PSNOW)
            QString("%1:%2").arg(serverIp).arg(serverPort), // host:port (will be split in StreamSession)
            QString(), // nickname
            QByteArray(), // regist_key (not used for cloud)
            QByteArray(), // morning (not used for cloud)
            QString(), // initial_login_pin
            QString(), // duid (not used for cloud, direct connection)
            false, // auto_regist
            false, // fullscreen
            false, // zoom
            false  // stretch
        );
        
        // Set cloud mode parameters BEFORE any validation
        connect_info.cloud_mode = true;
        connect_info.cloud_launch_spec = launchSpec;
        connect_info.cloud_handshake_key = handshakeKey;
        connect_info.cloud_session_id = sessionId;
        connect_info.cloud_psn_wrapper_type = gaikaiStreaming->getPsnWrapperType();
        
        // Set codec based on target (service type):
        // - PSCLOUD (PS5): Uses H.265/HEVC (as configured in videoStreamSettings: "hevc_hw4")
        // - PSNOW (PS3/PS4): Uses H.264 (server only supports H.264 for PSNOW)
        // This must match what the server sends and what the decoder is initialized with
        if (chiaki_target_is_ps5(target)) {
            connect_info.video_profile.codec = CHIAKI_CODEC_H265;
            qInfo() << "Cloud Play (PSCLOUD/PS5): Setting codec to H.265/HEVC for decoder initialization";
        } else {
            connect_info.video_profile.codec = CHIAKI_CODEC_H264;
            qInfo() << "Cloud Play (PSNOW/PS3/PS4): Setting codec to H.264 for decoder initialization";
        }
        
        qInfo() << "Cloud mode parameters set:";
        qInfo() << "  cloud_mode:" << connect_info.cloud_mode;
        qInfo() << "  cloud_session_id set:" << !connect_info.cloud_session_id.isEmpty();
        qInfo() << "  cloud_handshake_key set:" << !connect_info.cloud_handshake_key.isEmpty();
        qInfo() << "  cloud_launch_spec set:" << !connect_info.cloud_launch_spec.isEmpty();
        qInfo() << "  cloud_psn_wrapper_type:" << QString("0x%1").arg(connect_info.cloud_psn_wrapper_type, 2, 16, QChar('0'));
        
        // Resolve "auto" hardware decoder to actual decoder
        if(connect_info.hw_decoder == "auto")
        {
            connect_info.hw_decoder = QString();
            // Auto-detect available hardware decoder
            static QSet<QString> allowed = {
                "vulkan",
#if defined(Q_OS_LINUX)
                "vaapi",
#elif defined(Q_OS_MACOS)
                "videotoolbox",
#elif defined(Q_OS_WIN)
                "d3d11va",
#endif
            };
            
            enum AVHWDeviceType hw_dev = AV_HWDEVICE_TYPE_NONE;
            QStringList available;
            while (true) {
                hw_dev = av_hwdevice_iterate_types(hw_dev);
                if (hw_dev == AV_HWDEVICE_TYPE_NONE)
                    break;
                const QString name = QString::fromUtf8(av_hwdevice_get_type_name(hw_dev));
                if (allowed.contains(name))
                    available.append(name);
            }
            
            // Select decoder based on platform preferences
            if (available.contains("vulkan")) {
                connect_info.hw_decoder = "vulkan";
                qInfo() << "Auto-selected hardware decoder: vulkan";
            }
#if defined(Q_OS_LINUX)
            else if (available.contains("vaapi")) {
                connect_info.hw_decoder = "vaapi";
                qInfo() << "Auto-selected hardware decoder: vaapi";
            }
#elif defined(Q_OS_WIN)
            else if (available.contains("d3d11va")) {
                connect_info.hw_decoder = "d3d11va";
                qInfo() << "Auto-selected hardware decoder: d3d11va";
            }
#elif defined(Q_OS_MACOS)
            else if (available.contains("videotoolbox")) {
                connect_info.hw_decoder = "videotoolbox";
                qInfo() << "Auto-selected hardware decoder: videotoolbox";
            }
#endif
            else {
                qInfo() << "No hardware decoder available, using software decoding";
            }
        }
        
        // Create and start StreamSession
        qInfo() << "=== Creating StreamSession ===";
        try {
            qInfo() << "Instantiating StreamSession with cloud parameters...";
            // Create session with QmlBackend as parent so it can manage it
            StreamSession *session = new StreamSession(connect_info, parent());
            qInfo() << "StreamSession created successfully, emitting sessionCreated signal...";
            
            // Emit signal so QmlBackend can register the session
            emit sessionCreated(session);
            
            // Start the session
            session->Start();
            qInfo() << "StreamSession Start() called (connection is asynchronous)";
            
            // Success will be reported when the stream actually connects
            // For now, just indicate that we've initiated the connection
            if (callback.isCallable()) {
                callback.call({
                    true, 
                    "Cloud session connection initiated (waiting for server response...)",
                    serverIp
                });
            }
        } catch (const Exception &e) {
            qWarning() << "Failed to start cloud streaming session:" << e.what();
            if (callback.isCallable()) {
                callback.call({
                    false, 
                    QString("Failed to start session: %1").arg(e.what())
                });
            }
        }
        
        // Clean up
        gaikaiStreaming->deleteLater();
        if (kamajiSession) {
            kamajiSession->deleteLater();
        }
    });
    
    // When Gaikai allocation fails
    connect(gaikaiStreaming, &PSGaikaiStreaming::AllocationError, this,
            [this, gaikaiStreaming, kamajiSession, callback](QString error) {
        qWarning() << "Gaikai allocation failed:" << error;
        if (callback.isCallable()) {
            callback.call({false, QString("Allocation failed: %1").arg(error)});
        }
        gaikaiStreaming->deleteLater();
        if (kamajiSession) {
            kamajiSession->deleteLater();
        }
    });
    
    // Start Gaikai allocation with entitlement ID
    gaikaiStreaming->StartAllocationFlow(entitlementId, QJSValue());
}

