// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreamingbackend.h"
#include "cloudstreaming/pskamajisession.h"
#include "cloudstreaming/psgaikaistreaming.h"
#include "streamsession.h"
#include "exception.h"
#include "chiaki/remote/holepunch.h"
#include "chiaki/session.h"
#include "qmlbackend.h"
#include "cloudcatalogbackend.h"

#include <QObject>
#include <QDateTime>
#include <QLoggingCategory>
#include <QSet>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonObject>
#include <QJsonDocument>
#include <QUrlQuery>
#include <functional>

extern "C" {
#include <libavcodec/avcodec.h>
}

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

CloudStreamingBackend::CloudStreamingBackend(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
    , allocation_progress("")
    , authManager(new QNetworkAccessManager(this))
{
}

// ============================================================================
// MAIN ENTRY POINT - Single method to complete entire flow (Steps 1-13)
// ============================================================================

void CloudStreamingBackend::startCompleteCloudSession(QString serviceType, QString gameIdentifier, const QJSValue &callback)
{
    qInfo() << "=== Starting Complete Cloud Streaming Session ===";
    qInfo() << "Service Type:" << serviceType;
    qInfo() << "Game Identifier:" << gameIdentifier;
    
    // Get NPSSO token from settings
    QString npssoToken = settings->GetNpssoToken();
    if (npssoToken.isEmpty()) {
        qWarning() << "NPSSO token is empty - cloud play may not work";
    } else {
        qInfo() << "Using NPSSO:" << npssoToken.left(20) << "...";
    }
    
    // Normalize service type to lowercase
    serviceType = serviceType.toLower();
    
    // Validate parameters
    if (serviceType != "psnow" && serviceType != "pscloud") {
        qWarning() << "Invalid serviceType:" << serviceType << "Must be 'psnow' or 'pscloud'";
        if (callback.isCallable()) {
            callback.call({false, QString("Invalid serviceType: %1").arg(serviceType)});
        }
        return;
    }
    
    // Lookup game image from cache before starting session
    QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
    if (qmlBackend && qmlBackend->cloudCatalog()) {
        QString imageUrl = qmlBackend->cloudCatalog()->getGameLandscapeImageFromCache(serviceType, gameIdentifier);
        if (!imageUrl.isEmpty()) {
            qInfo() << "Found game landscape image for" << gameIdentifier << ":" << imageUrl;
            setGameImageUrl(imageUrl);
        } else {
            qInfo() << "No game image found in cache for" << gameIdentifier;
            setGameImageUrl(QString()); // Clear any previous image
        }
    } else {
        qWarning() << "Could not access CloudCatalogBackend for image lookup";
        setGameImageUrl(QString()); // Clear any previous image
    }
    
    // Generate DUID once - shared between authorization check and session creation
    size_t duid_size = CHIAKI_DUID_STR_SIZE;
    char duid_arr[duid_size];
    chiaki_holepunch_generate_client_device_uid(duid_arr, &duid_size);
    QString sharedDuid = QString(duid_arr);
    
    // Centralized authorization check for both PSNOW and PSCLOUD
    checkAuthorization(serviceType, npssoToken, sharedDuid, [this, serviceType, gameIdentifier, callback, npssoToken, sharedDuid](bool success) {
        if (!success) {
            // Authorization failed - set flag to show dialog (following ping timeout pattern)
            QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
            if (qmlBackend) {
                qmlBackend->setShowAuthorizationFailedDialog(true);
                // Also emit sessionError to trigger StreamView error handling and return to main menu
                emit qmlBackend->sessionError(tr("Authentication Required"), 
                                             tr("Your NPSSO token is likely expired. Please re-login to continue using cloud streaming."));
            }
            
            // Clear game image on authorization failure
            setGameImageUrl(QString());
            
            if (callback.isCallable()) {
                callback.call({false, "Authorization check failed"});
            }
            return;
        }
        
        // Authorization successful - continue with cloud session setup
        continueCloudSessionAfterAuth(serviceType, gameIdentifier, callback, npssoToken, sharedDuid);
    });
}

void CloudStreamingBackend::continueCloudSessionAfterAuth(QString serviceType, QString gameIdentifier, const QJSValue &callback, QString npssoToken, QString sharedDuid)
{
    // Determine service-specific configuration
    QString redirectUri;
    QString userAgent;
    QString oauthApiPath;
    
    if (serviceType == "pscloud") {
        redirectUri = GaikaiConsts::REDIRECT_URI;
        userAgent = GaikaiConsts::USER_AGENT;
        oauthApiPath = "/authz/v3";  // ACCOUNT_BASE already includes /api
    } else { // psnow
        redirectUri = KamajiConsts::REDIRECT_URI;
        userAgent = KamajiConsts::USER_AGENT;
        oauthApiPath = "/v1";  // ACCOUNT_BASE already includes /api
    }
    
    // Determine ChiakiTarget (device/console type used by Chiaki core).
    // PSCLOUD should be treated as PS5.
    // PSNOW target will be determined after platform is detected from API response.
    ChiakiTarget target;
    if (serviceType == "pscloud") {
        target = CHIAKI_TARGET_PS5_1;
    } else { // psnow - will be updated based on detected platform
        target = CHIAKI_TARGET_PS4_9; // Default, will be updated if PS3 is detected
    }
    
    qInfo() << "Using DUID:" << sharedDuid;
    qInfo() << "Determined ChiakiTarget:" << target;
    
    // For PSNOW: Create Kamaji session handler (Steps 0.5a-0.5d)
    // For PSCLOUD: Skip Kamaji entirely
    PSKamajiSession *kamajiSession = nullptr;
    QString finalEntitlementId = gameIdentifier;
    
    if (serviceType == "psnow") {
        qInfo() << "=== PSNOW Flow: Starting Kamaji Session ===";
        // Create Kamaji session with productId (will be converted to entitlementId)
        // Platform will be automatically detected from the API response
        kamajiSession = new PSKamajiSession(
            settings,
            sharedDuid,
            gameIdentifier, // productId for PSNOW
            CloudConfig::ACCOUNT_BASE,
            redirectUri,
            userAgent,
            this
        );
        
        // When Kamaji completes, continue to Gaikai allocation
        // Connect PS Plus subscription error signal
        connect(kamajiSession, &PSKamajiSession::psPlusSubscriptionError, this, [this]() {
            QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
            if (qmlBackend) {
                qmlBackend->setShowPSPlusSubscriptionDialog(true);
            }
        });
        
        connect(kamajiSession, &PSKamajiSession::sessionComplete, this, 
                [this, kamajiSession, callback, sharedDuid, serviceType, gameIdentifier, target, redirectUri, userAgent, oauthApiPath](bool success, QString message, QString entitlementId) {
            if (!success) {
                qWarning() << "Kamaji session creation failed:" << message;
                
                // Clear game image on error
                setGameImageUrl(QString());
                
                // Emit sessionError to dismiss loading screen
                QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
                if (qmlBackend) {
                    emit qmlBackend->sessionError(tr("Cloud Streaming Failed"), 
                                                 QString("Session creation failed: %1").arg(message));
                }
                
                if (callback.isCallable()) {
                    callback.call({false, QString("Session creation failed: %1").arg(message)});
                }
                kamajiSession->deleteLater();
                return;
            }
            
            qInfo() << "=== Kamaji Session Created, Starting Allocation ===";
            qInfo() << "Converted Entitlement ID:" << entitlementId;
            
            // Get platform from Kamaji session (detected from API response)
            QString detectedPlatform = kamajiSession->getPlatform();
            qInfo() << "Detected platform from Kamaji session:" << detectedPlatform;
            
            // Update target based on detected platform
            ChiakiTarget platformTarget = target;
            if (detectedPlatform == "ps3") {
                platformTarget = CHIAKI_TARGET_PS4_9; // PS3 games use PS4 target for streaming
            } else {
                platformTarget = CHIAKI_TARGET_PS4_9; // PS4 games use PS4 target
            }
            
            // Continue to Gaikai allocation with converted entitlementId
            startGaikaiAllocation(serviceType, detectedPlatform, entitlementId, sharedDuid,
                                  redirectUri, userAgent, oauthApiPath, platformTarget, callback, kamajiSession);
        });
        
        // Start the Kamaji authentication flow
        kamajiSession->startSessionCreation();
    } else {
        // PSCLOUD: Skip Kamaji, start directly with Gaikai
        // PSCLOUD always uses PS5 platform
        QString ps5Platform = "ps5";
        qInfo() << "=== PSCLOUD Flow: Skipping Kamaji, Starting Gaikai Directly ===";
        qInfo() << "Using PS5 platform for PSCLOUD";
        startGaikaiAllocation(serviceType, ps5Platform, finalEntitlementId, sharedDuid,
                              redirectUri, userAgent, oauthApiPath, target, callback, nullptr);
    }
}

void CloudStreamingBackend::startGaikaiAllocation(QString serviceType, QString platform, QString entitlementId, 
                                                   QString duid,
                                                   QString redirectUri, QString userAgent, QString oauthApiPath,
                                                   ChiakiTarget target, const QJSValue &callback, QObject *kamajiSession)
{
    // Step 7-13: Complete Gaikai allocation
    PSGaikaiStreaming *gaikaiStreaming = new PSGaikaiStreaming(
        settings,
        duid,
        serviceType,
        platform,
        this
    );
    
    // Connect progress updates - update our property which QML can bind to
    connect(gaikaiStreaming, &PSGaikaiStreaming::AllocationProgress, this,
            &CloudStreamingBackend::onAllocationProgress);
    
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
        
        // Read window type from settings (same as remote play)
        bool fullscreen = false, zoom = false, stretch = false;
        switch (settings->GetWindowType()) {
        case WindowType::SelectedResolution:
            break;
        case WindowType::CustomResolution:
            break;
        case WindowType::AdjustableResolution:
            break;
        case WindowType::Fullscreen:
            fullscreen = true;
            break;
        case WindowType::Zoom:
            zoom = true;
            break;
        case WindowType::Stretch:
            stretch = true;
            break;
        default:
            break;
        }
        
        // Create StreamSessionConnectInfo with cloud parameters
        // Pass host as "IP:PORT" format - StreamSession will extract port for cloud mode
        StreamSessionConnectInfo connect_info(
            settings,
            target, // PSCLOUD->PS5 target, PSNOW->PS4 target
            QString("%1:%2").arg(serverIp).arg(serverPort), // host:port (will be split in StreamSession)
            QString(), // nickname
            QByteArray(), // regist_key (not used for cloud)
            QByteArray(), // morning (not used for cloud)
            QString(), // initial_login_pin
            QString(), // duid (not used for cloud, direct connection)
            false, // auto_regist
            fullscreen, // fullscreen (from settings)
            zoom, // zoom (from settings)
            stretch  // stretch (from settings)
        );
        
        // Set service type for cloud streaming BEFORE any validation
        connect_info.cloud_launch_spec = launchSpec;
        connect_info.cloud_handshake_key = handshakeKey;
        connect_info.cloud_session_id = sessionId;
        if (serviceType == "pscloud") {
            connect_info.service_type = CHIAKI_SERVICE_TYPE_PSCLOUD;
        } else if (serviceType == "psnow") {
            connect_info.service_type = CHIAKI_SERVICE_TYPE_PSNOW;
        } else {
            connect_info.service_type = CHIAKI_SERVICE_TYPE_REMOTE_PLAY;
        }
        connect_info.cloud_psn_wrapper_type = gaikaiStreaming->getPsnWrapperType();
        
        // Extract MTU values from ping results
        QJsonObject pingResult = gaikaiStreaming->getSelectedDatacenterPingResult();
        if (!pingResult.isEmpty()) {
            connect_info.cloud_mtu_in = pingResult["mtu_in"].toInt(0);
            connect_info.cloud_mtu_out = pingResult["mtu_out"].toInt(0);
            int rtt_ms = pingResult["rtt"].toInt(0);
            connect_info.cloud_rtt_us = rtt_ms > 0 ? (uint64_t)rtt_ms * 1000 : 0;
            qInfo() << "Cloud mode: Using MTU values from ping results - mtu_in:" << connect_info.cloud_mtu_in
                    << ", mtu_out:" << connect_info.cloud_mtu_out << ", rtt:" << rtt_ms << "ms";
        } else {
            connect_info.cloud_mtu_in = 0;
            connect_info.cloud_mtu_out = 0;
            connect_info.cloud_rtt_us = 0;
            qWarning() << "Cloud mode: No ping results available, will use default MTU values";
        }
        
        // Set codec based on service type:
        // - PSCLOUD: H.265/HEVC
        // - PSNOW: H.264
        // This must match what the server sends and what the decoder is initialized with.
        if (connect_info.service_type == CHIAKI_SERVICE_TYPE_PSCLOUD) {
            connect_info.video_profile.codec = CHIAKI_CODEC_H265;
            qInfo() << "Cloud Play (PSCLOUD): Setting codec to H.265/HEVC for decoder initialization";
        } else {
            connect_info.video_profile.codec = CHIAKI_CODEC_H264;
            qInfo() << "Cloud Play (PSNOW): Setting codec to H.264 for decoder initialization";
        }
        
        qInfo() << "Cloud streaming parameters set:";
        qInfo() << "  service_type:" << chiaki_service_type_string(connect_info.service_type);
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
            
            // Clear progress message since allocation is complete
            setAllocationProgress("");
        if (queue_position != -1) {
            queue_position = -1;
            emit queuePositionChanged();
        }
            
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
            setGameImageUrl(QString()); // Clear image on error
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
    
    // Connect dialog error signals
    connect(gaikaiStreaming, &PSGaikaiStreaming::psPlusSubscriptionError, this, [this]() {
        QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
        if (qmlBackend) {
            qmlBackend->setShowPSPlusSubscriptionDialog(true);
        }
    });
    
    connect(gaikaiStreaming, &PSGaikaiStreaming::pingTimeoutError, this, [this]() {
        QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
        if (qmlBackend) {
            qmlBackend->setShowPingTimeoutDialog(true);
        }
    });
    
    // When Gaikai allocation fails
    connect(gaikaiStreaming, &PSGaikaiStreaming::AllocationError, this,
            [this, gaikaiStreaming, kamajiSession, callback](QString error) {
        qWarning() << "Gaikai allocation failed:" << error;
        
        // Clear game image on error
        setGameImageUrl(QString());
        
        // Emit sessionError to dismiss loading screen
        QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
        if (qmlBackend) {
            emit qmlBackend->sessionError(tr("Cloud Streaming Failed"), 
                                         QString("Allocation failed: %1").arg(error));
        }
        
        if (callback.isCallable()) {
            callback.call({false, QString("Allocation failed: %1").arg(error)});
        }
        gaikaiStreaming->deleteLater();
        if (kamajiSession) {
            kamajiSession->deleteLater();
        }
        
        // Clear progress message on error
        setAllocationProgress("");
        if (queue_position != -1) {
            queue_position = -1;
            emit queuePositionChanged();
        }
    });
    
    // Start Gaikai allocation with entitlement ID
    gaikaiStreaming->StartAllocationFlow(entitlementId, QJSValue());
}

void CloudStreamingBackend::onAllocationProgress(QString message, int queuePosition)
{
    setAllocationProgress(message);
    if (queue_position != queuePosition) {
        queue_position = queuePosition;
        emit queuePositionChanged();
    }
}


void CloudStreamingBackend::setAllocationProgress(const QString &message)
{
    if (allocation_progress != message) {
        allocation_progress = message;
        emit allocationProgressChanged();
    }
}

void CloudStreamingBackend::setGameImageUrl(const QString &url)
{
    if (game_image_url != url) {
        game_image_url = url;
        emit gameImageUrlChanged();
    }
}

// ============================================================================
// Centralized Authorization Check (used by both PSNOW and PSCLOUD)
// ============================================================================
void CloudStreamingBackend::checkAuthorization(QString serviceType, QString npssoToken, QString duid, std::function<void(bool)> callback)
{
    if (npssoToken.isEmpty()) {
        qWarning() << "Authorization check: NPSSO token is empty";
        callback(false);
        return;
    }
    
    // Determine configuration based on service type
    QString kamajiClientId;
    QString scopesStr;
    QString redirectUri;
    QString userAgent;
    
    if (serviceType == "psnow") {
        // PSNOW configuration (matching PSKamajiSession)
        kamajiClientId = KamajiConsts::CLIENT_ID;
        scopesStr = KamajiConsts::PS4_SCOPES;
        redirectUri = KamajiConsts::REDIRECT_URI;
        userAgent = KamajiConsts::USER_AGENT;
    } else { // pscloud
        // PSCLOUD configuration
        kamajiClientId = "19ae39c4-3f88-4d11-a792-94e4f52c996d";
        scopesStr = "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s";
        redirectUri = GaikaiConsts::REDIRECT_URI;
        userAgent = GaikaiConsts::USER_AGENT;
    }
    
    // Disable cookie jar on auth manager - we use manual Cookie headers only
    authManager->setCookieJar(nullptr);
    
    // Create authorization check request (matching PSKamajiSession::step0_5a_AuthorizeCheck)
    QString url = CloudConfig::ACCOUNT_BASE + "/authz/v3/oauth/authorizeCheck";
    
    QJsonObject body;
    body["client_id"] = kamajiClientId;
    body["scope"] = scopesStr;
    body["redirect_uri"] = redirectUri;
    body["response_type"] = "code";
    body["service_entity"] = "urn:service-entity:psn";
    body["duid"] = duid;
    
    QNetworkRequest req{QUrl(url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json; charset=UTF-8");
    req.setRawHeader("User-Agent", userAgent.toUtf8());
    // Set npsso cookie manually
    if (!npssoToken.isEmpty()) {
        req.setRawHeader("Cookie", QString("npsso=%1").arg(npssoToken).toUtf8());
    }
    
    qInfo() << "=== Centralized Authorization Check ===";
    qInfo() << "Service Type:" << serviceType;
    qInfo() << "URL:" << url;
    
    QNetworkReply *reply = authManager->post(req, QJsonDocument(body).toJson());
    
    connect(reply, &QNetworkReply::finished, this, [reply, callback, serviceType]() {
        bool success = false;
        
        // Match PSKamajiSession::handleAuthorizeCheckResponse logic
        if (reply->error() == QNetworkReply::NoError) {
            success = true;
            qInfo() << "Authorization check: SUCCESS for" << serviceType;
        } else {
            qWarning() << "Authorization check failed for" << serviceType << ":" << reply->errorString();
        }
        
        reply->deleteLater();
        callback(success);
    });
}

