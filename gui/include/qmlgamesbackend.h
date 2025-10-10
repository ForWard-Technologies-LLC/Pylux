#pragma once

#include "settings.h"

#include <QObject>
#include <QString>
#include <QList>

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

    Q_INVOKABLE QString getGameImage(const QString &titleId);
    Q_INVOKABLE void fetchTrophyData(const QString &npCommunicationId);
    Q_INVOKABLE QString getGamesForDevice(const QString &deviceId);

signals:
    void trophyDataReceived(const QString &npCommunicationId, const QString &jsonData);
    void gameImageUpdated(const QString &titleId);

private:
    void fetchGameImageFromPsn(const QString &titleId);
    bool canMakePsnRequest();

    Settings *settings;
    QNetworkAccessManager *network_manager;
    QList<qint64> psn_request_times;  // For rate limiting
};

