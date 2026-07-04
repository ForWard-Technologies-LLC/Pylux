// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreamingbackend.h"
#include "streamsession.h"
#include "exception.h"
#include "chiaki/remote/holepunch.h"
#include "chiaki/session.h"
#include "chiaki/cloudsession.h"
#include "chiaki/log.h"
#include "qmlbackend.h"
#include "cloudcatalogbackend.h"

#include <QObject>
#include <QCoreApplication>
#include <QDateTime>
#include <QLoggingCategory>
#include <QPointer>
#include <QSet>
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

    // The C provisioning flow runs the NPSSO authorizeCheck itself as its first
    // (silent) step and surfaces AUTHORIZATION_FAILED (handled in handleProvisionError)
    // if the token is expired -- no separate pre-flight pass is needed here anymore.
    continueCloudSessionAfterAuth(serviceType, gameIdentifier, callback, npssoToken, QString());
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
    // Store country/language for the resolve container URL -- byte-faithful to the old
    // Kamaji step0_5d (commit a43e8af2): in native mode (resolvedStoreCountry empty) derive
    // BOTH from the store locale; in fallback mode use the resolved country and the resolved
    // language (else the locale language). Hardcoded US/en would 404 a non-US native store.
    QString loc = settings->GetCloudStoreLocale();
    const QStringList lp = (loc.isEmpty() ? QStringLiteral("en-US") : loc).split('-');
    const QString localeLang = (!lp.isEmpty() && !lp[0].isEmpty()) ? lp[0].toLower() : QStringLiteral("en");
    const QString localeCountry = (lp.size() > 1 && !lp[1].isEmpty()) ? lp[1].toUpper() : QStringLiteral("US");
    const QString resolvedCountry = settings->GetCloudResolvedStoreCountry();
    const QString resolvedLang = settings->GetCloudResolvedStoreLang();
    QString cc, cl;
    if (!resolvedCountry.isEmpty()) {
        cc = resolvedCountry;
        cl = !resolvedLang.isEmpty() ? resolvedLang : localeLang;
    } else {
        cc = localeCountry;
        cl = localeLang;
    }
    const QByteArray storeCountry = cc.toUtf8();
    const QByteArray storeLang = cl.toUtf8();
    // Streaming language: manual picker, else fall back to the auto-detected catalog
    // store locale so non-English regions don't silently get "en".
    QString gameLangStr = settings->GetCloudGameLanguage();
    if (gameLangStr.isEmpty())
        gameLangStr = settings->GetCloudStoreLocale();
    const QByteArray gameLang = gameLangStr.toUtf8();
    const QByteArray forcedDc = (pscloud ? settings->GetCloudDatacenterPSCloud()
                                         : settings->GetCloudDatacenterPSNOW()).toUtf8();
    // Prior stored datacenters for this service -> merged with this run's pings by the lib
    // and returned, so the Settings picker keeps previously-measured RTTs (like the old code).
    const QByteArray priorDc = (pscloud ? settings->GetCloudDatacentersJsonPSCloud()
                                        : settings->GetCloudDatacentersJsonPSNOW()).toUtf8();
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

    const quint64 reqId = ++next_request_id;
    pending_callbacks.insert(reqId, callback);
    QPointer<CloudStreamingBackend> self(this);

    std::thread([self, reqId, svc, gameId, npsso, storeCountry, storeLang, gameLang,
                 forcedDc, priorDc, resolution, bitrate, isForeign, attrPassed, ownedEnt, ownedPlat]() mutable {
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
        cfg.prior_datacenters_json = priorDc.constData();
        cfg.resolution = resolution;
        cfg.bitrate_kbps = bitrate;
        cfg.progress = &CloudStreamingBackend::provisionProgressThunk;
        cfg.is_cancelled = nullptr;
        cfg.user = &self; // address of the lambda-local QPointer — valid for the blocking call's lifetime

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
        const QString dcPings = res.datacenter_pings ? QString::fromUtf8(res.datacenter_pings) : QString();
        chiaki_cloud_provision_result_fini(&res);

        QMetaObject::invokeMethod(qApp, [self, reqId, success, attrPassed, serviceTypeStr, serverIp, serverPort,
                                         handshakeKey, launchSpec, sessionId, wrap, mtuIn, mtuOut, rttUs, errMsg, dcPings]() mutable {
            if (!self)
                return; // backend destroyed while the worker ran
            const QJSValue callback = self->pending_callbacks.take(reqId);
            // Persist the merged datacenter list so Settings shows the measured RTTs
            // (done whether or not allocation succeeded -- the old code saved during the ping).
            if (!dcPings.isEmpty()) {
                if (serviceTypeStr == "pscloud") self->settings->SetCloudDatacentersJsonPSCloud(dcPings);
                else self->settings->SetCloudDatacentersJsonPSNOW(dcPings);
            }
            if (success) {
                if (!attrPassed)
                    self->settings->SetAccountAttributesCheckPassed(true);
                self->finishCloudSession(serviceTypeStr, serverIp, serverPort, handshakeKey, launchSpec,
                                         sessionId, wrap, mtuIn, mtuOut, rttUs, callback);
            } else {
                self->handleProvisionError(serviceTypeStr, errMsg, callback);
            }
        }, Qt::QueuedConnection);
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
    if (errorMessage.contains(QStringLiteral("AUTHORIZATION_FAILED"))) {
        if (qmlBackend) qmlBackend->setShowAuthorizationFailedDialog(true);
        userMessage = tr("Your NPSSO token is likely expired. Please re-login to continue using cloud streaming.");
    } else if (errorMessage.contains(QStringLiteral("PS_PLUS_SUBSCRIPTION_REQUIRED"))) {
        if (qmlBackend) qmlBackend->setShowPSPlusSubscriptionDialog(true);
        userMessage = tr("PS Plus subscription required");
    } else if (errorMessage.contains(QStringLiteral("ACCOUNT_PRIVACY_SETTINGS"))) {
        // Sentinel is "ACCOUNT_PRIVACY_SETTINGS:<upgrade-url>" (URL omitted when no
        // missing elements were parsed). Extract the URL for the dialog.
        const QString prefix = QStringLiteral("ACCOUNT_PRIVACY_SETTINGS:");
        QString upgradeUrl;
        int idx = errorMessage.indexOf(prefix);
        if (idx >= 0)
            upgradeUrl = errorMessage.mid(idx + prefix.length());
        if (qmlBackend) {
            qmlBackend->setAccountPrivacyUpgradeUrl(upgradeUrl);
            qmlBackend->setShowAccountPrivacySettingsDialog(true);
        }
        userMessage = tr("Account privacy settings need updating");
    } else if (errorMessage.contains(QStringLiteral("PING_TIMEOUT"))) {
        if (qmlBackend) qmlBackend->setShowPingTimeoutDialog(true);
        userMessage = tr("Ping must be < 80ms to start a cloud session");
    } else if (errorMessage.contains(QStringLiteral("GAME_NOT_FREE"))) {
        // Stale catalog: a title that was a free PS+ offer now costs money. Sentinel is
        // "GAME_NOT_FREE:<price>" (price may be empty). Tell the user to refresh.
        const QString prefix = QStringLiteral("GAME_NOT_FREE:");
        QString price;
        int idx = errorMessage.indexOf(prefix);
        if (idx >= 0) price = errorMessage.mid(idx + prefix.length()).trimmed();
        userMessage = price.isEmpty()
            ? tr("This game is no longer free to stream. Your game list may be out of date — refresh it and try again.")
            : tr("This game is no longer free to stream (price: %1). Your game list may be out of date — refresh it and try again.").arg(price);
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
}

// C progress callback -- runs on the worker thread; marshal to the GUI thread.
void CloudStreamingBackend::provisionProgressThunk(const char *stage, void *user)
{
    auto *holder = static_cast<QPointer<CloudStreamingBackend>*>(user);
    if (!holder || !stage)
        return;
    // NOTE: copying a QPointer off the GUI thread is not strictly thread-safe (it touches the
    // QWeakPointer control block, which the GUI thread mutates on destruction). It is safe HERE
    // only because CloudStreamingBackend is owned by QmlBackend and outlives every provision, so
    // it is never destroyed concurrently with a progress callback. Do not copy this pattern to a
    // backend with a shorter lifetime.
    QPointer<CloudStreamingBackend> self = *holder;
    const QString s = QString::fromUtf8(stage);
    QMetaObject::invokeMethod(qApp, [self, s]() {
        if (self)
            self->setAllocationProgress(s);
    }, Qt::QueuedConnection);
}

void CloudStreamingBackend::onAllocationProgress(QString message)
{
    setAllocationProgress(message);
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

