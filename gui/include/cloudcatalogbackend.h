// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CLOUDCATALOGBACKEND_H
#define CLOUDCATALOGBACKEND_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QJSValue>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QTimer>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

#include <atomic>
#include <vector>

/**
 * CloudCatalogBackend - thin QML bridge over the libchiaki cloud catalog.
 *
 * The entire catalog fetch / merge / ownership cross-reference / assemble
 * pipeline (and every cache file) now lives in libchiaki and is shared verbatim
 * with Android and iOS. This class only:
 *   - forwards fetchUnifiedCatalog() to chiaki_cloudcatalog_fetch_unified() and
 *     hands the returned display-and-stream-ready JSON straight to QML, and
 *   - keeps the per-game details fetch + Steam-shortcut / image utilities that
 *     are GUI-only concerns and not part of the catalog contract.
 *
 * It performs ZERO catalog derivation (no category/serviceType/platform/owner
 * logic) -- see chiaki/cloudcatalog.h for the contract.
 */
class CloudCatalogBackend : public QObject
{
    Q_OBJECT

public:
    explicit CloudCatalogBackend(Settings *settings, QObject *parent = nullptr);
    ~CloudCatalogBackend();

    /** Unified cloud catalog (libchiaki single source of truth). */
    Q_INVOKABLE void fetchUnifiedCatalog(const QJSValue &callback);
    Q_INVOKABLE void fetchGameDetails(const QString &productId, const QJSValue &callback);

    // Steam shortcut creation for cloud games
    Q_INVOKABLE void createCloudSteamShortcut(const QString &gameIdentifier, const QString &gameName,
                                              const QString &command, const QJSValue &callback,
                                              const QString &steamDir = QString());

    // Rebind to the active profile's Settings after a profile switch. The backend reads the NPSSO
    // token + cloud locale from this pointer, and the previous profile's Settings is deleted on
    // switch, so failing to update this would read a stale/dangling account (wrong owned games or a
    // use-after-free on the next fetch).
    void setSettings(Settings *settings);

    // Utility methods
    Q_INVOKABLE void invalidateCache();
    Q_INVOKABLE void invalidatePs5CatalogCache();
    Q_INVOKABLE QString getCachedData(const QString &key, int maxAge);
    Q_INVOKABLE QString getGameLandscapeImageFromCache(const QString &serviceType, const QString &gameIdentifier);

    // Owned-PSNOW launch fast-path: look up a title in the cached unified catalog by its launch
    // identifier and, if it is an owned PSNOW row with a pre-resolved streaming entitlement, return
    // that entitlementId + platform so the C provisioning flow can skip the resolve/acquire path. Returns
    // false (out params untouched) for anything else (non-owned, pscloud, missing entitlementId, or
    // no cached catalog). Reads the catalog the lib wrote; account-specific ownership only.
    bool getOwnedPsnowEntitlement(const QString &gameIdentifier, QString &outEntitlementId, QString &outPlatform);

signals:
    // Emitted after the on-disk catalog cache is wiped (profile/account switch, NPSSO change,
    // cloud-language change, or manual refresh). The cloud view listens for this to re-fetch so
    // the visible game list never lingers on the previous account's games.
    void cacheInvalidated();

private slots:
    void handleGameDetailsResponse();

private:
    Settings *settings;
    QNetworkAccessManager *networkManager;

    // Cache directory for file-based caching
    QString cacheDirectory;

    // Cache duration constants
    static const int CACHE_DURATION_DETAILS = 7 * 24 * 60 * 60 * 1000; // 7 days

    // Guards against overlapping unified fetches racing on the shared cache dir.
    // A second call while a fetch is in flight is coalesced (not rejected): its
    // callback is parked here and invoked with the same result when the running
    // fetch completes, so navigating back to the catalog mid-fetch never surfaces
    // an error or starts a duplicate racing fetch. Both fields are touched only on
    // the GUI/engine thread (Q_INVOKABLE entry + the queued completion handler).
    std::atomic<bool> unifiedFetchInFlight{false};
    std::vector<QJSValue> pendingUnifiedCallbacks;

    // Game details fetching state
    struct GameDetailsState {
        QJSValue callback;
        QString productId;
    } gameDetailsState;

    // Helper methods
    void setCachedData(const QString &key, const QJsonDocument &data);
    QString getCachedPs5CatalogV3(int maxAge);
    QString getCacheFilePath(const QString &key);
    void ensureCacheDirectory();
    void executeGameDetailsFetch(const QString &productId);
    QJsonObject extractGameImages(const QJsonObject &gameData);
    QString getNpSsoToken();

    // Helper methods for shortcut creation
    QPixmap downloadImageFromUrl(const QString &url, int timeoutMs = 10000);
    QPixmap resizeImageToFit(const QPixmap &source, int targetWidth, int targetHeight);
};

#endif // CLOUDCATALOGBACKEND_H
