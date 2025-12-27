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
                                    const QString body, QString userAgent, const QHash<QString, QString>& additionalHeaders) {
    makeRequest(true, url, authHeader, contentType, body, userAgent, additionalHeaders);
}

void JsonRequester::makeGetRequest(const QString& url, const QString& authHeader, const QString contentType, QString userAgent, const QHash<QString, QString>& additionalHeaders) {
    makeRequest(false, url, authHeader, contentType, nullptr, userAgent, additionalHeaders);
}

void JsonRequester::makeRequest(bool post, const QString& url, const QString& authHeader, const QString contentType,
                                const QString body, QString userAgent, const QHash<QString, QString>& additionalHeaders) {
    // Always log the URL
    qCInfo(chiakiGui) << "PSN" << (post ? "POST" : "GET") << "request:" << url;
    
    // Log full request details only in verbose mode
    qCDebug(chiakiGui) << "PSN Network Request Details:";
    qCDebug(chiakiGui) << "  Content-Type:" << contentType;
    qCDebug(chiakiGui) << "  Authorization:" <<  authHeader;
    if (!userAgent.isEmpty()) {
        qCDebug(chiakiGui) << "  User-Agent:" << userAgent;
    }
    if (post && !body.isEmpty()) {
        qCDebug(chiakiGui) << "  Body:" << body;
    }

    QUrl q_url(url);
    QNetworkRequest request(q_url);
    // Only set Authorization header if provided (OAuth v3 doesn't use it)
    if (!authHeader.isEmpty()) {
        request.setRawHeader("Authorization", authHeader.toUtf8());
    }
    request.setRawHeader("Content-Type", contentType.toUtf8());
    
    // Set User-Agent if provided
    if (!userAgent.isEmpty()) {
        request.setRawHeader("User-Agent", userAgent.toUtf8());
    }
    
    // Add additional headers if provided
    for (auto it = additionalHeaders.constBegin(); it != additionalHeaders.constEnd(); ++it) {
        request.setRawHeader(it.key().toUtf8(), it.value().toUtf8());
    }
    
    // Log all request headers
    qCInfo(chiakiGui) << "=== JsonRequester Request Headers ===";
    qCInfo(chiakiGui) << "URL:" << url;
    qCInfo(chiakiGui) << "Method:" << (post ? "POST" : "GET");
    qCInfo(chiakiGui) << "Request Headers:";
    
    // QNetworkRequest doesn't have rawHeaderPairs(), so we use rawHeaderList() and rawHeader()
    QList<QByteArray> headerNames = request.rawHeaderList();
    for (const QByteArray &headerName : headerNames) {
        QByteArray headerValue = request.rawHeader(headerName);
        QString headerNameStr = QString::fromUtf8(headerName);
        QString headerValueStr = QString::fromUtf8(headerValue);
        
        // Truncate long values for readability
        if (headerNameStr.compare("Authorization", Qt::CaseInsensitive) == 0) {
            headerValueStr = headerValueStr.left(30) + "...";
        }
        
        qCInfo(chiakiGui) << "  " << headerNameStr << ":" << headerValueStr;
    }
    
    // Also check Content-Type header (might be set via setHeader instead of setRawHeader)
    QVariant contentTypeHeader = request.header(QNetworkRequest::ContentTypeHeader);
    if (contentTypeHeader.isValid() && !contentTypeHeader.toString().isEmpty()) {
        qCInfo(chiakiGui) << "  Content-Type:" << contentTypeHeader.toString();
    }
    
    if (post && !body.isEmpty()) {
        qCInfo(chiakiGui) << "Request Body:" << body;
    }
    qCInfo(chiakiGui) << "=====================================";

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

    if (reply->error() == QNetworkReply::NoError) {
        const QByteArray data = reply->readAll();
        
        // Always log basic response info
        qCInfo(chiakiGui) << "PSN response:" << url << "- Status:" 
                          << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        
        // Log full response details only in verbose mode
        qCDebug(chiakiGui) << "PSN Network Response Details:";
        qCDebug(chiakiGui) << "  URL:" << url;
        qCDebug(chiakiGui) << "  HTTP Status:" << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qCDebug(chiakiGui) << "  Response Size:" << data.size() << "bytes";
        qCDebug(chiakiGui) << "  Response Body:" << QString::fromUtf8(data);
        
        const QJsonDocument jsonDocument = QJsonDocument::fromJson(data);
        emit requestFinished(url, jsonDocument);
    } else {
        // Always log errors
        qCWarning(chiakiGui) << "PSN request error:" << url << "-" << reply->errorString();
        
        // Log error details only in verbose mode
        qCDebug(chiakiGui) << "  Error Code:" << reply->error();
        
        emit requestError(url, reply->errorString(), reply->error());
    }

    reply->deleteLater();
}
