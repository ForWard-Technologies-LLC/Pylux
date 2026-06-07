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
#include <QMap>
#include <QCache>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

/**
 * CloudCatalogBackend - Fetches and manages cloud gaming catalogs
 * 
 * Provides methods to:
 * - Fetch PSNOW catalog (PS4/PS3 subscription games)
 * - Fetch PS5 Cloud Streaming catalog (all PS5 games with streaming support)
 * - Fetch owned PS5 games (requires PSN authentication)
 * - Cross-reference owned games with cloud catalog
 * - Fetch detailed game information including images
 */
class CloudCatalogBackend : public QObject
{
    Q_OBJECT

public:
    explicit CloudCatalogBackend(Settings *settings, QObject *parent = nullptr);
    ~CloudCatalogBackend();

    // Main catalog fetching methods
    Q_INVOKABLE void fetchPsnowCatalog(const QJSValue &callback);
    // Streamable PS3 Classics catalog. Walks the PUBLIC pcnow (Apollo) container
    // STORE-MSF192018-APOLLOPS3GAMES (no OAuth/session needed -- the container API is
    // open), returning ~300 PS3 titles that imagic/gameslist never lists. These stream
    // via the PSNOW -> Gaikai konan path the streaming code already supports.
    Q_INVOKABLE void fetchPs3Catalog(const QJSValue &callback);
    Q_INVOKABLE void fetchPs5CloudCatalog(const QJSValue &callback);
    Q_INVOKABLE void fetchOwnedPs5Games(const QJSValue &callback);
    Q_INVOKABLE void getOwnedPs5CloudGames(const QJSValue &callback);
    Q_INVOKABLE void fetchGameDetails(const QString &productId, const QJSValue &callback);

    // Steam shortcut creation for cloud games
    Q_INVOKABLE void createCloudSteamShortcut(const QString &gameIdentifier, const QString &gameName, 
                                              const QString &command, const QJSValue &callback, 
                                              const QString &steamDir = QString());

    // Utility methods
    Q_INVOKABLE void clearCache();
    Q_INVOKABLE void invalidateCache();
    Q_INVOKABLE void invalidatePs5CatalogCache();
    Q_INVOKABLE QString getCachedData(const QString &key, int maxAge);
    Q_INVOKABLE QString getGameLandscapeImageFromCache(const QString &serviceType, const QString &gameIdentifier);

signals:
    void catalogUpdated();

private slots:
    void handlePsnowCategoryResponse();
    void handlePs5ImagicListResponse();
    void finalizePs5CloudCatalogFetch();
    void handleOwnedGamesOAuthResponse();
    void fetchOwnedGamesPage();
    void handleOwnedGamesResponse();
    void handleGameDetailsResponse();
    void processCrossReferenceComplete();

private:
    Settings *settings;
    QNetworkAccessManager *networkManager;
    
    // Cache directory for file-based caching
    QString cacheDirectory;
    
    // Cache duration constants
    static const int CACHE_DURATION_CATALOG = 24 * 60 * 60 * 1000; // 24 hours
    static const int CACHE_DURATION_DETAILS = 7 * 24 * 60 * 60 * 1000; // 7 days
    
    // PSNOW catalog fetching state
    struct PsnowFetchState {
        QJSValue callback;
        QJsonArray allGames;
        QStringList categories;
        int currentCategoryIndex;
        QTimer *rateLimitTimer;
        QString oauthCode;
        QString jsessionId;
        QString baseUrl;
        QString duid;
        bool authInProgress;
    } psnowState;

    // PS3 Classics catalog fetching state (public Apollo PS3 container, paginated).
    // containerUrl is resolved per account region group (Americas vs PAL) at fetch time.
    struct Ps3FetchState {
        QJSValue callback;
        QJsonArray allGames;
        QString containerUrl;
        int currentStart = 0;
        int totalResults = -1;
        bool inProgress = false;
    } ps3State;

    // PS5 catalog fetching state (six imagic lists, merged like Sony's PS5 cloud finder)
    struct Ps5FetchState {
        QJSValue callback;
        int pendingListFetches = 0;
        int succeededListFetches = 0;
        bool allPs5ListSucceeded = false;
        QStringList failedLists;
        QMap<QString, QJsonObject> gamesByConceptId;
        QMap<QString, QJsonObject> plusLibrarySupplementByProductId;
        QMap<QString, QString> productIdAliases; // alternate imagic productId -> canonical browse productId
        int totalGamesSeen = 0;
        // Store-locale fallback: Sony serves a fixed set of language-COUNTRY locales.
        // The country is always valid but the language may not be (e.g. hu-HU 404s,
        // en-HU works). We try the session locale, then en-COUNTRY, then en-US.
        QStringList localeChain;
        int localeTierIndex = 0;
        QString activeLocale; // canonical "ll-CC" form for the tier currently being fetched
    } ps5State;
    
    // Owned games fetching state
    struct OwnedGamesState {
        QJSValue callback;
        QString oauthToken;
        QJsonArray accumulatedEntitlements;  // Accumulate results across pages
        int currentStart = 0;                 // Current pagination offset
        static const int PAGE_SIZE = 300;     // Page size for API requests
    } ownedGamesState;
    
    // Game details fetching state
    struct GameDetailsState {
        QJSValue callback;
        QString productId;
        QTimer *cooldownTimer;
    } gameDetailsState;
    
    // Cross-reference state for owned PS5 cloud games
    struct CrossReferenceState {
        QJSValue callback;
        QJsonArray cloudCatalogGames;
        QJsonArray plusLibrarySupplement;
        QJsonArray ownedGames;
        QMap<QString, QString> productIdAliases;
        // Bundle product_id -> its component entitlement ids, for bundle-sibling matching (from
        // upstream PR #15): a bundle entitlement (e.g. RE7 Gold) expands to its component games.
        QMap<QString, QStringList> componentIdsByProductId;
        bool catalogFetched;
        bool ownedGamesFetched;
    } crossReferenceState;
    
    // Helper methods
    void setCachedData(const QString &key, const QJsonDocument &data);
    QString getCachedPs5CatalogV3(int maxAge);
    QString getCacheFilePath(const QString &key);
    void ensureCacheDirectory();
    void fetchPsnowCategory(int categoryIndex);
    void processPsnowCatalogComplete();
    QString ps3AccountCountry() const;
    void fetchPs3CatalogPage();
    void handlePs3CatalogPageResponse();
    void finishPs3Catalog();
    void fetchOwnedGamesOAuthToken();
    void fetchPsnowOAuthToken();
    void fetchPsnowSession();
    void fetchPsnowStores();
    void fetchPsnowRootContainer();
    void handlePsnowOAuthResponse();
    void handlePsnowSessionResponse();
    void handlePsnowStoresResponse();
    void handlePsnowRootContainerResponse();
    void startPs5ImagicListFetch(); // fires the six imagic list requests for ps5State.activeLocale
    void executeGameDetailsFetch(const QString &productId);
    QJsonArray filterStreamingSupportedGames(const QJsonArray &games);
    QJsonArray filterOwnedPs5Games(const QJsonArray &entitlements);
    QJsonObject extractGameImages(const QJsonObject &gameData);
    QString extractCoverImageFromGameObject(const QJsonObject &gameObj);
    QString getNpSsoToken();
    
    // Helper methods for shortcut creation
    QPixmap downloadImageFromUrl(const QString &url, int timeoutMs = 10000);
    QPixmap resizeImageToFit(const QPixmap &source, int targetWidth, int targetHeight);
};

#endif // CLOUDCATALOGBACKEND_H

