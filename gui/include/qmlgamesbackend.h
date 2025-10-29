#pragma once

#include "settings.h"

#include <QObject>
#include <QString>
#include <QList>
#include <QJSValue>
#include <QPixmap>
#include <QJsonArray>
#include <QJsonObject>

class QNetworkAccessManager;

/**
 * Backend for the Games view, handling PSN game data, images, and trophies.
 * Kept separate from QmlBackend for maintainability and to avoid merge conflicts.
 */
class QmlGamesBackend : public QObject
{
    Q_OBJECT

public:
    explicit QmlGamesBackend(Settings *settings, QObject *parent = nullptr);
    ~QmlGamesBackend();

    Q_INVOKABLE QString getGameImage(const QString &titleId, const QString &type = "portrait");
    Q_INVOKABLE void fetchTrophyData(const QString &npTitleId, bool forceRefresh = false);
    Q_INVOKABLE QString getGamesForDevice(const QString &deviceId);
    Q_INVOKABLE QString getCachedStoreResponse(const QString &titleId);
    Q_INVOKABLE void createGameSteamShortcut(const QString &titleId, const QString &gameName, 
                                              const QJSValue &callback, const QString &steamDir, const QString &deviceName = QString());

signals:
    void trophyDataReceived(const QString &npCommunicationId, const QString &jsonData);
    void gameImageUpdated(const QString &titleId);

private:
    void fetchGameImageFromPsn(const QString &titleId);
    void fetchTrophyGroups(const QString &npCommunicationId, const QString &npTitleId, const QString &psn_token, const QJsonObject &trophy_title, bool isRetry = false);
    void fetchAllTrophies(const QString &npCommunicationId, const QString &npTitleId, const QString &psn_token, 
                          const QJsonObject &trophy_title, const QJsonArray &groups, bool isRetry = false);
    void fetchTrophyProgress(const QString &npCommunicationId, const QString &npTitleId, const QString &psn_token, 
                             const QJsonObject &trophy_title, const QJsonArray &groups, const QJsonArray &trophies_definitions, bool isRetry = false);
    void refreshPsnTokenAndRetry(const QString &npCommunicationId, const QString &npTitleId, 
                                 const QJsonObject &trophy_title, const QJsonArray &groups = QJsonArray(),
                                 const QJsonArray &trophies_definitions = QJsonArray(), int retryStep = 0);
    bool canMakePsnRequest();
    QPixmap downloadImageFromUrl(const QString &url, int timeoutMs = 10000);
    QPixmap resizeImageToFit(const QPixmap &source, int targetWidth, int targetHeight);

    struct TrophyCache {
        QString jsonData;
        qint64 timestamp;
    };
    
    struct GameImageCache {
        QString jsonData;  // Full Store API response
        qint64 timestamp;
    };
    
    Settings *settings;
    QNetworkAccessManager *network_manager;
    QList<qint64> psn_request_times;  // For rate limiting
    QMap<QString, TrophyCache> trophy_cache;  // Trophy data cache (npTitleId -> cached data)
    QMap<QString, GameImageCache> game_image_cache;  // Game image cache (titleId -> cached API response)
    static constexpr qint64 TROPHY_CACHE_DURATION_MS = 24 * 60 * 60 * 1000;  // 24 hours
    static constexpr qint64 GAME_IMAGE_CACHE_DURATION_MS = 30LL * 24 * 60 * 60 * 1000;  // 30 days
};

