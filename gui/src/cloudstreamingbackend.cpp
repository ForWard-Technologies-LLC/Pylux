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
    static const QString TEST_ENTITLEMENT_ID = "UP9000-CUSA02320_00-PSRSVD0000000000";
    
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
                CHIAKI_TARGET_PS5_1, // Cloud streaming uses PS5 target
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
            
            // Cloud Play uses H.264 (confirmed from official app Frida logs)
            // The server sends codec=3 in packets, but we normalize to H.264 (0)
            // We also need to set it here so the video decoder initializes with H.264
            connect_info.video_profile.codec = CHIAKI_CODEC_H264;
            qInfo() << "Cloud Play: Forcing initial codec to H.264 for decoder initialization";
            
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

