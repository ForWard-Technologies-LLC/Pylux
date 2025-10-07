#include "jsonrequester.h"
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QDebug>
#include <QRegularExpression>

JsonRequester::JsonRequester(QObject* parent) : QObject(parent), networkManager(new QNetworkAccessManager(this)) {
    connect(networkManager, &QNetworkAccessManager::finished, this, &JsonRequester::onRequestFinished);
}

QString JsonRequester::generateBearerAuthHeader(QString bearerToken) {
    return QString("Bearer %1").arg(bearerToken);
}

QString JsonRequester::generateBasicAuthHeader(QString username, QString password) {
    QString combined = QString("%1:%2").arg(username).arg(password);
    QString authHeader = "Basic " + combined.toUtf8().toBase64();
    return authHeader;
}

void JsonRequester::makePostRequest(const QString& url, const QString& authHeader, const QString contentType,
                                    const QString body) {
    makeRequest(true, url, authHeader, contentType, body);
}

void JsonRequester::makeGetRequest(const QString& url, const QString& authHeader, const QString contentType) {
    makeRequest(false, url, authHeader, contentType, nullptr);
}

void JsonRequester::makeRequest(bool post, const QString& url, const QString& authHeader, const QString contentType,
                                const QString body) {
    // Log PSN network request details when verbose logging is enabled
    qCDebug(chiakiGui) << "PSN Network Request:";
    qCDebug(chiakiGui) << "  Method:" << (post ? "POST" : "GET");
    qCDebug(chiakiGui) << "  URL:" << url;
    qCDebug(chiakiGui) << "  Content-Type:" << contentType;
    qCDebug(chiakiGui) << "  Authorization:" <<  authHeader;
    if (post && !body.isEmpty()) {
        qCDebug(chiakiGui) << "  Body:" << body;
    }

    QUrl q_url(url);
    QNetworkRequest request(q_url);
    request.setRawHeader("Authorization", authHeader.toUtf8());
    request.setRawHeader("Content-Type", contentType.toUtf8());

    QNetworkReply* reply;
    if (post) {
        QByteArray postData = body.toUtf8();
        reply = networkManager->post(request, postData);
    } else {
        reply = networkManager->get(request);
    }

    currentReplies.insert(reply, url);
}

void JsonRequester::onRequestFinished(QNetworkReply* reply) {
    const QString url = currentReplies.value(reply);
    currentReplies.remove(reply);

    // Log PSN network response details when verbose logging is enabled
    qCDebug(chiakiGui) << "PSN Network Response:";
    qCDebug(chiakiGui) << "  URL:" << url;
    qCDebug(chiakiGui) << "  HTTP Status:" << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    qCDebug(chiakiGui) << "  Error Code:" << reply->error();

    if (reply->error() == QNetworkReply::NoError) {
        const QByteArray data = reply->readAll();
        qCDebug(chiakiGui) << "  Response Size:" << data.size() << "bytes";
        
        // Log response body with sensitive data redacted
        QString responseStr = QString::fromUtf8(data);
        qCDebug(chiakiGui) << "  Response Body:" << responseStr;
        
        const QJsonDocument jsonDocument = QJsonDocument::fromJson(data);
        emit requestFinished(url, jsonDocument);
    } else {
        qCDebug(chiakiGui) << "  Error:" << reply->errorString();
        emit requestError(url, reply->errorString(), reply->error());
    }

    reply->deleteLater();
}
