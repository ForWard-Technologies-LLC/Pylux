// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudcatalogbackend.h"
#ifdef CHIAKI_GUI_ENABLE_STEAM_SHORTCUT
#include "steamtools.h"
#endif
#include <chiaki/cloudcatalog.h>
#include <chiaki/log.h>
#include <thread>
#include <cstring>
#include <QLoggingCategory>
#include <QUrlQuery>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QJsonDocument>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QSslConfiguration>
#include <QSslSocket>
#include <QEventLoop>
#include <QTimer>
#include <QCoreApplication>
#include <QPointer>
#include <QProcessEnvironment>
#include <QImageReader>
#include <QPainter>
#include <QPixmap>
#include <climits>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

CloudCatalogBackend::CloudCatalogBackend(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
    , networkManager(new QNetworkAccessManager(this))
{
    // Disable cookie jar - we use manual Cookie headers only
    networkManager->setCookieJar(nullptr);
    
    // Initialize cache directory
    cacheDirectory = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/cloud_catalog";
    ensureCacheDirectory();
}

CloudCatalogBackend::~CloudCatalogBackend()
{
}

void CloudCatalogBackend::setSettings(Settings *new_settings)
{
    settings = new_settings;
}

void CloudCatalogBackend::ensureCacheDirectory()
{
    QDir dir;
    if (!dir.exists(cacheDirectory)) {
        dir.mkpath(cacheDirectory);
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "Created cache directory:" << cacheDirectory;
        }
    }
}

QString CloudCatalogBackend::getCacheFilePath(const QString &key)
{
    // Sanitize key for filename (replace invalid chars)
    QString safeKey = key;
    safeKey.replace("/", "_");
    safeKey.replace("\\", "_");
    safeKey.replace(":", "_");
    return cacheDirectory + "/" + safeKey + ".json";
}

bool CloudCatalogBackend::getOwnedPsnowEntitlement(const QString &gameIdentifier,
                                                   QString &outEntitlementId, QString &outPlatform)
{
    if (gameIdentifier.isEmpty())
        return false;

    // The lib owns the unified catalog filename and bumps its version suffix, so resolve it by glob
    // (newest unified_catalog_v*.json) rather than hard-coding the current version.
    QDir dir(cacheDirectory);
    QFileInfoList matches = dir.entryInfoList({QStringLiteral("unified_catalog_v*.json")},
                                              QDir::Files, QDir::Time);
    if (matches.isEmpty())
        return false;

    QFile file(matches.first().absoluteFilePath());
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;
    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();
    if (!doc.isObject())
        return false;

    const QJsonArray games = doc.object().value(QStringLiteral("games")).toArray();
    for (const QJsonValue &v : games) {
        if (!v.isObject())
            continue;
        const QJsonObject g = v.toObject();
        // Match the launch identifier against the row's launch id (and productId as a fallback).
        const QString streamId = g.value(QStringLiteral("streamIdentifier")).toString();
        const QString productId = g.value(QStringLiteral("productId")).toString();
        if (gameIdentifier != streamId && gameIdentifier != productId)
            continue;

        // Only owned PSNOW rows carry a pre-resolved streaming entitlement we can stream directly.
        const QString svcRaw = g.value(QStringLiteral("streamServiceType")).toString();
        const QString svc = svcRaw.isEmpty() ? g.value(QStringLiteral("serviceType")).toString() : svcRaw;
        const QString entitlementId = g.value(QStringLiteral("entitlementId")).toString();
        if (svc != QStringLiteral("psnow") || !g.value(QStringLiteral("isOwned")).toBool()
            || entitlementId.isEmpty())
            return false;

        outEntitlementId = entitlementId;
        outPlatform = g.value(QStringLiteral("platform")).toString();
        return true;
    }
    return false;
}

QString CloudCatalogBackend::getCachedData(const QString &key, int maxAge)
{
    QString filePath = getCacheFilePath(key);
    QFileInfo fileInfo(filePath);
    
    if (!fileInfo.exists()) {
        qInfo() << "[CACHE MISS] No cache file found for:" << key;
        return QString();
    }
    
    // Check file age
    qint64 age = fileInfo.lastModified().msecsTo(QDateTime::currentDateTime());
    if (age > maxAge) {
        // Cache expired, delete file
        QFile::remove(filePath);
        qInfo() << "[CACHE EXPIRED] Cache file expired for:" << key << "(age:" << (age / 1000) << "seconds, max:" << (maxAge / 1000) << "seconds)";
        return QString();
    }
    
    // Read file
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qWarning() << "[CACHE ERROR] Failed to open cache file:" << filePath;
        return QString();
    }
    
    QByteArray data = file.readAll();
    file.close();
    
    qint64 ageSeconds = age / 1000;
    qInfo() << "[CACHE HIT] Loaded cached data for:" << key << "(" << (data.size() / 1024) << "KB, age:" << ageSeconds << "seconds)";
    
    return QString::fromUtf8(data);
}

QString CloudCatalogBackend::getCachedPs5CatalogV3(int maxAge)
{
    const QString cached = getCachedData(QStringLiteral("ps5_cloud_catalog_v6"), maxAge);
    if (cached.isEmpty())
        return QString();

    const QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
    if (!doc.isObject()) {
        QFile::remove(getCacheFilePath(QStringLiteral("ps5_cloud_catalog_v6")));
        return QString();
    }

    const QString expectedLocale = settings ? settings->GetCloudStoreLocale() : QStringLiteral("en-US");
    const QString cachedLocale = doc.object().value(QStringLiteral("locale")).toString();
    if (!cachedLocale.isEmpty() && cachedLocale != expectedLocale) {
        qInfo() << "[CACHE LOCALE MISMATCH] PS5 catalog v3 locale" << cachedLocale
                << "!=" << expectedLocale << ", refetching";
        QFile::remove(getCacheFilePath(QStringLiteral("ps5_cloud_catalog_v6")));
        return QString();
    }

    return cached;
}

void CloudCatalogBackend::setCachedData(const QString &key, const QJsonDocument &data)
{
    QString filePath = getCacheFilePath(key);
    
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning() << "[CACHE ERROR] Failed to write cache file:" << filePath;
        return;
    }
    
    QByteArray jsonData = data.toJson(QJsonDocument::Compact);
    file.write(jsonData);
    file.close();
    
    qInfo() << "[CACHE SAVED] Cached data for:" << key << "(" << (jsonData.size() / 1024) << "KB)";
}

QString CloudCatalogBackend::getNpSsoToken()
{
    // Get NPSSO token from settings (saved during login)
    return settings->GetNpssoToken();
}

void CloudCatalogBackend::fetchUnifiedCatalog(const QJSValue &callback)
{
    // Single source of truth: libchiaki owns the entire fetch/merge/cross-reference/
    // assemble pipeline and every cache file under cacheDirectory. This client does ZERO
    // catalog derivation -- it forwards npsso/locale/cache_dir and hands the returned
    // display-and-stream-ready JSON envelope straight to QML (see chiaki/cloudcatalog.h).
    QJSValue cb = callback;

    // Serialize: a second concurrent fetch would race the same cache files. Instead
    // of rejecting the overlap (which surfaced a spurious "fetch already in progress"
    // error when navigating back to the catalog mid-fetch), coalesce it: park this
    // caller's callback and resolve it with the SAME result when the running fetch
    // finishes. No duplicate fetch, no error toast. (GUI-thread only: this method is
    // Q_INVOKABLE from QML and the completion handler is a queued call on this object.)
    bool expected = false;
    if (!unifiedFetchInFlight.compare_exchange_strong(expected, true)) {
        if (cb.isCallable())
            pendingUnifiedCallbacks.push_back(cb);
        return;
    }

    const quint64 reqId = ++next_request_id;
    pending_callbacks.insert(reqId, cb);
    QPointer<CloudCatalogBackend> self(this);

    const QByteArray npsso = getNpSsoToken().toUtf8();
    const QByteArray locale =
        (settings ? settings->GetCloudStoreLocale() : QStringLiteral("en-US")).toUtf8();
    const QByteArray cacheDir = cacheDirectory.toUtf8();

    std::thread([self, reqId, npsso, locale, cacheDir]() mutable {
        ChiakiLog log;
        chiaki_log_init(&log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR,
                        chiaki_log_cb_print, nullptr);

        ChiakiCloudCatalogConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.npsso = npsso.constData();
        cfg.locale = locale.constData();
        cfg.cache_dir = cacheDir.constData();
        cfg.force_refresh = false;

        ChiakiCloudCatalogResult res;
        ChiakiErrorCode err = chiaki_cloudcatalog_fetch_unified(&cfg, &res, &log);
        const bool success = (err == CHIAKI_ERR_SUCCESS && res.json);
        const QString json = res.json ? QString::fromUtf8(res.json) : QString();
        const QString message = success
            ? QStringLiteral("Success")
            : QString::fromUtf8(res.error_message ? res.error_message : "Failed to fetch cloud catalog");
        chiaki_cloudcatalog_result_fini(&res);

        // QJSValue must be invoked on the engine (main) thread. Route through qApp so
        // the callback is fetched and invoked on the GUI thread even if `self` is
        // destroyed before the worker finishes.
        QMetaObject::invokeMethod(qApp, [self, reqId, success, message, json]() mutable {
            if (!self)
                return; // backend destroyed while the worker ran
            const QJSValue cb = self->pending_callbacks.take(reqId);
            std::vector<QJSValue> parked;
            parked.swap(self->pendingUnifiedCallbacks);
            self->unifiedFetchInFlight.store(false);

            // Persist the locale the lib actually settled on (region detection now lives
            // entirely in libchiaki: it re-bases the locale on the account's Kamaji-session
            // country and resolves the imagic store-locale chain, returning "settledLocale").
            // Mirrors iOS noteSettledLocale / Android noteCloudStoreLocaleSettled. Uses the core
            // Settings setter (NOT QmlSettings), so it does NOT invalidate the cache the lib
            // just wrote; otherwise an international account would thrash the catalog.
            if (success && self->settings) {
                const QJsonObject root = QJsonDocument::fromJson(json.toUtf8()).object();
                const QString settled = root.value(QStringLiteral("settledLocale")).toString();
                if (!settled.isEmpty() && settled != self->settings->GetCloudStoreLocale())
                    self->settings->SetCloudStoreLocale(settled);
                self->settings->SetCloudResolvedStoreCountry(root.value(QStringLiteral("fallbackRegion")).toString());
                self->settings->SetCloudResolvedStoreLang(root.value(QStringLiteral("resolvedStoreLang")).toString());
                self->settings->SetCloudCatalogNativeMode(root.value(QStringLiteral("nativeMode")).toBool(true));
            }

            const QJSValue payload = success ? QJSValue(json) : QJSValue();
            if (cb.isCallable())
                cb.call({ success, message, payload });
            for (QJSValue &pcb : parked)
                if (pcb.isCallable())
                    pcb.call({ success, message, payload });
        }, Qt::QueuedConnection);
    }).detach();
}

void CloudCatalogBackend::fetchGameDetails(const QString &productId, const QJSValue &callback)
{
    // Check cache first
    QString cacheKey = QString("game_details_%1").arg(productId);
    qInfo() << "[fetchGameDetails] Checking cache for:" << productId << "cache key:" << cacheKey;
    QString cached = getCachedData(cacheKey, CACHE_DURATION_DETAILS);
    if (!cached.isEmpty()) {
        qInfo() << "[CACHE] Using cached game details for:" << productId << "(cache key:" << cacheKey << ")";
        QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
        if (callback.isCallable()) {
            callback.call({true, "Cached", QJSValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)))});
        }
        return;
    }
    
    qInfo() << "[API CALL] Fetching game details from API for:" << productId << "(cache key:" << cacheKey << ", cache miss)";
    
    gameDetailsState.callback = callback;
    gameDetailsState.productId = productId;
    
    // Apply 100ms cooldown before making API call
    QTimer::singleShot(100, this, [this, productId]() {
        executeGameDetailsFetch(productId);
    });
}

void CloudCatalogBackend::executeGameDetailsFetch(const QString &productId)
{
    // Get locale from unified language setting
    QString localeSetting = settings ? settings->GetCloudStoreLocale() : "en-US";
    QString locale = localeSetting.toLower(); // Convert "en-US" to "en-us"
    
    // Extract country and language from locale (e.g., "en-us" -> "US", "en")
    QStringList localeParts = locale.split("-");
    QString country = localeParts.size() > 1 ? localeParts[1].toUpper() : "US";
    QString language = localeParts[0].toLower();
    
    // Check if productId looks like a title ID (ends with _00) or is a full product ID
    QString url;
    bool isTitleId = productId.contains("_00") && productId.length() <= 15; // Title IDs are short like "PPSA01325_00"
    
    if (isTitleId) {
        // It's a title ID, use store API directly
        url = QString("https://store.playstation.com/store/api/chihiro/00_09_000/container/%1/%2/999/%3/0")
            .arg(country, language, productId);
    } else {
        // It's a product ID, try PSNOW API first
        url = QString("https://psnow.playstation.com/store/api/pcnow/00_09_000/container/%1/%2/19/%3?useOffers=true&gkb=1&gkb2=1")
            .arg(country, language, productId);
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Fetching game details ===";
        qInfo() << "  Product/Title ID:" << productId;
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest request{QUrl(url)};
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("Accept", "application/json");
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    
    QNetworkReply *reply = networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handleGameDetailsResponse);
}

void CloudCatalogBackend::handleGameDetailsResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Game Details Response ===";
        qInfo() << "  Product ID:" << gameDetailsState.productId;
        qInfo() << "  Status:" << statusCode;
    }
    
    reply->deleteLater();
    
    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "Game details fetch error:" << reply->errorString();
        if (gameDetailsState.callback.isCallable()) {
            gameDetailsState.callback.call({false, reply->errorString(), QJSValue()});
        }
        return;
    }
    
    QByteArray data = reply->readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (!doc.isObject()) {
        if (gameDetailsState.callback.isCallable()) {
            gameDetailsState.callback.call({false, "Invalid response format", QJSValue()});
        }
        return;
    }
    
    QJsonObject gameData = doc.object();
    
    // Check if images are in links[0].images (store API format)
    QJsonArray imagesArray;
    if (gameData.contains("images") && gameData["images"].isArray()) {
        imagesArray = gameData["images"].toArray();
    } else if (gameData.contains("links") && gameData["links"].isArray()) {
        QJsonArray links = gameData["links"].toArray();
        if (!links.isEmpty() && links[0].isObject()) {
            QJsonObject firstLink = links[0].toObject();
            if (firstLink.contains("images") && firstLink["images"].isArray()) {
                imagesArray = firstLink["images"].toArray();
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "  Found images in links[0].images, count:" << imagesArray.size();
                }
            }
        }
    }
    
    // If we found images, add them to gameData for extraction
    if (!imagesArray.isEmpty()) {
        gameData["images"] = imagesArray;
    }
    
    // Extract and organize images
    QJsonObject images = extractGameImages(gameData);
    gameData["extracted_images"] = images;
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  Game name:" << gameData["name"].toString();
        qInfo() << "  Cover image:" << (images["cover"].toString().isEmpty() ? "None" : "Found");
        qInfo() << "  Landscape image:" << (images["landscape"].toString().isEmpty() ? "None" : "Found");
    }
    
    QJsonDocument resultDoc(gameData);
    
    // Cache the result
    QString cacheKey = QString("game_details_%1").arg(gameDetailsState.productId);
    qInfo() << "[API CALL] Saving game details to cache for:" << gameDetailsState.productId << "(cache key:" << cacheKey << ")";
    setCachedData(cacheKey, resultDoc);
    qInfo() << "[API CALL] Game details saved to cache successfully";
    
    // Call callback
    if (gameDetailsState.callback.isCallable()) {
        QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        qInfo() << "[API CALL] Calling callback with fetched game details for:" << gameDetailsState.productId;
        gameDetailsState.callback.call({true, "Success", QJSValue(jsonStr)});
    }
}

QJsonObject CloudCatalogBackend::extractGameImages(const QJsonObject &gameData)
{
    QJsonObject images;
    QString coverUrl;
    QString landscapeUrl;
    
    if (gameData.contains("images") && gameData["images"].isArray()) {
        QJsonArray imagesArray = gameData["images"].toArray();
        
        for (const QJsonValue &img : imagesArray) {
            if (img.isObject()) {
                QJsonObject imgObj = img.toObject();
                int type = imgObj["type"].toInt();
                QString url = imgObj["url"].toString();
                
                // Type 10 = cover/box art
                if (type == 10 && coverUrl.isEmpty()) {
                    coverUrl = url;
                }
                // Type 12 = landscape 1080p (preferred)
                else if (type == 12 && landscapeUrl.isEmpty()) {
                    landscapeUrl = url;
                }
                // Type 13 = landscape 720p (fallback)
                else if (type == 13 && landscapeUrl.isEmpty()) {
                    landscapeUrl = url;
                }
            }
        }
    }
    
    images["cover"] = coverUrl;
    images["landscape"] = landscapeUrl;
    
    return images;
}

QString CloudCatalogBackend::getGameLandscapeImageFromCache(const QString &serviceType, const QString &gameIdentifier)
{
    if (gameIdentifier.isEmpty()) {
        return QString();
    }
    
    // Determine cache file based on service type
    QString cacheKey;
    QString productIdForCatalog; // For PSCloud: productId to use in catalog lookup
    
    if (serviceType.toLower() == "psnow") {
        cacheKey = "psnow_catalog";
    } else if (serviceType.toLower() == "pscloud") {
        // For PSCloud, check game details cache first (has landscape images from API)
        // If gameIdentifier is an entitlement ID, we need to find the productId from library first
        // Use very large maxAge to never invalidate cache (read-only operation)
        QString libraryCached = getCachedData("ps5_cloud_library", INT_MAX);
        if (!libraryCached.isEmpty()) {
            QJsonDocument libraryDoc = QJsonDocument::fromJson(libraryCached.toUtf8());
            if (libraryDoc.isObject()) {
                QJsonObject libraryRoot = libraryDoc.object();
                if (libraryRoot.contains("games") && libraryRoot["games"].isArray()) {
                    QJsonArray libraryGames = libraryRoot["games"].toArray();
                    for (const QJsonValue &gameValue : libraryGames) {
                        if (!gameValue.isObject()) continue;
                        QJsonObject game = gameValue.toObject();
                        // Match by entitlement ID (id field)
                        if (game.contains("id") && game["id"].toString() == gameIdentifier) {
                            // Found in library, get productId - prioritize product_id, fallback to id
                            if (game.contains("product_id")) {
                                QString productId = game["product_id"].toString();
                                if (!productId.isEmpty()) {
                                    productIdForCatalog = productId;
                                    qInfo() << "getGameLandscapeImage: Found productId" << productIdForCatalog << "for entitlement ID" << gameIdentifier;
                                    break;
                                }
                            }
                            // Fallback to id if product_id is missing or empty
                            if (productIdForCatalog.isEmpty() && game.contains("id")) {
                                QString id = game["id"].toString();
                                if (!id.isEmpty()) {
                                    productIdForCatalog = id;
                                    qInfo() << "getGameLandscapeImage: Using id as productId fallback" << productIdForCatalog << "for entitlement ID" << gameIdentifier;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Try game details cache first (has landscape images from API)
        // Use very large maxAge to never invalidate cache (read-only operation)
        QString lookupId = productIdForCatalog.isEmpty() ? gameIdentifier : productIdForCatalog;
        QString gameDetailsCacheKey = QString("game_details_%1").arg(lookupId);
        QString gameDetailsCached = getCachedData(gameDetailsCacheKey, INT_MAX);
        if (!gameDetailsCached.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Found game details cache for" << lookupId;
            QJsonDocument gameDetailsDoc = QJsonDocument::fromJson(gameDetailsCached.toUtf8());
            if (gameDetailsDoc.isObject()) {
                QJsonObject gameDetailsObj = gameDetailsDoc.object();
                if (gameDetailsObj.contains("extracted_images")) {
                    QJsonObject extracted = gameDetailsObj["extracted_images"].toObject();
                    QString landscape = extracted["landscape"].toString();
                    if (!landscape.isEmpty()) {
                        qInfo() << "getGameLandscapeImage: Using landscape image from game details cache:" << landscape;
                        return landscape;
                    }
                    // Fallback to cover if landscape not available
                    QString cover = extracted["cover"].toString();
                    if (!cover.isEmpty()) {
                        qInfo() << "getGameLandscapeImage: Using cover image from game details cache (landscape not available):" << cover;
                        return cover;
                    }
                }
            }
            qInfo() << "getGameLandscapeImage: Game details cache found but no images, falling back to catalog";
        } else {
            qInfo() << "getGameLandscapeImage: Game details cache not found for" << lookupId << ", falling back to catalog";
        }
        
        // Fallback to catalog (may not have landscape images)
        cacheKey = "ps5_cloud_catalog_v6";
    } else {
        qWarning() << "getGameLandscapeImage: Unknown service type:" << serviceType;
        return QString();
    }
    
    // Load cache - use very large maxAge to never invalidate cache (read-only operation)
    QString cached = (cacheKey == QLatin1String("ps5_cloud_catalog_v6"))
                         ? getCachedPs5CatalogV3(INT_MAX)
                         : getCachedData(cacheKey, INT_MAX);
    if (cached.isEmpty()) {
        qInfo() << "getGameLandscapeImage: Cache not available for" << cacheKey;
        return QString();
    }
    
    // Parse JSON
    QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
    if (!doc.isObject()) {
        qWarning() << "getGameLandscapeImage: Invalid cache format for" << cacheKey;
        return QString();
    }
    
    QJsonObject root = doc.object();
    if (!root.contains("games") || !root["games"].isArray()) {
        qWarning() << "getGameLandscapeImage: No games array in cache";
        return QString();
    }
    
    QJsonArray games = root["games"].toArray();
    
    // Find game by identifier
    QJsonObject gameObj;
    bool found = false;
    
    for (const QJsonValue &gameValue : games) {
        if (!gameValue.isObject()) continue;
        
        QJsonObject game = gameValue.toObject();
        
        // Match based on service type
        if (serviceType.toLower() == "psnow") {
            // PSNOW: Match by "id" field (product ID)
            if (game.contains("id") && game["id"].toString() == gameIdentifier) {
                gameObj = game;
                found = true;
                break;
            }
        } else if (serviceType.toLower() == "pscloud") {
            // PSCloud catalog: Match by "productId" field
            // Use productIdForCatalog if we found it from library, otherwise try gameIdentifier directly
            QString lookupId = productIdForCatalog.isEmpty() ? gameIdentifier : productIdForCatalog;
            if (game.contains("productId") && game["productId"].toString() == lookupId) {
                gameObj = game;
                found = true;
                break;
            }
        }
    }
    
    if (!found) {
        qInfo() << "getGameLandscapeImage: Game not found in cache:" << cacheKey << "with identifier:" << gameIdentifier;
        if (!productIdForCatalog.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Tried productId:" << productIdForCatalog << "from library lookup";
        }
        return QString();
    }
    
    qInfo() << "getGameLandscapeImage: Found game in" << cacheKey << "for identifier:" << gameIdentifier;
    
    // Extract landscape image using priority order
    // Priority 1: images array (type 12 → 13 → 10 → any)
    if (gameObj.contains("images") && gameObj["images"].isArray()) {
        QJsonArray images = gameObj["images"].toArray();
        qInfo() << "getGameLandscapeImage: Found images array with" << images.size() << "images for" << gameIdentifier;
        
        QString type12, type13, type10, anyType;
        QList<int> foundTypes;
        
        for (const QJsonValue &img : images) {
            if (!img.isObject()) continue;
            
            QJsonObject imgObj = img.toObject();
            int type = imgObj["type"].toInt();
            QString url = imgObj["url"].toString();
            foundTypes.append(type);
            
            qInfo() << "getGameLandscapeImage: Image type" << type << "URL:" << url;
            
            if (type == 12 && type12.isEmpty()) {
                type12 = url;
            } else if (type == 13 && type13.isEmpty()) {
                type13 = url;
            } else if (type == 10 && type10.isEmpty()) {
                type10 = url;
            } else if (anyType.isEmpty()) {
                anyType = url;
            }
        }
        
        qInfo() << "getGameLandscapeImage: Available image types:" << foundTypes;
        
        if (!type12.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Using type 12 (landscape 1080p) for" << gameIdentifier << "URL:" << type12;
            return type12;
        }
        if (!type13.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Using type 13 (landscape 720p) for" << gameIdentifier << "URL:" << type13;
            return type13;
        }
        if (!type10.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Using type 10 (cover) for" << gameIdentifier << "URL:" << type10;
            return type10;
        }
        if (!anyType.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Using any image type for" << gameIdentifier << "URL:" << anyType;
            return anyType;
        }
        qInfo() << "getGameLandscapeImage: No valid images found in images array for" << gameIdentifier;
    } else {
        qInfo() << "getGameLandscapeImage: No images array found in game object for" << gameIdentifier;
    }
    
    // Priority 2: imageUrl (cover image)
    if (gameObj.contains("imageUrl")) {
        QString imageUrl = gameObj["imageUrl"].toString();
        if (!imageUrl.isEmpty()) {
            qInfo() << "getGameLandscapeImage: Using imageUrl (fallback) for" << gameIdentifier << "URL:" << imageUrl;
            return imageUrl;
        }
    }
    
    qInfo() << "getGameLandscapeImage: No image found for" << gameIdentifier << "in catalog:" << cacheKey;
    return QString();
}

void CloudCatalogBackend::invalidatePs5CatalogCache()
{
    for (const QString &key :
         {QStringLiteral("ps5_cloud_catalog_v6"), QStringLiteral("ps5_cloud_catalog_v5"), QStringLiteral("ps5_cloud_catalog_v4"), QStringLiteral("ps5_cloud_catalog_v3"),
          QStringLiteral("ps5_cloud_catalog_v2"), QStringLiteral("ps5_cloud_catalog")}) {
        const QString path = getCacheFilePath(key);
        if (QFile::exists(path)) {
            QFile::remove(path);
            qInfo() << "[CACHE INVALIDATED] Removed PS5 cloud catalog cache:" << key;
        }
    }
}

void CloudCatalogBackend::invalidateCache()
{
    // libchiaki owns every cache file and its versioned key (current + legacy), so
    // delegate to it. This is the single source of truth for cache naming and keeps
    // the client from drifting out of sync when the cache schema/version bumps.
    const QByteArray cacheDir = cacheDirectory.toUtf8();
    chiaki_cloudcatalog_invalidate_cache(cacheDir.constData());
    qInfo() << "[CACHE INVALIDATED] Delegated cache invalidation to libchiaki for" << cacheDirectory;
    // Tell the cloud view to drop its stale in-memory list and re-fetch (the cache files are gone,
    // so the next fetch is a guaranteed network refresh for the now-current account).
    emit cacheInvalidated();
}

QPixmap CloudCatalogBackend::downloadImageFromUrl(const QString &url, int timeoutMs)
{
    if (url.isEmpty()) {
        return QPixmap();
    }
    
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::UserAgentHeader, "Mozilla/5.0");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    
    // Configure SSL
    QSslConfiguration sslConfig = request.sslConfiguration();
    sslConfig.setPeerVerifyMode(QSslSocket::VerifyNone); // Accept any certificate for CDN images
    request.setSslConfiguration(sslConfig);
    
    QNetworkReply *reply = networkManager->get(request);
    
    QEventLoop loop;
    QTimer timeout_timer;
    timeout_timer.setSingleShot(true);
    
    connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    connect(&timeout_timer, &QTimer::timeout, &loop, &QEventLoop::quit);
    
    timeout_timer.start(timeoutMs);
    loop.exec();
    
    QPixmap pixmap;
    if (timeout_timer.isActive() && reply->error() == QNetworkReply::NoError) {
        timeout_timer.stop();
        QByteArray data = reply->readAll();
        pixmap.loadFromData(data);
        qInfo() << "Downloaded image from" << url << "size:" << pixmap.size();
    } else {
        if (!timeout_timer.isActive()) {
            qWarning() << "Timeout downloading image from" << url;
        } else {
            qWarning() << "Failed to download image from" << url << "error:" << reply->error() << reply->errorString();
        }
    }
    
    reply->deleteLater();
    return pixmap;
}

QPixmap CloudCatalogBackend::resizeImageToFit(const QPixmap &source, int targetWidth, int targetHeight)
{
    // Return empty pixmap if source is null/empty (graceful handling)
    if (source.isNull() || source.width() == 0 || source.height() == 0) {
        return QPixmap();
    }
    
    // Create heavily blurred background using multiple-pass downscale/upscale technique
    // First, scale to fill the target dimensions (stretched)
    QPixmap stretched = source.scaled(targetWidth, targetHeight, 
                                      Qt::IgnoreAspectRatio, 
                                      Qt::SmoothTransformation);
    
    // Create extreme blur effect with multiple passes for smooth result
    // Pass 1: Aggressive downscale for extreme blur
    int blurSize1 = qMax(targetWidth, targetHeight) / 80;  // Very small for extreme blur
    QPixmap downscaled1 = stretched.scaled(blurSize1, blurSize1, 
                                           Qt::IgnoreAspectRatio, 
                                           Qt::SmoothTransformation);
    
    // Pass 2: Intermediate upscale for smoother blur
    int blurSize2 = qMax(targetWidth, targetHeight) / 40;
    QPixmap intermediate = downscaled1.scaled(blurSize2, blurSize2, 
                                              Qt::IgnoreAspectRatio, 
                                              Qt::SmoothTransformation);
    
    // Pass 3: Another intermediate pass for extra smoothness
    int blurSize3 = qMax(targetWidth, targetHeight) / 20;
    QPixmap intermediate2 = intermediate.scaled(blurSize3, blurSize3, 
                                                Qt::IgnoreAspectRatio, 
                                                Qt::SmoothTransformation);
    
    // Final upscale to target size
    QPixmap blurredBackground = intermediate2.scaled(targetWidth, targetHeight, 
                                                     Qt::IgnoreAspectRatio, 
                                                     Qt::SmoothTransformation);
    
    // Darken the background extremely for minimal distraction
    QPainter bgPainter(&blurredBackground);
    bgPainter.setCompositionMode(QPainter::CompositionMode_Darken);
    bgPainter.fillRect(blurredBackground.rect(), QColor(0, 0, 0, 210));  // ~90% darker, nearly black
    bgPainter.end();
    
    // Scale source maintaining aspect ratio for the centered foreground
    QPixmap scaled = source.scaled(targetWidth, targetHeight, 
                                    Qt::KeepAspectRatio, 
                                    Qt::SmoothTransformation);
    
    // Calculate position to center the scaled image
    int x = (targetWidth - scaled.width()) / 2;
    int y = (targetHeight - scaled.height()) / 2;
    
    // Draw scaled image centered on blurred background
    QPainter painter(&blurredBackground);
    painter.drawPixmap(x, y, scaled);
    painter.end();
    
    qInfo() << "Resized image from" << source.size() 
           << "to" << blurredBackground.size() 
           << "(scaled:" << scaled.size() << ", with blurred background)";
    
    return blurredBackground;
}

void CloudCatalogBackend::createCloudSteamShortcut(const QString &gameIdentifier, const QString &gameName, 
                                                   const QString &command, const QJSValue &callback, 
                                                   const QString &steamDir)
{
    qInfo() << "=== CREATE CLOUD STEAM SHORTCUT START ===";
    qInfo() << "Game Identifier:" << gameIdentifier;
    qInfo() << "Game Name:" << gameName;
    qInfo() << "Command:" << command;
    qInfo() << "Steam Dir:" << steamDir;
    
    QJSValue cb = callback;
    
    auto infoLambda = [callback](const QString &infoMessage) {
        qInfo() << "[INFO]" << infoMessage;
        QJSValue icb = callback;
        if (icb.isCallable())
            icb.call({infoMessage, true, false});
    };

    auto errorLambda = [callback](const QString &errorMessage) {
        qWarning() << "[ERROR]" << errorMessage;
        QJSValue icb = callback;
        if (icb.isCallable())
            icb.call({errorMessage, false, true});
    };

#ifndef CHIAKI_GUI_ENABLE_STEAM_SHORTCUT
    if (cb.isCallable())
        cb.call({QString("[E] Steam shortcuts are not available in this build."), false, true});
    return;
#else

    // Validate command
    if (command != "cloudGameCatalog" && command != "cloudGameLibrary") {
        errorLambda("[E] Invalid command. Must be 'cloudGameCatalog' or 'cloudGameLibrary'");
        return;
    }
    
    // For PSCloud (cloudGameLibrary), gameIdentifier is entitlement ID, need to look up product_id
    // For PSNOW (cloudGameCatalog), gameIdentifier is already the product ID
    QString productIdForCache = gameIdentifier;
    if (command == "cloudGameLibrary") {
        // Look up product_id from library using entitlement ID
        QString libraryCached = getCachedData("ps5_cloud_library", INT_MAX);
        if (!libraryCached.isEmpty()) {
            QJsonDocument libraryDoc = QJsonDocument::fromJson(libraryCached.toUtf8());
            if (libraryDoc.isObject()) {
                QJsonObject libraryRoot = libraryDoc.object();
                if (libraryRoot.contains("games") && libraryRoot["games"].isArray()) {
                    QJsonArray libraryGames = libraryRoot["games"].toArray();
                    for (const QJsonValue &gameValue : libraryGames) {
                        if (!gameValue.isObject()) continue;
                        QJsonObject game = gameValue.toObject();
                        // Match by entitlement ID (id field)
                        if (game.contains("id") && game["id"].toString() == gameIdentifier) {
                            // Found in library, get productId - prioritize product_id, fallback to id
                            if (game.contains("product_id")) {
                                QString productId = game["product_id"].toString();
                                if (!productId.isEmpty()) {
                                    productIdForCache = productId;
                                    qInfo() << "createCloudSteamShortcut: Found productId" << productIdForCache << "for entitlement ID" << gameIdentifier;
                                    break;
                                }
                            }
                            // Fallback to id if product_id is missing or empty
                            if (productIdForCache == gameIdentifier && game.contains("id")) {
                                QString id = game["id"].toString();
                                if (!id.isEmpty()) {
                                    productIdForCache = id;
                                    qInfo() << "createCloudSteamShortcut: Using id as productId fallback" << productIdForCache << "for entitlement ID" << gameIdentifier;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Get cached game details using product ID
    QString cacheKey = QString("game_details_%1").arg(productIdForCache);
    QString cachedDetails = getCachedData(cacheKey, 7 * 24 * 60 * 60 * 1000); // 7 days cache
    
    if (cachedDetails.isEmpty()) {
        qWarning() << "No cached game details for" << productIdForCache << "(looked up from gameIdentifier:" << gameIdentifier << ")";
        if (cb.isCallable())
            cb.call({QString("[E] No cached game details for %1. Please wait for game details to load first.").arg(gameName), false, true});
        return;
    }
    
    infoLambda(QString("[I] Fetching artwork for %1...").arg(gameName));
    
    // Parse cached game details
    QJsonDocument doc = QJsonDocument::fromJson(cachedDetails.toUtf8());
    if (!doc.isObject()) {
        errorLambda("[E] Failed to parse cached game details JSON");
        return;
    }
    
    QJsonObject gameData = doc.object();
    QJsonObject extractedImages = gameData["extracted_images"].toObject();
    
    QString coverUrl = extractedImages["cover"].toString();
    QString landscapeUrl = extractedImages["landscape"].toString();
    
    qInfo() << "Cover URL:" << coverUrl;
    qInfo() << "Landscape URL:" << landscapeUrl;
    
    // Download images
    infoLambda("[I] Downloading hero image...");
    QPixmap hero;
    if (!landscapeUrl.isEmpty()) {
        hero = downloadImageFromUrl(landscapeUrl);
    }
    if (hero.isNull() && !coverUrl.isEmpty()) {
        hero = downloadImageFromUrl(coverUrl);
    }
    if (!hero.isNull()) {
        infoLambda("[I] Resizing hero image to 1920x620...");
        hero = resizeImageToFit(hero, 1920, 620);
    }
    
    infoLambda("[I] Downloading landscape image...");
    QPixmap landscape;
    if (!landscapeUrl.isEmpty()) {
        landscape = downloadImageFromUrl(landscapeUrl);
    }
    if (landscape.isNull() && !coverUrl.isEmpty()) {
        landscape = downloadImageFromUrl(coverUrl);
    }
    if (!landscape.isNull()) {
        infoLambda("[I] Resizing landscape image to 920x430...");
        landscape = resizeImageToFit(landscape, 920, 430);
    }
    
    infoLambda("[I] Downloading portrait image...");
    QPixmap portrait;
    if (!coverUrl.isEmpty()) {
        portrait = downloadImageFromUrl(coverUrl);
    }
    if (!portrait.isNull()) {
        infoLambda("[I] Resizing portrait image to 600x900...");
        portrait = resizeImageToFit(portrait, 600, 900);
    }
    
    // Load fixed assets
    qInfo() << "Loading fixed assets...";
    QPixmap icon(":/icons/game_shortcut_icon.png");
    QPixmap logo(":/icons/game_shortcut_logo.png");
    
    if (icon.isNull()) {
        qWarning() << "Failed to load game shortcut icon, using fallback";
        icon = QPixmap(":/icons/steam_icon.png");
    }
    if (logo.isNull()) {
        qWarning() << "Failed to load game shortcut logo, using fallback";
        logo = QPixmap(":/icons/steam_logo.png");
    }
    
    // Create artwork map
    QMap<QString, const QPixmap*> artwork;
    
    if (landscape.isNull()) {
        auto fallback = QPixmap(":/icons/steam_landscape.png");
        artwork.insert("landscape", new QPixmap(fallback));
    } else {
        artwork.insert("landscape", new QPixmap(landscape));
    }
    
    if (portrait.isNull()) {
        auto fallback = QPixmap(":/icons/steam_portrait.png");
        artwork.insert("portrait", new QPixmap(fallback));
    } else {
        artwork.insert("portrait", new QPixmap(portrait));
    }
    
    if (hero.isNull()) {
        QImageReader reader;
        reader.setAllocationLimit(512);
        reader.setFileName(":/icons/steam_hero.png");
        auto fallback = QPixmap::fromImageReader(&reader);
        artwork.insert("hero", new QPixmap(fallback));
    } else {
        artwork.insert("hero", new QPixmap(hero));
    }
    
    artwork.insert("icon", new QPixmap(icon));
    artwork.insert("logo", new QPixmap(logo));
    
    // Build launch options based on command
    qInfo() << "Building launch options with" << command << "command...";
    QString escaped_identifier = gameIdentifier;
    escaped_identifier.replace("\"", "\\\"");  // Escape quotes for shell safety
    
    QString launch_options;
    if (command == "cloudGameCatalog") {
        launch_options = QString("--product-id \"%1\" cloudGameCatalog").arg(escaped_identifier);
    } else { // cloudGameLibrary
        launch_options = QString("--entitlement-id \"%1\" cloudGameLibrary").arg(escaped_identifier);
    }
    
    qInfo() << "Launch options:" << launch_options;
    infoLambda(QString("[I] Creating Steam shortcut with launch options: %1").arg(launch_options));
    
    // Initialize SteamTools
    qInfo() << "Initializing SteamTools with steamDir:" << steamDir;
    SteamTools* steam_tools = new SteamTools(infoLambda, errorLambda, steamDir);
    
    qInfo() << "Checking if Steam exists...";
    bool steamExists = steam_tools->steamExists();
    qInfo() << "Steam exists:" << steamExists;
    
    if (!steamExists) {
        qWarning() << "Steam does not exist, cannot create shortcut";
        if (cb.isCallable())
            cb.call({QString("[E] Steam does not exist, cannot create Steam Shortcut"), false, true});
        
        // Clean up artwork
        for (auto it = artwork.begin(); it != artwork.end(); ++it) {
            delete it.value();
        }
        delete steam_tools;
        return;
    }
    
    // Get executable path
    QString executable = QCoreApplication::applicationFilePath();
    qInfo() << "Application executable path:" << executable;
    
    #ifdef Q_OS_LINUX
        // Check if running as AppImage
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        if (env.contains("APPIMAGE")) {
            executable = env.value("APPIMAGE");
            qInfo() << "Running as AppImage, using:" << executable;
        }
    #endif
    
    // Check for Flatpak
    if (executable == "flatpak") {
        const QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        QString flatpakId = env.value("FLATPAK_ID");
        launch_options.prepend(QString("run %1 ").arg(flatpakId));
        qInfo() << "Running as Flatpak, updated launch options:" << launch_options;
    }
    
    // If running from extracted pylux directory, use launch.sh instead of direct executable
    if (executable != "flatpak" && !executable.endsWith(".AppImage"))
    {
        QFileInfo exeInfo(executable);
        QString exePath = exeInfo.absoluteFilePath();
        
        if (exePath.contains("/usr/bin/"))
        {
            QDir exeDir(exeInfo.absolutePath());
            if (exeDir.cdUp() && exeDir.cdUp())
            {
                QString launchScript = exeDir.absoluteFilePath("launch.sh");
                if (QFile::exists(launchScript))
                {
                    qInfo() << "Using launch.sh for cloud game Steam shortcut:" << launchScript;
                    executable = launchScript;
                }
            }
        }
    }
    
    // Build the shortcut
    qInfo() << "Building shortcut entry...";
    QString shortcut_name = gameName;
    SteamShortcutEntry newShortcut = steam_tools->buildShortcutEntry(
        std::move(shortcut_name), 
        std::move(executable), 
        std::move(launch_options), 
        std::move(artwork)
    );
    qInfo() << "Shortcut entry built successfully";
    
    // Parse existing shortcuts
    qInfo() << "Parsing existing shortcuts...";
    QVector<SteamShortcutEntry> shortcuts = steam_tools->parseShortcuts();
    qInfo() << "Found" << shortcuts.size() << "existing shortcuts";
    
    bool found = false;
    
    // Check if shortcut already exists
    qInfo() << "Checking if shortcut already exists...";
    for (int i = 0; i < shortcuts.size(); ++i) {
        if (shortcuts[i].getAppName() == newShortcut.getAppName()) {
            qInfo() << "Found existing shortcut at index" << i << ", updating...";
            infoLambda(QString("[I] Updating existing shortcut for %1").arg(newShortcut.getAppName()));
            shortcuts[i] = newShortcut;
            found = true;
            break;
        }
    }
    
    if (!found) {
        qInfo() << "No existing shortcut found, adding new one";
        infoLambda(QString("[I] Adding new shortcut for %1").arg(newShortcut.getAppName()));
        shortcuts.append(newShortcut);
    }
    
    // Update shortcuts
    qInfo() << "Updating shortcuts file with" << shortcuts.size() << "total shortcuts...";
    steam_tools->updateShortcuts(shortcuts);
    qInfo() << "Shortcuts updated successfully";
    
    // Update controller config for Steam Deck
    QString controller_layout_workshop_id = "3049833406";
    qInfo() << "Updating Steam Deck controller config with workshop ID:" << controller_layout_workshop_id;
    try {
        steam_tools->updateControllerConfig(newShortcut.getAppName(), std::move(controller_layout_workshop_id));
    } catch (const std::exception& e) {
        qWarning() << "Failed to update Steam controller config:" << e.what();
    }
    
    infoLambda("[I] Successfully created Steam shortcut!");
    infoLambda("");
    infoLambda("══════════════════════════════════════════════════════");
    infoLambda("✓ SHORTCUT CREATED SUCCESSFULLY!");
    infoLambda("══════════════════════════════════════════════════════");
    infoLambda("");
    infoLambda(QString("→ Game: %1").arg(gameName));
    infoLambda("");
    infoLambda("⚠ IMPORTANT: Please restart Steam for the shortcut to appear!");
    infoLambda("");
    qInfo() << "Calling final callback with done=true, ok=true";
    qInfo() << "Callback is callable:" << cb.isCallable();
    if (cb.isCallable()) {
        QJSValue result = cb.call({QString("Shortcut created successfully for %1").arg(gameName), true, true});
        qInfo() << "Callback call result:" << (result.isError() ? result.toString() : "success");
        if (result.isError()) {
            qWarning() << "Callback error:" << result.toString();
        }
    } else {
        qWarning() << "Callback is not callable!";
    }
    
    // Clean up artwork
    for (auto it = artwork.begin(); it != artwork.end(); ++it) {
        delete it.value();
    }
    delete steam_tools;

#endif // CHIAKI_GUI_ENABLE_STEAM_SHORTCUT
}


