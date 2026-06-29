// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreamingbackend.h"
#include "cloudstreaming/pskamajisession.h"   // KamajiConsts (auth check)
#include "cloudstreaming/psgaikaistreaming.h" // GaikaiConsts (auth check)
#include "streamsession.h"
#include "exception.h"
#include "chiaki/remote/holepunch.h"
#include "chiaki/session.h"
#include "chiaki/cloudsession.h"
#include "chiaki/log.h"
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
#include <thread>
#include <cstring>

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

// Runs the unified C provisioning flow on a worker thread, then hands the
// stream-ready result back to the GUI thread. Kamaji + Gaikai + datacenter
// ping/select + the owned fast-path + the one-shot noGameForEntitlementId retry
// all live in libchiaki (chiaki_cloud_provision_session) now.
void CloudStreamingBackend::continueCloudSessionAfterAuth(QString serviceType, QString gameIdentifier, const QJSValue &callback, QString npssoToken, QString sharedDuid)
{
    const bool pscloud = (serviceType == "pscloud");

    // Snapshot everything the worker needs as owned byte arrays (must outlive the thread).
    const QByteArray svc = serviceType.toUtf8();
    const QByteArray gameId = gameIdentifier.toUtf8();
    const QByteArray npsso = npssoToken.toUtf8();
    const QByteArray storeCountry = settings->GetCloudResolvedStoreCountry().toUtf8();
    const QByteArray storeLang = settings->GetCloudResolvedStoreLang().toUtf8();
    // Streaming language: manual picker, else fall back to the auto-detected catalog
    // locale (matches psgaikaistreaming.cpp) so non-English regions don't silently get "en".
    QString gameLangStr = settings->GetCloudGameLanguage();
    if (gameLangStr.isEmpty())
        gameLangStr = settings->GetCloudStoreLocale();
    const QByteArray gameLang = gameLangStr.toUtf8();
    const QByteArray forcedDc = (pscloud ? settings->GetCloudDatacenterPSCloud()
                                         : settings->GetCloudDatacenterPSNOW()).toUtf8();
    const int resolution = pscloud ? settings->GetCloudResolutionPSCloud()
                                    : settings->GetCloudResolutionPSNOW();
    const int bitrate = static_cast<int>(pscloud ? settings->GetCloudBitratePSCloud()
                                                  : settings->GetCloudBitratePSNOW());
    const bool isForeign = settings->IsCloudCatalogIsForeign();
    const bool attrPassed = settings->GetAccountAttributesCheckPassed();

    // Owned-PSNOW fast-path: hand the catalog's resolved owned entitlement straight in so the
    // C flow skips the resolve/acquire path. (If Gaikai rejects it, the orchestrator retries
    // the full resolve flow once internally.)
    QByteArray ownedEnt, ownedPlat;
    if (!pscloud) {
        QmlBackend *qb = qobject_cast<QmlBackend*>(parent());
        QString e, p;
        if (qb && qb->cloudCatalog() && qb->cloudCatalog()->getOwnedPsnowEntitlement(gameIdentifier, e, p)) {
            qInfo() << "PSNOW owned fast-path: entitlementId=" << e << "platform=" << p;
            ownedEnt = e.toUtf8();
            ownedPlat = p.toUtf8();
        }
    }
    Q_UNUSED(sharedDuid); // the C flow generates its own shared DUID for Kamaji+Gaikai

    setAllocationProgress(tr("Starting cloud session..."));

    std::thread([this, callback, svc, gameId, npsso, storeCountry, storeLang, gameLang,
                 forcedDc, resolution, bitrate, isForeign, attrPassed, ownedEnt, ownedPlat]() mutable {
        ChiakiLog log;
        chiaki_log_init(&log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR,
                        chiaki_log_cb_print, nullptr);

        ChiakiCloudProvisionConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.service_type = svc.constData();
        cfg.game_identifier = gameId.constData();
        cfg.npsso = npsso.constData();
        cfg.store_country = storeCountry.constData();
        cfg.store_lang = storeLang.constData();
        cfg.game_language = gameLang.constData();
        cfg.owned_entitlement_id = ownedEnt.constData();
        cfg.owned_platform = ownedPlat.constData();
        cfg.catalog_is_foreign = isForeign;
        cfg.skip_account_attr_check = attrPassed;
        cfg.forced_datacenter = forcedDc.constData();
        cfg.cache_dir = "";
        cfg.resolution = resolution;
        cfg.bitrate_kbps = bitrate;
        cfg.progress = &CloudStreamingBackend::provisionProgressThunk;
        cfg.is_cancelled = nullptr;
        cfg.user = this;

        ChiakiCloudProvisionResult res;
        ChiakiErrorCode err = chiaki_cloud_provision_session(&cfg, &res, &log);

        const bool success = (err == CHIAKI_ERR_SUCCESS);
        const QString serviceTypeStr = QString::fromUtf8(svc);
        const QString serverIp = QString::fromUtf8(res.server_ip);
        const int serverPort = res.server_port;
        const QString handshakeKey = res.handshake_key ? QString::fromUtf8(res.handshake_key) : QString();
        const QString launchSpec = res.launch_spec ? QString::fromUtf8(res.launch_spec) : QString();
        const QString sessionId = res.session_id ? QString::fromUtf8(res.session_id) : QString();
        const uint8_t wrap = res.psn_wrapper_type;
        const uint32_t mtuIn = res.mtu_in, mtuOut = res.mtu_out;
        const quint64 rttUs = res.rtt_us;
        const QString errMsg = res.error_message ? QString::fromUtf8(res.error_message) : QString();
        chiaki_cloud_provision_result_fini(&res);

        QMetaObject::invokeMethod(this, [this, callback, success, serviceTypeStr, serverIp, serverPort,
                                         handshakeKey, launchSpec, sessionId, wrap, mtuIn, mtuOut, rttUs, errMsg]() mutable {
            if (success) {
                finishCloudSession(serviceTypeStr, serverIp, serverPort, handshakeKey, launchSpec,
                                   sessionId, wrap, mtuIn, mtuOut, rttUs, callback);
            } else {
                handleProvisionError(serviceTypeStr, errMsg, callback);
            }
        });
    }).detach();
}

// Build StreamSessionConnectInfo from the C result and start the StreamSession.
// This boundary (and everything below it) is unchanged from the previous flow --
// only the source of the parameters moved from PSGaikaiStreaming to the C result.
void CloudStreamingBackend::finishCloudSession(QString serviceType, QString serverIp, int serverPort,
                                               QString handshakeKey, QString launchSpec, QString sessionId,
                                               uint8_t psnWrapperType, uint32_t mtuIn, uint32_t mtuOut, uint64_t rttUs,
                                               const QJSValue &callback)
{
    qInfo() << "=== COMPLETE CLOUD SESSION SUCCESS ===";
    qInfo() << "  IP:" << serverIp << " Port:" << serverPort << " SessionId len:" << sessionId.length();
    qInfo() << "  handshake len:" << handshakeKey.length() << " launchSpec len:" << launchSpec.length();

    // PSCLOUD streams as PS5, PSNOW (PS3 + PS4) as PS4.
    const ChiakiTarget target = (serviceType == "pscloud") ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_9;

    // Read window type from settings (same as remote play)
    bool fullscreen = false, zoom = false, stretch = false;
    switch (settings->GetWindowType()) {
    case WindowType::SelectedResolution:
    case WindowType::CustomResolution:
    case WindowType::AdjustableResolution:
        break;
    case WindowType::Fullscreen: fullscreen = true; break;
    case WindowType::Zoom: zoom = true; break;
    case WindowType::Stretch: stretch = true; break;
    default: break;
    }

    // Pass host as "IP:PORT"; StreamSession extracts the port for cloud mode.
    StreamSessionConnectInfo connect_info(
        settings,
        target,
        QString("%1:%2").arg(serverIp).arg(serverPort),
        QString(),     // nickname
        QByteArray(),  // regist_key (not used for cloud)
        QByteArray(),  // morning (not used for cloud)
        QString(),     // initial_login_pin
        QString(),     // duid (not used for cloud, direct connection)
        false,         // auto_regist
        fullscreen, zoom, stretch);

    connect_info.cloud_launch_spec = launchSpec;
    connect_info.cloud_handshake_key = handshakeKey;
    connect_info.cloud_session_id = sessionId;
    if (serviceType == "pscloud")
        connect_info.service_type = CHIAKI_SERVICE_TYPE_PSCLOUD;
    else if (serviceType == "psnow")
        connect_info.service_type = CHIAKI_SERVICE_TYPE_PSNOW;
    else
        connect_info.service_type = CHIAKI_SERVICE_TYPE_REMOTE_PLAY;
    connect_info.cloud_psn_wrapper_type = psnWrapperType;
    connect_info.cloud_mtu_in = mtuIn;
    connect_info.cloud_mtu_out = mtuOut;
    connect_info.cloud_rtt_us = rttUs;
    connect_info.video_profile = settings->GetCloudVideoProfile(serviceType);

    qInfo() << "Cloud streaming parameters set:";
    qInfo() << "  service_type:" << chiaki_service_type_string(connect_info.service_type);
    qInfo() << "  cloud_psn_wrapper_type:" << QString("0x%1").arg(connect_info.cloud_psn_wrapper_type, 2, 16, QChar('0'));
    qInfo() << "  mtu_in:" << mtuIn << " mtu_out:" << mtuOut << " rtt_us:" << rttUs;

    // Resolve "auto" hardware decoder to an actual decoder.
    if (connect_info.hw_decoder == "auto") {
        connect_info.hw_decoder = QString();
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

    qInfo() << "=== Creating StreamSession ===";
    try {
        StreamSession *session = new StreamSession(connect_info, parent());
        emit sessionCreated(session);

        setAllocationProgress("");
        if (queue_position != -1) {
            queue_position = -1;
            emit queuePositionChanged();
        }

        session->Start();
        qInfo() << "StreamSession Start() called (connection is asynchronous)";

        if (callback.isCallable()) {
            callback.call({
                true,
                "Cloud session connection initiated (waiting for server response...)",
                serverIp
            });
        }
    } catch (const Exception &e) {
        qWarning() << "Failed to start cloud streaming session:" << e.what();
        setGameImageUrl(QString());
        if (callback.isCallable()) {
            callback.call({false, QString("Failed to start session: %1").arg(e.what())});
        }
    }
}

// Map the C error_message sentinels to the same dialogs the old flow raised.
void CloudStreamingBackend::handleProvisionError(QString serviceType, QString errorMessage, const QJSValue &callback)
{
    Q_UNUSED(serviceType);
    qWarning() << "Cloud provisioning failed:" << errorMessage;
    setGameImageUrl(QString());

    // Set the specific dialog (supplementary), then ALWAYS emit sessionError so the
    // stream/loading page dismisses and returns to the main menu -- the original
    // emitted both its special signal AND AllocationError/sessionComplete(false)
    // (which fired sessionError). Without the sessionError the page never exits and
    // the dialog just toasts on the streaming page.
    QString userMessage;
    QmlBackend *qmlBackend = qobject_cast<QmlBackend*>(parent());
    if (errorMessage.contains(QStringLiteral("PS_PLUS_SUBSCRIPTION_REQUIRED"))) {
        if (qmlBackend) qmlBackend->setShowPSPlusSubscriptionDialog(true);
        userMessage = tr("PS Plus subscription required");
    } else if (errorMessage.contains(QStringLiteral("ACCOUNT_PRIVACY_SETTINGS"))) {
        if (qmlBackend) {
            qmlBackend->setAccountPrivacyUpgradeUrl(QString());
            qmlBackend->setShowAccountPrivacySettingsDialog(true);
        }
        userMessage = tr("Account privacy settings need updating");
    } else if (errorMessage.contains(QStringLiteral("PING_TIMEOUT"))) {
        if (qmlBackend) qmlBackend->setShowPingTimeoutDialog(true);
        userMessage = tr("Ping must be < 80ms to start a cloud session");
    } else {
        userMessage = errorMessage.isEmpty() ? tr("Allocation failed")
                                             : QString("Allocation failed: %1").arg(errorMessage);
    }

    if (qmlBackend) {
        emit qmlBackend->sessionError(tr("Cloud Streaming Failed"), userMessage);
    }

    if (callback.isCallable()) {
        callback.call({false, userMessage});
    }

    setAllocationProgress("");
    if (queue_position != -1) {
        queue_position = -1;
        emit queuePositionChanged();
    }
}

// C progress callback -- runs on the worker thread; marshal to the GUI thread.
void CloudStreamingBackend::provisionProgressThunk(const char *stage, void *user)
{
    auto *self = static_cast<CloudStreamingBackend*>(user);
    if (!self || !stage)
        return;
    const QString s = QString::fromUtf8(stage);
    QMetaObject::invokeMethod(self, [self, s]() { self->setAllocationProgress(s); });
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
