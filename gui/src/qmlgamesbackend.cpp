#include "qmlgamesbackend.h"
#include "steamtools.h"

#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QSslConfiguration>
#include <QSslSocket>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <QTimer>
#include <QLoggingCategory>
#include <QEventLoop>
#include <QCoreApplication>
#include <QProcessEnvironment>
#include <QImageReader>
#include <algorithm>

Q_LOGGING_CATEGORY(chiakiGuiGames, "chiaki.gui.games")

QmlGamesBackend::QmlGamesBackend(Settings *settings, QObject *parent)
    : QObject(parent)
    , settings(settings)
    , network_manager(new QNetworkAccessManager(this))
{
}

QmlGamesBackend::~QmlGamesBackend()
{
}

bool QmlGamesBackend::canMakePsnRequest()
{
    // Rate limit: 5 requests per second
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    
    // Remove requests older than 1 second
    psn_request_times.erase(
        std::remove_if(psn_request_times.begin(), psn_request_times.end(),
            [now](qint64 time) { return (now - time) > 1000; }),
        psn_request_times.end()
    );
    
    // Check if we can make another request
    if (psn_request_times.size() >= 5) {
        return false;
    }
    
    // Record this request
    psn_request_times.append(now);
    return true;
}

QString QmlGamesBackend::getGameImage(const QString &titleId)
{
    if (titleId.isEmpty()) {
        return QString();
    }
    
    // Check cache for all images JSON
    QString cache_key = QString("game_images/%1\\all").arg(titleId);
    QString cached_json = settings->GetGameImageCache(cache_key);
    
    if (!cached_json.isEmpty()) {
        // Parse JSON array and extract cover image URL
        QJsonDocument doc = QJsonDocument::fromJson(cached_json.toUtf8());
        if (doc.isArray()) {
            QJsonArray images = doc.array();
            // Find best image (type 10 = box art, 12 = portrait, 13 = landscape)
            for (const int type : {10, 12, 13}) {
                for (const QJsonValue &img_val : images) {
                    if (img_val.isObject()) {
                        QJsonObject img = img_val.toObject();
                        if (img.value("type").toInt() == type) {
                            return img.value("url").toString();
                        }
                    }
                }
            }
        }
    }
    
    // Queue fetch from PSN if not cached
    QTimer::singleShot(0, this, [this, titleId]() {
        fetchGameImageFromPsn(titleId);
    });
    
    return QString(); // Return empty while loading
}

void QmlGamesBackend::fetchGameImageFromPsn(const QString &titleId)
{
    if (!canMakePsnRequest()) {
        // Retry after delay
        QTimer::singleShot(200, this, [this, titleId]() {
            fetchGameImageFromPsn(titleId);
        });
        return;
    }
    
    // Format: PPSA01325_00
    QString full_title_id = titleId.contains("_") ? titleId : titleId + "_00";
    
    // Fetch from PlayStation Store API
    QString url = QString("https://store.playstation.com/store/api/chihiro/00_09_000/container/US/en/999/%1/0")
        .arg(full_title_id);
    
    qCInfo(chiakiGuiGames) << "Fetching fresh Store API data for" << titleId << "from" << url;
    
    QNetworkRequest request(url);
    QNetworkReply *reply = network_manager->get(request);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, titleId]() {
        reply->deleteLater();
        
        if (reply->error() == QNetworkReply::NoError) {
            QByteArray response_data = reply->readAll();
            QJsonDocument doc = QJsonDocument::fromJson(response_data);
            
            if (doc.isObject()) {
                
                QJsonObject obj = doc.object();
                
                // Try to find images - they might be in .images or .links[0].images
                QJsonArray images = obj.value("images").toArray();
                
                // If not found at root, try links[0].images
                if (images.isEmpty()) {
                    QJsonArray links = obj.value("links").toArray();
                    if (!links.isEmpty() && links[0].isObject()) {
                        images = links[0].toObject().value("images").toArray();
                        qCInfo(chiakiGuiGames) << "Found images in links[0].images, count:" << images.size();
                    }
                } else {
                    qCInfo(chiakiGuiGames) << "Found images at root, count:" << images.size();
                }
                
                // Cache all images as JSON array
                if (!images.isEmpty()) {
                    QJsonDocument images_doc(images);
                    QString cache_key = QString("game_images/%1\\all").arg(titleId);
                    settings->SetGameImageCache(cache_key, QString(images_doc.toJson(QJsonDocument::Compact)));
                    qCInfo(chiakiGuiGames) << "Cached all images JSON for" << titleId << "with" << images.size() << "images";
                    
                    // Notify UI
                    emit gameImageUpdated(titleId);
                } else {
                    qCWarning(chiakiGuiGames) << "No images to cache for" << titleId;
                }
            }
        } else {
            qCWarning(chiakiGuiGames) << "Failed to fetch game image for" << titleId << ":" << reply->errorString();
        }
    });
}

void QmlGamesBackend::fetchTrophyData(const QString &npTitleId, bool forceRefresh)
{
    if (npTitleId.isEmpty()) {
        return;
    }
    
    // Check cache first (unless force refresh)
    if (!forceRefresh && trophy_cache.contains(npTitleId)) {
        const TrophyCache &cached = trophy_cache[npTitleId];
        qint64 age_ms = QDateTime::currentMSecsSinceEpoch() - cached.timestamp;
        
        if (age_ms < TROPHY_CACHE_DURATION_MS) {
            qCInfo(chiakiGuiGames) << "Using cached trophy data for" << npTitleId << "(age:" << (age_ms / 1000 / 60) << "minutes)";
            emit trophyDataReceived(npTitleId, cached.jsonData);
            return;
        } else {
            qCInfo(chiakiGuiGames) << "Trophy cache expired for" << npTitleId << "(age:" << (age_ms / 1000 / 60 / 60) << "hours)";
        }
    }
    
    if (forceRefresh) {
        qCInfo(chiakiGuiGames) << "Force refresh requested for" << npTitleId;
    }
    
    QString psn_token = settings->GetPsnAuthToken();
    if (psn_token.isEmpty()) {
        qCWarning(chiakiGuiGames) << "No PSN token available for trophy fetch";
        return;
    }
    
    if (!canMakePsnRequest()) {
        // Retry after delay
        QTimer::singleShot(200, this, [this, npTitleId, forceRefresh]() {
            fetchTrophyData(npTitleId, forceRefresh);
        });
        return;
    }
    
    // Step 1: Fetch trophy title data (counts) - this converts npTitleId to npCommunicationId
    QString url = QString("https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles?npTitleIds=%1")
        .arg(npTitleId);
    
    qCInfo(chiakiGuiGames) << "=== TROPHY API CALL 1: Fetch Trophy Title ===";
    qCInfo(chiakiGuiGames) << "URL:" << url;
    qCInfo(chiakiGuiGames) << "Method: GET";
    qCInfo(chiakiGuiGames) << "Headers: Authorization: Bearer [TOKEN REDACTED]";
    
    QNetworkRequest request(url);
    request.setRawHeader("Authorization", QString("Bearer %1").arg(psn_token).toUtf8());
    
    QNetworkReply *reply = network_manager->get(request);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, npTitleId, psn_token]() {
        reply->deleteLater();
        
        qCInfo(chiakiGuiGames) << "=== TROPHY API RESPONSE 1: Trophy Title ===";
        qCInfo(chiakiGuiGames) << "Status Code:" << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qCInfo(chiakiGuiGames) << "Status Message:" << reply->attribute(QNetworkRequest::HttpReasonPhraseAttribute).toString();
        
        if (reply->error() != QNetworkReply::NoError) {
            qCWarning(chiakiGuiGames) << "Error:" << reply->errorString();
            qCWarning(chiakiGuiGames) << "Response Body:" << reply->readAll();
            emit trophyDataReceived(npTitleId, "{}");
            return;
        }
        
        QByteArray title_data = reply->readAll();
        qCInfo(chiakiGuiGames) << "Response Body:" << title_data;
        QJsonDocument title_doc = QJsonDocument::fromJson(title_data);
        
        if (!title_doc.isObject()) {
            emit trophyDataReceived(npTitleId, "{}");
            return;
        }
        
        QJsonObject title_obj = title_doc.object();
        QJsonArray title_array = title_obj.value("trophyTitles").toArray();
        
        if (title_array.isEmpty()) {
            qCWarning(chiakiGuiGames) << "No trophy titles found for" << npTitleId;
            emit trophyDataReceived(npTitleId, "{}");
            return;
        }
        
        QJsonObject trophy_title = title_array[0].toObject();
        
        // Extract the actual npCommunicationId from the response
        QString npCommunicationId = trophy_title.value("npCommunicationId").toString();
        if (npCommunicationId.isEmpty()) {
            qCWarning(chiakiGuiGames) << "No npCommunicationId in trophy response for" << npTitleId;
            emit trophyDataReceived(npTitleId, "{}");
            return;
        }
        
        qCInfo(chiakiGuiGames) << "Got npCommunicationId" << npCommunicationId << "for npTitleId" << npTitleId;
        
        // Step 2: Fetch trophy groups using the correct npCommunicationId
        fetchTrophyGroups(npCommunicationId, npTitleId, psn_token, trophy_title);
    });
}

void QmlGamesBackend::fetchTrophyGroups(const QString &npCommunicationId, const QString &npTitleId, const QString &psn_token, const QJsonObject &trophy_title)
{
    if (!canMakePsnRequest()) {
        QTimer::singleShot(200, this, [this, npCommunicationId, npTitleId, psn_token, trophy_title]() {
            fetchTrophyGroups(npCommunicationId, npTitleId, psn_token, trophy_title);
        });
        return;
    }
    
    QString url = QString("https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/%1/trophyGroups")
        .arg(npCommunicationId);
    
    qCInfo(chiakiGuiGames) << "=== TROPHY API CALL 2: Fetch Trophy Groups ===";
    qCInfo(chiakiGuiGames) << "URL:" << url;
    qCInfo(chiakiGuiGames) << "Method: GET";
    qCInfo(chiakiGuiGames) << "Headers: Authorization: Bearer [TOKEN REDACTED]";
    
    QNetworkRequest request(url);
    request.setRawHeader("Authorization", QString("Bearer %1").arg(psn_token).toUtf8());
    
    QNetworkReply *reply = network_manager->get(request);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, npCommunicationId, npTitleId, psn_token, trophy_title]() {
        reply->deleteLater();
        
        qCInfo(chiakiGuiGames) << "=== TROPHY API RESPONSE 2: Trophy Groups ===";
        qCInfo(chiakiGuiGames) << "Status Code:" << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qCInfo(chiakiGuiGames) << "Status Message:" << reply->attribute(QNetworkRequest::HttpReasonPhraseAttribute).toString();
        
        if (reply->error() != QNetworkReply::NoError) {
            qCWarning(chiakiGuiGames) << "Error:" << reply->errorString();
            qCWarning(chiakiGuiGames) << "Response Body:" << reply->readAll();
            // Send title data without trophy list
            QJsonDocument doc(trophy_title);
            emit trophyDataReceived(npTitleId, QString(doc.toJson(QJsonDocument::Compact)));
            return;
        }
        
        QByteArray groups_data = reply->readAll();
        qCInfo(chiakiGuiGames) << "Response Body:" << groups_data;
        QJsonDocument groups_doc = QJsonDocument::fromJson(groups_data);
        
        if (!groups_doc.isObject()) {
            QJsonDocument doc(trophy_title);
            emit trophyDataReceived(npTitleId, QString(doc.toJson(QJsonDocument::Compact)));
            return;
        }
        
        QJsonObject groups_obj = groups_doc.object();
        QJsonArray groups_array = groups_obj.value("trophyGroups").toArray();
        
        if (groups_array.isEmpty()) {
            QJsonDocument doc(trophy_title);
            emit trophyDataReceived(npTitleId, QString(doc.toJson(QJsonDocument::Compact)));
            return;
        }
        
        qCInfo(chiakiGuiGames) << "Found" << groups_array.size() << "trophy groups for" << npCommunicationId;
        
        // Fetch all trophy groups
        fetchAllTrophyGroups(npCommunicationId, npTitleId, psn_token, trophy_title, groups_array, 0);
    });
}

void QmlGamesBackend::fetchAllTrophyGroups(const QString &npCommunicationId, const QString &npTitleId, 
                                            const QString &psn_token, const QJsonObject &trophy_title, 
                                            const QJsonArray &groups, int currentGroupIndex)
{
    if (currentGroupIndex >= groups.size()) {
        // All groups fetched - shouldn't happen as we need at least one
        QJsonDocument doc(trophy_title);
        emit trophyDataReceived(npTitleId, QString(doc.toJson(QJsonDocument::Compact)));
        return;
    }
    
    if (!canMakePsnRequest()) {
        QTimer::singleShot(200, this, [this, npCommunicationId, npTitleId, psn_token, trophy_title, groups, currentGroupIndex]() {
            fetchAllTrophyGroups(npCommunicationId, npTitleId, psn_token, trophy_title, groups, currentGroupIndex);
        });
        return;
    }
    
    QString group_id = groups[currentGroupIndex].toObject().value("trophyGroupId").toString();
    qCInfo(chiakiGuiGames) << "Fetching trophies for group" << group_id << "(" << (currentGroupIndex + 1) << "of" << groups.size() << ")";
    
    QString url = QString("https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/%1/trophyGroups/%2/trophies")
        .arg(npCommunicationId)
        .arg(group_id);
    
    qCInfo(chiakiGuiGames) << "=== TROPHY API CALL 3: Fetch Individual Trophies ===";
    qCInfo(chiakiGuiGames) << "URL:" << url;
    qCInfo(chiakiGuiGames) << "Method: GET";
    qCInfo(chiakiGuiGames) << "Headers: Authorization: Bearer [TOKEN REDACTED]";
    qCInfo(chiakiGuiGames) << "Group:" << group_id << "(" << (currentGroupIndex + 1) << "/" << groups.size() << ")";
    
    QNetworkRequest request(url);
    request.setRawHeader("Authorization", QString("Bearer %1").arg(psn_token).toUtf8());
    
    QNetworkReply *reply = network_manager->get(request);
    
    // Store accumulated trophy data across groups
    static QMap<QString, QJsonArray> accumulated_trophies;
    
    if (currentGroupIndex == 0) {
        // Starting new fetch - clear accumulated data
        accumulated_trophies[npTitleId] = QJsonArray();
    }
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, npCommunicationId, npTitleId, psn_token, trophy_title, groups, currentGroupIndex]() {
        reply->deleteLater();
        
        qCInfo(chiakiGuiGames) << "=== TROPHY API RESPONSE 3: Individual Trophies ===";
        qCInfo(chiakiGuiGames) << "Status Code:" << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qCInfo(chiakiGuiGames) << "Status Message:" << reply->attribute(QNetworkRequest::HttpReasonPhraseAttribute).toString();
        qCInfo(chiakiGuiGames) << "Group:" << groups[currentGroupIndex].toObject().value("trophyGroupId").toString();
        
        if (reply->error() == QNetworkReply::NoError) {
            QByteArray trophies_data = reply->readAll();
            qCInfo(chiakiGuiGames) << "Response Body:" << trophies_data;
            QJsonDocument trophies_doc = QJsonDocument::fromJson(trophies_data);
            
            if (trophies_doc.isObject()) {
                QJsonObject trophies_obj = trophies_doc.object();
                QJsonArray trophies_array = trophies_obj.value("trophies").toArray();
                
                qCInfo(chiakiGuiGames) << "Fetched" << trophies_array.size() << "trophies for group" << groups[currentGroupIndex].toObject().value("trophyGroupId").toString();
                
                // Accumulate trophies
                QJsonArray &accumulated = accumulated_trophies[npTitleId];
                for (const QJsonValue &trophy : trophies_array) {
                    accumulated.append(trophy);
                }
            }
        } else {
            qCWarning(chiakiGuiGames) << "Error:" << reply->errorString();
            qCWarning(chiakiGuiGames) << "Response Body:" << reply->readAll();
        }
        
        // Check if we need to fetch more groups
        if (currentGroupIndex < groups.size() - 1) {
            // Fetch next group
            fetchAllTrophyGroups(npCommunicationId, npTitleId, psn_token, trophy_title, groups, currentGroupIndex + 1);
        } else {
            // All groups fetched - emit combined data
            QJsonObject combined_data = trophy_title;
            combined_data["trophies"] = accumulated_trophies[npTitleId];
            
            qCInfo(chiakiGuiGames) << "All trophy groups fetched. Total trophies:" << accumulated_trophies[npTitleId].size();
            
            // Clean up accumulated data
            accumulated_trophies.remove(npTitleId);
            
            // Convert to JSON and cache it
            QJsonDocument doc(combined_data);
            QString jsonData = QString(doc.toJson(QJsonDocument::Compact));
            
            // Cache the result
            TrophyCache cache;
            cache.jsonData = jsonData;
            cache.timestamp = QDateTime::currentMSecsSinceEpoch();
            trophy_cache[npTitleId] = cache;
            
            qCInfo(chiakiGuiGames) << "Cached trophy data for" << npTitleId;
            
            emit trophyDataReceived(npTitleId, jsonData);
        }
    });
}

QString QmlGamesBackend::getGamesForDevice(const QString &deviceId)
{
    QString games_json = settings->GetPsnGamesJson();
    if (games_json.isEmpty()) {
        return QString("[]");
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(games_json.toUtf8());
    if (!doc.isObject()) {
        return QString("[]");
    }
    
    QJsonObject devices = doc.object();
    if (!devices.contains(deviceId)) {
        return QString("[]");
    }
    
    QJsonValue device_val = devices.value(deviceId);
    if (!device_val.isObject()) {
        return QString("[]");
    }
    
    QJsonObject device = device_val.toObject();
    QJsonValue games_val = device.value("games");
    if (!games_val.isArray()) {
        return QString("[]");
    }
    
    QJsonDocument games_doc(games_val.toArray());
    return QString(games_doc.toJson(QJsonDocument::Compact));
}

QString QmlGamesBackend::getCachedStoreResponse(const QString &titleId)
{
    // Check persistent cache for all images JSON
    QString cache_key = QString("game_images/%1\\all").arg(titleId);
    QString cached_json = settings->GetGameImageCache(cache_key);
    
    if (!cached_json.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Found cached images JSON for" << titleId;
    } else {
        qCInfo(chiakiGuiGames) << "No cached images JSON found for" << titleId;
    }
    
    return cached_json;
}

QPixmap QmlGamesBackend::downloadImageFromUrl(const QString &url, int timeoutMs)
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
    
    QNetworkReply *reply = network_manager->get(request);
    
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
        qCInfo(chiakiGuiGames) << "Downloaded image from" << url << "size:" << pixmap.size();
    } else {
        if (!timeout_timer.isActive()) {
            qCWarning(chiakiGuiGames) << "Timeout downloading image from" << url;
        } else {
            qCWarning(chiakiGuiGames) << "Failed to download image from" << url << "error:" << reply->error() << reply->errorString();
        }
    }
    
    reply->deleteLater();
    return pixmap;
}

void QmlGamesBackend::createGameSteamShortcut(const QString &titleId, const QString &gameName, 
                                               const QJSValue &callback, const QString &steamDir, const QString &deviceName)
{
    qWarning() << "=== CREATE STEAM SHORTCUT START ===";
    qWarning() << "Title ID:" << titleId;
    qWarning() << "Game Name:" << gameName;
    qWarning() << "Steam Dir:" << steamDir;
    qWarning() << "Callback is callable:" << callback.isCallable();
    
    QJSValue cb = callback;
    
    auto infoLambda = [callback](const QString &infoMessage) {
        qCInfo(chiakiGuiGames) << "[INFO]" << infoMessage;
        QJSValue icb = callback;
        if (icb.isCallable())
            icb.call({infoMessage, true, false});
    };

    auto errorLambda = [callback](const QString &errorMessage) {
        qCWarning(chiakiGuiGames) << "[ERROR]" << errorMessage;
        QJSValue icb = callback;
        if (icb.isCallable())
            icb.call({errorMessage, false, true});
    };
    
    qCInfo(chiakiGuiGames) << "Getting cached Store API response...";
    // Get cached Store API response
    QString store_response = getCachedStoreResponse(titleId);
    qCInfo(chiakiGuiGames) << "Cached response length:" << store_response.length();
    
    if (store_response.isEmpty()) {
        qCWarning(chiakiGuiGames) << "No cached image data for game" << gameName;
        if (cb.isCallable())
            cb.call({QString("[E] No cached image data for game %1. Please wait for images to load first.").arg(gameName), false, true});
        return;
    }
    
    infoLambda(QString("[I] Fetching artwork for %1...").arg(gameName));
    
    // Parse the cached images JSON array
    qCInfo(chiakiGuiGames) << "Parsing cached images JSON...";
    QJsonDocument doc = QJsonDocument::fromJson(store_response.toUtf8());
    if (!doc.isArray()) {
        errorLambda("[E] Failed to parse cached images JSON");
        return;
    }
    
    QJsonArray images = doc.array();
    qCInfo(chiakiGuiGames) << "Got" << images.size() << "images from cache";
    
    if (images.isEmpty()) {
        errorLambda("[E] No images found in cache");
        return;
    }
    
    // Extract image URLs by type
    qCInfo(chiakiGuiGames) << "Extracting image URLs by type...";
    QString type10_url, type12_url, type13_url;
    for (const QJsonValue &img_val : images) {
        if (img_val.isObject()) {
            QJsonObject img = img_val.toObject();
            int type = img.value("type").toInt();
            QString url = img.value("url").toString();
            
            if (type == 10) {
                type10_url = url;
                qCInfo(chiakiGuiGames) << "Found type 10 (box art):" << url;
            }
            else if (type == 12) {
                type12_url = url;
                qCInfo(chiakiGuiGames) << "Found type 12 (1080p hero):" << url;
            }
            else if (type == 13) {
                type13_url = url;
                qCInfo(chiakiGuiGames) << "Found type 13 (720p hero):" << url;
            }
        }
    }
    
    // Download images with fallback logic
    qCInfo(chiakiGuiGames) << "Starting image downloads...";
    infoLambda("[I] Downloading hero image...");
    QPixmap hero;
    // Try type 13 (720p landscape) first, then type 12 (1080p landscape), then type 10
    if (!type13_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Downloading hero from type 13...";
        hero = downloadImageFromUrl(type13_url);
    }
    if (hero.isNull() && !type12_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Type 13 failed, trying type 12...";
        hero = downloadImageFromUrl(type12_url);
    }
    if (hero.isNull() && !type10_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Type 12 failed, trying type 10...";
        hero = downloadImageFromUrl(type10_url);
    }
    qCInfo(chiakiGuiGames) << "Hero image result:" << (hero.isNull() ? "null" : QString("size %1x%2").arg(hero.width()).arg(hero.height()));
    
    infoLambda("[I] Downloading landscape image...");
    QPixmap landscape;
    // Try type 13 first, then type 12, then type 10
    if (!type13_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Downloading landscape from type 13...";
        landscape = downloadImageFromUrl(type13_url);
    }
    if (landscape.isNull() && !type12_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Type 13 failed, trying type 12...";
        landscape = downloadImageFromUrl(type12_url);
    }
    if (landscape.isNull() && !type10_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Type 12 failed, trying type 10...";
        landscape = downloadImageFromUrl(type10_url);
    }
    qCInfo(chiakiGuiGames) << "Landscape image result:" << (landscape.isNull() ? "null" : QString("size %1x%2").arg(landscape.width()).arg(landscape.height()));
    
    infoLambda("[I] Downloading portrait image...");
    QPixmap portrait;
    // Use type 10 (box art) for portrait
    if (!type10_url.isEmpty()) {
        qCInfo(chiakiGuiGames) << "Downloading portrait from type 10...";
        portrait = downloadImageFromUrl(type10_url);
    }
    qCInfo(chiakiGuiGames) << "Portrait image result:" << (portrait.isNull() ? "null" : QString("size %1x%2").arg(portrait.width()).arg(portrait.height()));
    
    // Load fixed assets
    qCInfo(chiakiGuiGames) << "Loading fixed assets...";
    QPixmap icon(":/icons/game_shortcut_icon.png");
    QPixmap logo(":/icons/game_shortcut_logo.png");
    
    qCInfo(chiakiGuiGames) << "Icon loaded:" << !icon.isNull() << "size:" << icon.size();
    qCInfo(chiakiGuiGames) << "Logo loaded:" << !logo.isNull() << "size:" << logo.size();
    
    if (icon.isNull()) {
        qCWarning(chiakiGuiGames) << "Failed to load game shortcut icon, using fallback";
        icon = QPixmap(":/icons/steam_icon.png");
    }
    if (logo.isNull()) {
        qCWarning(chiakiGuiGames) << "Failed to load game shortcut logo, using fallback";
        logo = QPixmap(":/icons/steam_logo.png");
    }
    
    // Create artwork map
    QMap<QString, const QPixmap*> artwork;
    
    // Use downloaded images or fallback to defaults
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
    
    // Build launch options with properly escaped game name
    qCInfo(chiakiGuiGames) << "Building launch options...";
    QString escaped_game_name = gameName;
    escaped_game_name.replace("\"", "\\\"");  // Escape quotes
    QString launch_options = QString("--game=\"%1\"").arg(escaped_game_name);
    
    // Add device name if provided
    if (!deviceName.isEmpty()) {
        QString escaped_device_name = deviceName;
        escaped_device_name.replace("\"", "\\\"");  // Escape quotes
        launch_options += QString(" --nickname=\"%1\"").arg(escaped_device_name);
        qCInfo(chiakiGuiGames) << "Added device name to launch options:" << deviceName;
    }
    
    qCInfo(chiakiGuiGames) << "Launch options:" << launch_options;
    infoLambda(QString("[I] Creating Steam shortcut with launch options: %1").arg(launch_options));
    
    // Initialize SteamTools
    qCInfo(chiakiGuiGames) << "Initializing SteamTools with steamDir:" << steamDir;
    SteamTools* steam_tools = new SteamTools(infoLambda, errorLambda, steamDir);
    
    qCInfo(chiakiGuiGames) << "Checking if Steam exists...";
    bool steamExists = steam_tools->steamExists();
    qCInfo(chiakiGuiGames) << "Steam exists:" << steamExists;
    
    if (!steamExists) {
        qCWarning(chiakiGuiGames) << "Steam does not exist, cannot create shortcut";
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
    qCInfo(chiakiGuiGames) << "Application executable path:" << executable;
    
    #ifdef Q_OS_LINUX
        // Check if running as AppImage
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        if (env.contains("APPIMAGE")) {
            executable = env.value("APPIMAGE");
            qCInfo(chiakiGuiGames) << "Running as AppImage, using:" << executable;
        }
    #endif
    
    // Check for Flatpak
    if (executable == "flatpak") {
        const QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        QString flatpakId = env.value("FLATPAK_ID");
        launch_options.prepend(QString("run %1 ").arg(flatpakId));
        qCInfo(chiakiGuiGames) << "Running as Flatpak, updated launch options:" << launch_options;
    }
    
    // Build the shortcut
    qCInfo(chiakiGuiGames) << "Building shortcut entry...";
    QString shortcut_name = gameName;
    SteamShortcutEntry newShortcut = steam_tools->buildShortcutEntry(
        std::move(shortcut_name), 
        std::move(executable), 
        std::move(launch_options), 
        std::move(artwork)
    );
    qCInfo(chiakiGuiGames) << "Shortcut entry built successfully";
    
    // Parse existing shortcuts
    qCInfo(chiakiGuiGames) << "Parsing existing shortcuts...";
    QVector<SteamShortcutEntry> shortcuts = steam_tools->parseShortcuts();
    qCInfo(chiakiGuiGames) << "Found" << shortcuts.size() << "existing shortcuts";
    
    bool found = false;
    
    // Check if shortcut already exists
    qCInfo(chiakiGuiGames) << "Checking if shortcut already exists...";
    for (int i = 0; i < shortcuts.size(); ++i) {
        if (shortcuts[i].getAppName() == newShortcut.getAppName()) {
            qCInfo(chiakiGuiGames) << "Found existing shortcut at index" << i << ", updating...";
            infoLambda(QString("[I] Updating existing shortcut for %1").arg(newShortcut.getAppName()));
            shortcuts[i] = newShortcut;
            found = true;
            break;
        }
    }
    
    if (!found) {
        qCInfo(chiakiGuiGames) << "No existing shortcut found, adding new one";
        infoLambda(QString("[I] Adding new shortcut for %1").arg(newShortcut.getAppName()));
        shortcuts.append(newShortcut);
    }
    
    // Update shortcuts
    qCInfo(chiakiGuiGames) << "Updating shortcuts file with" << shortcuts.size() << "total shortcuts...";
    steam_tools->updateShortcuts(shortcuts);
    qCInfo(chiakiGuiGames) << "Shortcuts updated successfully";
    
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
    if (cb.isCallable())
        cb.call({QString("✓ Steam shortcut created for %1").arg(gameName), true, true});
    
    // Clean up
    qCInfo(chiakiGuiGames) << "Cleaning up SteamTools...";
    delete steam_tools;
    qCInfo(chiakiGuiGames) << "=== CREATE STEAM SHORTCUT END ===";
}

