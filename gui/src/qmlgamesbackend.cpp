#include "qmlgamesbackend.h"

#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <QTimer>
#include <QLoggingCategory>
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
    
    // Check cache first
    QString cache_key = QString("game_images/%1").arg(titleId);
    QString cached_url = settings->GetGameImageCache(cache_key);
    
    if (!cached_url.isEmpty()) {
        return cached_url;
    }
    
    // Queue fetch from PSN
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
    
    QNetworkRequest request(url);
    QNetworkReply *reply = network_manager->get(request);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, titleId]() {
        reply->deleteLater();
        
        if (reply->error() == QNetworkReply::NoError) {
            QByteArray response_data = reply->readAll();
            QJsonDocument doc = QJsonDocument::fromJson(response_data);
            
            if (doc.isObject()) {
                QJsonObject obj = doc.object();
                
                // Try to find images in order: type 10, 12, 13
                QJsonArray images = obj.value("images").toArray();
                QString best_image_url;
                
                for (const QString &type : {"10", "12", "13"}) {
                    for (const QJsonValue &img_val : images) {
                        if (img_val.isObject()) {
                            QJsonObject img = img_val.toObject();
                            if (img.value("type").toString() == type) {
                                best_image_url = img.value("url").toString();
                                break;
                            }
                        }
                    }
                    if (!best_image_url.isEmpty()) break;
                }
                
                // Cache all available images
                if (!images.isEmpty()) {
                    QJsonDocument cache_doc(images);
                    QString cache_key_all = QString("game_images/%1/all").arg(titleId);
                    settings->SetGameImageCache(cache_key_all, QString(cache_doc.toJson(QJsonDocument::Compact)));
                }
                
                // Cache the best image URL
                if (!best_image_url.isEmpty()) {
                    QString cache_key = QString("game_images/%1").arg(titleId);
                    settings->SetGameImageCache(cache_key, best_image_url);
                    
                    // Notify UI
                    emit gameImageUpdated(titleId);
                }
            }
        } else {
            qCWarning(chiakiGuiGames) << "Failed to fetch game image for" << titleId << ":" << reply->errorString();
        }
    });
}

void QmlGamesBackend::fetchTrophyData(const QString &npCommunicationId)
{
    if (npCommunicationId.isEmpty()) {
        return;
    }
    
    QString psn_token = settings->GetPsnAuthToken();
    if (psn_token.isEmpty()) {
        qCWarning(chiakiGuiGames) << "No PSN token available for trophy fetch";
        return;
    }
    
    if (!canMakePsnRequest()) {
        // Retry after delay
        QTimer::singleShot(200, this, [this, npCommunicationId]() {
            fetchTrophyData(npCommunicationId);
        });
        return;
    }
    
    // Fetch trophy title data
    QString url = QString("https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles?npTitleIds=%1")
        .arg(npCommunicationId);
    
    QNetworkRequest request(url);
    request.setRawHeader("Authorization", QString("Bearer %1").arg(psn_token).toUtf8());
    
    QNetworkReply *reply = network_manager->get(request);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply, npCommunicationId]() {
        reply->deleteLater();
        
        if (reply->error() == QNetworkReply::NoError) {
            QByteArray response_data = reply->readAll();
            emit trophyDataReceived(npCommunicationId, QString::fromUtf8(response_data));
        } else {
            qCWarning(chiakiGuiGames) << "Failed to fetch trophy data for" << npCommunicationId << ":" << reply->errorString();
            // Emit empty data
            emit trophyDataReceived(npCommunicationId, "{}");
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

