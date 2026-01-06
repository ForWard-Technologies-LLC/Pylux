// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudcatalogbackend.h"
#include "cloudstreamingbackend.h"
#include "cloudstreaming/pskamajisession.h"
#include "steamtools.h"
#include <chiaki/remote/holepunch.h>
#include <QLoggingCategory>
#include <QUrlQuery>
#include <QRegularExpression>
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
#include <QProcessEnvironment>
#include <QImageReader>
#include <QPainter>
#include <QPixmap>
#include <climits>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui)

// PSNOW category IDs (alphabetical categories)
// PSNOW categories are now dynamically fetched from the stores endpoint

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
    
    // Initialize state
    psnowState.currentCategoryIndex = -1;
    psnowState.rateLimitTimer = new QTimer(this);
    psnowState.rateLimitTimer->setSingleShot(true);
    psnowState.rateLimitTimer->setInterval(100); // 100ms cooldown between API calls
    psnowState.oauthCode = QString();
    psnowState.jsessionId = QString();
    psnowState.baseUrl = QString();
    psnowState.duid = QString();
    psnowState.authInProgress = false;
    
    // Initialize game details cooldown timer
    gameDetailsState.cooldownTimer = new QTimer(this);
    gameDetailsState.cooldownTimer->setSingleShot(true);
    gameDetailsState.cooldownTimer->setInterval(100); // 100ms cooldown between game details calls
    
    // Initialize cross-reference state
    crossReferenceState.callback = QJSValue();
    crossReferenceState.cloudCatalogGames = QJsonArray();
    crossReferenceState.ownedGames = QJsonArray();
    crossReferenceState.catalogFetched = false;
    crossReferenceState.ownedGamesFetched = false;
}

CloudCatalogBackend::~CloudCatalogBackend()
{
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

void CloudCatalogBackend::fetchPsnowCatalog(const QJSValue &callback)
{
    // Check cache first
    QString cached = getCachedData("psnow_catalog", CACHE_DURATION_CATALOG);
    if (!cached.isEmpty()) {
        qInfo() << "[CACHE] Using cached PSNOW catalog (skipping API calls)";
        QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
        if (callback.isCallable()) {
            callback.call({true, "Cached", QJSValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)))});
        }
        return;
    }
    
    // Check if already authenticating
    if (psnowState.authInProgress) {
        qInfo() << "[PSNOW] Authentication already in progress, skipping duplicate request";
        if (callback.isCallable()) {
            callback.call({false, "Request already in progress", QJSValue()});
        }
        return;
    }
    
    // Check NPSSO token - required for authentication
    QString npsso = getNpSsoToken();
    if (npsso.isEmpty()) {
        QString errorMsg = "NPSSO token is required for PSNOW catalog. Please login to PSN and enter a valid NPSSO token.";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (callback.isCallable()) {
            callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    qInfo() << "[API CALL] Fetching PSNOW catalog from API (cache miss or expired)";
    
    // Initialize fetch state
    psnowState.callback = callback;
    psnowState.allGames = QJsonArray();
    psnowState.categories = QStringList();
    psnowState.currentCategoryIndex = 0;
    psnowState.authInProgress = true;
    psnowState.oauthCode.clear();
    psnowState.jsessionId.clear();
    psnowState.baseUrl.clear();
    psnowState.duid.clear();
    
    // Start authentication flow: OAuth -> Session -> Stores -> Categories
    fetchPsnowOAuthToken();
}

void CloudCatalogBackend::fetchPsnowOAuthToken()
{
    QString npsso = getNpSsoToken();
    if (npsso.isEmpty()) {
        psnowState.authInProgress = false;
        QString errorMsg = "NPSSO token is required for PSNOW catalog. Please login to PSN and enter a valid NPSSO token.";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // Generate DUID dynamically (matching CloudStreamingBackend)
    size_t duid_size = CHIAKI_DUID_STR_SIZE;
    char duid_arr[duid_size];
    ChiakiErrorCode duid_err = chiaki_holepunch_generate_client_device_uid(duid_arr, &duid_size);
    if (duid_err != CHIAKI_ERR_SUCCESS) {
        psnowState.authInProgress = false;
        QString errorMsg = "Failed to generate device UID for PSNOW OAuth authentication.";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    psnowState.duid = QString(duid_arr);
    
    QUrl url(CloudConfig::ACCOUNT_BASE + "/v1/oauth/authorize");
    QUrlQuery query;
    query.addQueryItem("smcid", "pc:psnow");
    query.addQueryItem("applicationId", "psnow");
    query.addQueryItem("response_type", "code");
    query.addQueryItem("scope", KamajiConsts::PS4_SCOPES);
    query.addQueryItem("client_id", KamajiConsts::CLIENT_ID);
    query.addQueryItem("redirect_uri", KamajiConsts::REDIRECT_URI);
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    query.addQueryItem("renderMode", "mobilePortrait");
    query.addQueryItem("hidePageElements", "forgotPasswordLink");
    query.addQueryItem("displayFooter", "none");
    query.addQueryItem("disableLinks", "qriocityLink");
    query.addQueryItem("mid", "PSNOW");
    query.addQueryItem("duid", psnowState.duid);
    query.addQueryItem("layout_type", "popup");
    query.addQueryItem("service_logo", "ps");
    query.addQueryItem("tp_psn", "true");
    query.addQueryItem("noEVBlock", "true");
    url.setQuery(query);
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW OAuth Token Request ===";
        qInfo() << "  URL:" << url.toString();
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", KamajiConsts::USER_AGENT.toUtf8());
    req.setRawHeader("Cookie", QString("npsso=%1").arg(npsso).toUtf8());
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    QNetworkReply *reply = networkManager->get(req);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePsnowOAuthResponse);
}

void CloudCatalogBackend::handlePsnowOAuthResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW OAuth Response ===";
        qInfo() << "  Status:" << statusCode;
    }
    
    QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
    if (redirectUrl.isEmpty()) {
        QByteArray locationHeader = reply->rawHeader("Location");
        if (!locationHeader.isEmpty()) {
            redirectUrl = QUrl::fromEncoded(locationHeader);
        }
    }
    
    if (redirectUrl.isEmpty() || statusCode != 302) {
        psnowState.authInProgress = false;
        QString errorMsg = "OAuth request failed for PSNOW catalog";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // Extract code from redirect URL
    QUrlQuery query(redirectUrl);
    QString code = query.queryItemValue("code");
    
    if (code.isEmpty()) {
        // Try fragment
        QString fragment = redirectUrl.fragment();
        QRegularExpression codeRe("code=([^&]+)");
        QRegularExpressionMatch codeMatch = codeRe.match(fragment);
        if (codeMatch.hasMatch()) {
            code = codeMatch.captured(1);
        }
    }
    
    if (code.isEmpty()) {
        psnowState.authInProgress = false;
        QString errorMsg = "No authorization code in OAuth response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    psnowState.oauthCode = code;
    qInfo() << "[PSNOW] Got OAuth code, creating session...";
    fetchPsnowSession();
}

void CloudCatalogBackend::fetchPsnowSession()
{
    QString url = KamajiConsts::KAMAJI_BASE + "/user/session";
    QString body = QString("code=%1&client_id=%2&duid=%3")
        .arg(psnowState.oauthCode)
        .arg(KamajiConsts::CLIENT_ID)
        .arg(psnowState.duid);
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Session Request ===";
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: POST";
        qInfo() << "  Body:" << body;
    }
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Content-Type", "text/plain;charset=UTF-8");
    req.setRawHeader("User-Agent", KamajiConsts::USER_AGENT.toUtf8());
    req.setRawHeader("X-Alt-Referer", KamajiConsts::REDIRECT_URI.toUtf8());
    req.setRawHeader("Origin", KamajiConsts::ORIGIN.toUtf8());
    req.setRawHeader("Referer", KamajiConsts::REFERER.toUtf8());
    req.setRawHeader("Accept", "*/*");
    
    QNetworkReply *reply = networkManager->post(req, body.toUtf8());
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePsnowSessionResponse);
}

void CloudCatalogBackend::handlePsnowSessionResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray response = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Session Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Body:" << QString(response);
    }
    
    if (reply->error() != QNetworkReply::NoError || statusCode != 200) {
        psnowState.authInProgress = false;
        QString errorMsg = QString("Session creation failed: %1").arg(reply->errorString());
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(response);
    if (!doc.isObject()) {
        psnowState.authInProgress = false;
        QString errorMsg = "Invalid JSON in session response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QJsonObject obj = doc.object();
    QJsonObject header = obj["header"].toObject();
    QJsonObject data = obj["data"].toObject();
    
    if (header["status_code"].toString() != "0x0000") {
        psnowState.authInProgress = false;
        QString errorMsg = QString("Session failed with status: %1").arg(header["status_code"].toString());
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // Extract JSESSIONID from Set-Cookie header
    QList<QNetworkReply::RawHeaderPair> headers = reply->rawHeaderPairs();
    for (const auto &headerPair : headers) {
        if (headerPair.first.toLower() == "set-cookie") {
            QString setCookieValue = QString::fromUtf8(headerPair.second);
            QRegularExpression jsessionRegex("JSESSIONID=([^;]+)");
            QRegularExpressionMatch match = jsessionRegex.match(setCookieValue);
            if (match.hasMatch()) {
                psnowState.jsessionId = match.captured(1);
                break;
            }
        }
    }
    
    if (psnowState.jsessionId.isEmpty()) {
        psnowState.authInProgress = false;
        QString errorMsg = "No JSESSIONID in session response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // Save country and language from session response to settings
    QString country = data["country"].toString();
    QString language = data["language"].toString();
    if (!country.isEmpty() && !language.isEmpty()) {
        // Format: language-COUNTRY (e.g., "nl-NL" or "en-US")
        QString locale = QString("%1-%2").arg(language, country.toUpper());
        if (settings) {
            QString previousLocale = settings->GetCloudLanguagePSCloud();
            settings->SetCloudLanguagePSCloud(locale);
            qInfo() << "[PSNOW] Saved locale from session:" << locale;
            
            // Invalidate cache if locale changed
            if (previousLocale != locale) {
                qInfo() << "[PSNOW] Locale changed from" << previousLocale << "to" << locale << "- invalidating cache";
                invalidateCache();
            }
        }
    }
    
    qInfo() << "[PSNOW] Session created successfully, fetching stores...";
    fetchPsnowStores();
}

void CloudCatalogBackend::fetchPsnowStores()
{
    QString url = KamajiConsts::KAMAJI_BASE + "/user/stores";
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Stores Request ===";
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("User-Agent", KamajiConsts::USER_AGENT.toUtf8());
    req.setRawHeader("Cookie", QString("JSESSIONID=%1").arg(psnowState.jsessionId).toUtf8());
    req.setRawHeader("Origin", KamajiConsts::ORIGIN.toUtf8());
    req.setRawHeader("Referer", KamajiConsts::REFERER.toUtf8());
    req.setRawHeader("Accept", "application/json");
    
    QNetworkReply *reply = networkManager->get(req);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePsnowStoresResponse);
}

void CloudCatalogBackend::handlePsnowStoresResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray response = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Stores Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Body:" << QString(response);
    }
    
    if (reply->error() != QNetworkReply::NoError || statusCode != 200) {
        psnowState.authInProgress = false;
        QString errorMsg = QString("Stores request failed: %1").arg(reply->errorString());
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(response);
    if (!doc.isObject()) {
        psnowState.authInProgress = false;
        QString errorMsg = "Invalid JSON in stores response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QJsonObject obj = doc.object();
    QJsonObject header = obj["header"].toObject();
    QJsonObject data = obj["data"].toObject();
    
    if (header["status_code"].toString() != "0x0000") {
        psnowState.authInProgress = false;
        QString errorMsg = QString("Stores request failed with status: %1").arg(header["status_code"].toString());
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QString baseUrl = data["base_url"].toString();
    if (baseUrl.isEmpty()) {
        psnowState.authInProgress = false;
        QString errorMsg = "No base_url in stores response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    psnowState.baseUrl = baseUrl;
    
    qInfo() << "[PSNOW] Stores fetched successfully, base URL:" << baseUrl;
    
    // Fetch the root container to get dynamic category URLs
    fetchPsnowRootContainer();
}

void CloudCatalogBackend::fetchPsnowRootContainer()
{
    // Fetch root container endpoint with ?size=100
    QString rootUrl = psnowState.baseUrl + "?size=100";
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Root Container Request ===";
        qInfo() << "  URL:" << rootUrl;
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest req{QUrl(rootUrl)};
    req.setRawHeader("User-Agent", KamajiConsts::USER_AGENT.toUtf8());
    req.setRawHeader("Cookie", QString("JSESSIONID=%1").arg(psnowState.jsessionId).toUtf8());
    req.setRawHeader("Origin", KamajiConsts::ORIGIN.toUtf8());
    req.setRawHeader("Referer", KamajiConsts::REFERER.toUtf8());
    req.setRawHeader("Accept", "application/json");
    
    QNetworkReply *reply = networkManager->get(req);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePsnowRootContainerResponse);
}

void CloudCatalogBackend::handlePsnowRootContainerResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    reply->deleteLater();
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray response = reply->readAll();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Root Container Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Body:" << QString(response);
    }
    
    if (reply->error() != QNetworkReply::NoError || statusCode != 200) {
        psnowState.authInProgress = false;
        QString errorMsg = QString("Root container request failed: %1").arg(reply->errorString());
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QJsonDocument doc = QJsonDocument::fromJson(response);
    if (!doc.isObject()) {
        psnowState.authInProgress = false;
        QString errorMsg = "Invalid JSON in root container response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    QJsonObject obj = doc.object();
    QJsonArray links = obj["links"].toArray();
    
    // Alphabetical category name patterns to match
    QStringList categoryPatterns = {
        "A - B",
        "C - D",
        "E - G",
        "H - L",
        "M - O",
        "P - R",
        "S",
        "T",
        "U - Z"
    };
    
    QStringList categoryUrls;
    
    // Extract URLs from links that match alphabetical category patterns
    for (const QJsonValue &linkValue : links) {
        QJsonObject link = linkValue.toObject();
        QString name = link["name"].toString();
        
        // Check if this link matches any of our category patterns
        if (categoryPatterns.contains(name)) {
            QString url = link["url"].toString();
            if (!url.isEmpty()) {
                categoryUrls.append(url);
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "[PSNOW] Found category:" << name << "URL:" << url;
                }
            }
        }
    }
    
    if (categoryUrls.isEmpty()) {
        psnowState.authInProgress = false;
        QString errorMsg = "No alphabetical category URLs found in root container response";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (psnowState.callback.isCallable()) {
            psnowState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    psnowState.categories = categoryUrls;
    psnowState.authInProgress = false;
    
    qInfo() << "[PSNOW] Root container fetched successfully, extracted" << categoryUrls.size() << "alphabetical category URLs";
    
    // Now start fetching categories
    psnowState.allGames = QJsonArray();
    psnowState.currentCategoryIndex = 0;
    fetchPsnowCategory(0);
}

void CloudCatalogBackend::fetchPsnowCategory(int categoryIndex)
{
    if (categoryIndex >= psnowState.categories.size()) {
        // All categories fetched, process and return
        processPsnowCatalogComplete();
        return;
    }
    
    // Check if we have categories (from stores endpoint)
    if (psnowState.categories.isEmpty()) {
        qWarning() << "PSNOW categories not available - authentication may not have completed";
        return;
    }
    
    // Use the URL directly from the root container response
    QString url = psnowState.categories[categoryIndex];
    
    // Append query parameters if not already present
    if (!url.contains("?")) {
        url = QString("%1?start=0&size=500").arg(url);
    } else {
        // URL already has query parameters, append ours
        url = QString("%1&start=0&size=500").arg(url);
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Fetching PSNOW category ===";
        qInfo() << "  Category Index:" << categoryIndex;
        qInfo() << "  URL:" << url;
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest request{QUrl(url)};
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("Accept", "application/json");
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    
    QNetworkReply *reply = networkManager->get(request);
    reply->setProperty("categoryIndex", categoryIndex);
    
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePsnowCategoryResponse);
}

void CloudCatalogBackend::handlePsnowCategoryResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    int categoryIndex = reply->property("categoryIndex").toInt();
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PSNOW Category Response ===";
        qInfo() << "  Category Index:" << categoryIndex;
        qInfo() << "  Status:" << statusCode;
    }
    
    reply->deleteLater();
    
    if (reply->error() != QNetworkReply::NoError) {
        QString errorMsg = QString("PSNOW category fetch error: %1").arg(reply->errorString());
        qWarning() << errorMsg;
        // Report error to callback if this is the last category or if we haven't collected any games
        if (psnowState.allGames.isEmpty() && psnowState.currentCategoryIndex >= psnowState.categories.size() - 1) {
            if (psnowState.callback.isCallable()) {
                psnowState.callback.call({false, errorMsg, QJSValue()});
            }
            return;
        }
        // Continue with next category even on error
        psnowState.currentCategoryIndex = categoryIndex + 1;
        if (psnowState.currentCategoryIndex < psnowState.categories.size()) {
            psnowState.rateLimitTimer->start();
            connect(psnowState.rateLimitTimer, &QTimer::timeout, this, [this, categoryIndex]() {
                fetchPsnowCategory(categoryIndex + 1);
            }, Qt::SingleShotConnection);
        } else {
            processPsnowCatalogComplete();
        }
        return;
    }
    
    QByteArray data = reply->readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (doc.isObject()) {
        QJsonObject obj = doc.object();
        if (obj.contains("links") && obj["links"].isArray()) {
            QJsonArray links = obj["links"].toArray();
            int gameCount = 0;
            for (const QJsonValue &link : links) {
                if (link.isObject()) {
                    QJsonObject gameObj = link.toObject();
                    
                    // Extract cover image from catalog response if available
                    // Check for images in the game object
                    QString coverImageUrl = extractCoverImageFromGameObject(gameObj);
                    if (!coverImageUrl.isEmpty()) {
                        // Add imageUrl field for easy access
                        gameObj["imageUrl"] = coverImageUrl;
                    }
                    
                    psnowState.allGames.append(gameObj);
                    gameCount++;
                }
            }
            if (settings && settings->GetLogVerbose()) {
                qInfo() << "  Games in category:" << gameCount;
            }
        }
    }
    
    // Move to next category with rate limiting
    psnowState.currentCategoryIndex = categoryIndex + 1;
    if (psnowState.currentCategoryIndex < psnowState.categories.size()) {
        psnowState.rateLimitTimer->start();
        connect(psnowState.rateLimitTimer, &QTimer::timeout, this, [this]() {
            fetchPsnowCategory(psnowState.currentCategoryIndex);
        }, Qt::SingleShotConnection);
    } else {
        processPsnowCatalogComplete();
    }
}

void CloudCatalogBackend::processPsnowCatalogComplete()
{
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Processing PSNOW catalog complete ===";
        qInfo() << "  Total games before deduplication:" << psnowState.allGames.size();
    }
    
    // Remove duplicates by product ID
    QMap<QString, QJsonObject> uniqueGames;
    for (const QJsonValue &game : psnowState.allGames) {
        if (game.isObject()) {
            QJsonObject gameObj = game.toObject();
            QString id = gameObj["id"].toString();
            if (!id.isEmpty() && !uniqueGames.contains(id)) {
                uniqueGames[id] = gameObj;
            }
        }
    }
    
    // Convert back to array and ensure images are extracted
    QJsonArray finalGames;
    for (const QJsonObject &game : uniqueGames.values()) {
        QJsonObject gameObj = game;
        
        // Extract cover image if not already present
        if (!gameObj.contains("imageUrl") || gameObj["imageUrl"].toString().isEmpty()) {
            QString coverImageUrl = extractCoverImageFromGameObject(gameObj);
            if (!coverImageUrl.isEmpty()) {
                gameObj["imageUrl"] = coverImageUrl;
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "  Extracted cover image for:" << gameObj["name"].toString();
                }
            }
        }
        
        finalGames.append(gameObj);
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  Unique games after deduplication:" << finalGames.size();
    }
    
    QJsonObject result;
    result["games"] = finalGames;
    result["total"] = finalGames.size();
    
    QJsonDocument resultDoc(result);
    
    // Cache the result
    setCachedData("psnow_catalog", resultDoc);
    
    // Call callback
    if (psnowState.callback.isCallable()) {
        QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        psnowState.callback.call({true, "Success", QJSValue(jsonStr)});
    }
    
    emit catalogUpdated();
}

void CloudCatalogBackend::fetchPs5CloudCatalog(const QJSValue &callback)
{
    // Get locale from unified language setting and convert to lowercase for API
    QString localeSetting = settings ? settings->GetCloudLanguagePSCloud() : "en-US";
    QString locale = localeSetting.toLower(); // Convert "en-US" to "en-us"
    
    // Check cache first
    QString cached = getCachedData("ps5_cloud_catalog", CACHE_DURATION_CATALOG);
    if (!cached.isEmpty()) {
        qInfo() << "[CACHE] Using cached PS5 cloud catalog";
        QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
        if (callback.isCallable()) {
            callback.call({true, "Cached", QJSValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)))});
        }
        return;
    }
    
    qInfo() << "[API CALL] Fetching PS5 cloud catalog from API (cache miss or expired)";
    ps5State.callback = callback;
    
    QString url = QString("https://www.playstation.com/bin/imagic/gameslist?locale=%1&categoryList=all-ps5-list").arg(locale);
    
    QNetworkRequest request{QUrl(url)};
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("Accept", "application/json");
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    
    QNetworkReply *reply = networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePs5CatalogResponse);
}

void CloudCatalogBackend::handlePs5CatalogResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PS5 Catalog Response ===";
        qInfo() << "  Status:" << statusCode;
    }
    
    reply->deleteLater();
    
    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "PS5 catalog fetch error:" << reply->errorString();
        if (ps5State.callback.isCallable()) {
            ps5State.callback.call({false, reply->errorString(), QJSValue()});
        }
        return;
    }
    
    QByteArray data = reply->readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (!doc.isArray()) {
        if (ps5State.callback.isCallable()) {
            ps5State.callback.call({false, "Invalid response format", QJSValue()});
        }
        return;
    }
    
    // Flatten all games from all categories and filter for streaming support
    QJsonArray allGames;
    QJsonArray categories = doc.array();
    int totalGames = 0;
    int streamingGames = 0;
    
    for (const QJsonValue &category : categories) {
        if (category.isObject()) {
            QJsonObject catObj = category.toObject();
            if (catObj.contains("games") && catObj["games"].isArray()) {
                QJsonArray games = catObj["games"].toArray();
                totalGames += games.size();
                for (const QJsonValue &game : games) {
                    if (game.isObject()) {
                        QJsonObject gameObj = game.toObject();
                        // Filter for streamingSupported: true
                        if (gameObj.contains("streamingSupported") && gameObj["streamingSupported"].toBool()) {
                            // Ensure imageUrl is present (PS5 Cloud games should have it, but verify)
                            if (!gameObj.contains("imageUrl") || gameObj["imageUrl"].toString().isEmpty()) {
                                QString coverImageUrl = extractCoverImageFromGameObject(gameObj);
                                if (!coverImageUrl.isEmpty()) {
                                    gameObj["imageUrl"] = coverImageUrl;
                                }
                            }
                            allGames.append(gameObj);
                            streamingGames++;
                        }
                    }
                }
            }
        }
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  Total games:" << totalGames;
        qInfo() << "  Streaming-supported games:" << streamingGames;
    }
    
    QJsonObject result;
    result["games"] = allGames;
    result["total"] = allGames.size();
    
    QJsonDocument resultDoc(result);
    
    // Cache the result
    setCachedData("ps5_cloud_catalog", resultDoc);
    
    // If cross-reference is active, populate its state
    if (crossReferenceState.callback.isCallable() && !crossReferenceState.catalogFetched) {
        crossReferenceState.cloudCatalogGames = allGames;
        crossReferenceState.catalogFetched = true;
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "[CROSS-REF] Fetched PS5 cloud catalog from API:" << allGames.size() << "games";
        }
        // Check if both are fetched now
        if (crossReferenceState.catalogFetched && crossReferenceState.ownedGamesFetched) {
            processCrossReferenceComplete();
        }
    }
    
    // Call callback
    if (ps5State.callback.isCallable()) {
        QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        ps5State.callback.call({true, "Success", QJSValue(jsonStr)});
    }
    
    emit catalogUpdated();
}

void CloudCatalogBackend::fetchOwnedPs5Games(const QJSValue &callback)
{
    // Check NPSSO token first - fail immediately if not present
    QString npsso = getNpSsoToken();
    if (npsso.isEmpty()) {
        QString errorMsg = "NPSSO token is required for PS5 cloud play. Please login to PSN and enter a valid NPSSO token. You also need a valid PS Plus subscription.";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (callback.isCallable()) {
            callback.call({false, errorMsg, QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // Check cache first
    QString cached = getCachedData("ps5_cloud_library", CACHE_DURATION_CATALOG);
    if (!cached.isEmpty()) {
        qInfo() << "[CACHE] Using cached PS5 cloud library (skipping API calls)";
        QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
        if (callback.isCallable()) {
            callback.call({true, "Cached", QJSValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)))});
        }
        return;
    }
    
    qInfo() << "[API CALL] Fetching PS5 cloud library from API (cache miss or expired)";
    ownedGamesState.callback = callback;
    
    // Clear any existing OAuth token to ensure we fetch a fresh one
    ownedGamesState.oauthToken.clear();
    
    // First, get OAuth token for entitlements API
    fetchOwnedGamesOAuthToken();
}

void CloudCatalogBackend::fetchOwnedGamesOAuthToken()
{
    // NPSSO token should already be checked in fetchOwnedPs5Games, but double-check here for safety
    QString npsso = getNpSsoToken();
    if (npsso.isEmpty()) {
        QString errorMsg = "NPSSO token is required for PS5 cloud play. Please login to PSN and enter a valid NPSSO token. You also need a valid PS Plus subscription.";
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, errorMsg, QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Fetching OAuth token for owned games ===";
    }
    
    // Get OAuth token for entitlements API
    QString url = CloudConfig::ACCOUNT_BASE + "/v1/oauth/authorize";
    QUrlQuery query;
    query.addQueryItem("response_type", "token");
    query.addQueryItem("scope", "kamaji:get_internal_entitlements user:account.attributes.validate");
    query.addQueryItem("client_id", "dc523cc2-b51b-4190-bff0-3397c06871b3");
    query.addQueryItem("redirect_uri", KamajiConsts::REDIRECT_URI);
    query.addQueryItem("service_entity", "urn:service-entity:psn");
    query.addQueryItem("prompt", "none");
    
    QUrl fullUrl(url);
    fullUrl.setQuery(query);
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  URL:" << fullUrl.toString();
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest request{fullUrl};
    request.setRawHeader("Cookie", QString("npsso=%1").arg(npsso).toUtf8());
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    
    QNetworkReply *reply = networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handleOwnedGamesOAuthResponse);
}

void CloudCatalogBackend::handleOwnedGamesOAuthResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: OAuth Token Response ===";
        qInfo() << "  Status:" << statusCode;
        qInfo() << "  Headers:";
        for (const auto &header : reply->rawHeaderPairs()) {
            qInfo() << "    " << header.first << ":" << header.second;
        }
    }
    
    reply->deleteLater();
    
    if (statusCode != 302) {
        QString errorMsg = QString("OAuth request failed: Expected 302, got %1").arg(statusCode);
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        // Clear OAuth token on failure to prevent reuse of invalid token
        ownedGamesState.oauthToken.clear();
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, errorMsg, QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // OAuth flow returns 302 redirect with token in Location header
    QUrl redirectUrl = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
    if (redirectUrl.isEmpty()) {
        QByteArray locationHeader = reply->rawHeader("Location");
        if (!locationHeader.isEmpty()) {
            redirectUrl = QUrl::fromEncoded(locationHeader);
        }
    }
    
    if (redirectUrl.isEmpty()) {
        qWarning() << "CloudCatalogBackend: No redirect URL in OAuth response";
        // Clear OAuth token on failure to prevent reuse of invalid token
        ownedGamesState.oauthToken.clear();
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, "OAuth redirect not received", QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, "OAuth redirect not received", QJSValue()});
        }
        return;
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  Redirect URL:" << redirectUrl.toString();
    }
    
    // Check for errors in the redirect URL (both query and fragment)
    QUrlQuery query = QUrlQuery(redirectUrl.query());
    QString errorParam = query.queryItemValue("error");
    QString errorDescription = query.queryItemValue("error_description");
    
    // Also check fragment for errors
    QString fragment = redirectUrl.fragment();
    if (errorParam.isEmpty() && fragment.contains("error=")) {
        QRegularExpression errorRe("error=([^&]+)");
        QRegularExpressionMatch errorMatch = errorRe.match(fragment);
        if (errorMatch.hasMatch()) {
            errorParam = errorMatch.captured(1);
        }
    }
    
    // If there's an error, show a user-friendly message
    if (!errorParam.isEmpty()) {
        QString errorMsg;
        if (errorParam == "login_required" || errorParam.contains("login", Qt::CaseInsensitive)) {
            errorMsg = "Authentication failed. Please login to PSN and enter a valid NPSSO token. You also need a valid PS Plus subscription to access cloud play.";
        } else {
            errorMsg = QString("OAuth authentication failed: %1").arg(errorDescription.isEmpty() ? errorParam : errorDescription);
        }
        qWarning() << "CloudCatalogBackend: OAuth error:" << errorParam << errorDescription;
        // Clear OAuth token on failure to prevent reuse of invalid token
        ownedGamesState.oauthToken.clear();
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, errorMsg, QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    // Extract access_token from fragment
    QRegularExpression re("access_token=([^&]+)");
    QRegularExpressionMatch match = re.match(fragment);
    if (match.hasMatch()) {
        ownedGamesState.oauthToken = match.captured(1);
        
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "  Extracted access token:" << ownedGamesState.oauthToken.left(20) << "...";
        }
        
        // Apply 100ms cooldown before fetching owned games (after OAuth)
        QTimer::singleShot(100, this, [this]() {
            // Reset pagination state
            ownedGamesState.accumulatedEntitlements = QJsonArray();
            ownedGamesState.currentStart = 0;
            
            // Start fetching first page
            fetchOwnedGamesPage();
        });
    } else {
        // Check if the redirect URL itself indicates an error
        QString redirectStr = redirectUrl.toString();
        if (redirectStr.contains("error=", Qt::CaseInsensitive)) {
            QString errorMsg = "Authentication failed. Please login to PSN and enter a valid NPSSO token. You also need a valid PS Plus subscription to access cloud play.";
            qWarning() << "CloudCatalogBackend: OAuth error in redirect URL";
            if (ownedGamesState.callback.isCallable()) {
                ownedGamesState.callback.call({false, errorMsg, QJSValue()});
            } else if (crossReferenceState.callback.isCallable()) {
                crossReferenceState.callback.call({false, errorMsg, QJSValue()});
            }
        } else {
            qWarning() << "CloudCatalogBackend: Could not extract access token from fragment:" << fragment;
            QString errorMsg = "Could not extract access token from OAuth response. Please ensure you have logged in to PSN and entered a valid NPSSO token, and that you have a valid PS Plus subscription.";
            // Clear OAuth token on failure to prevent reuse of invalid token
            ownedGamesState.oauthToken.clear();
            if (ownedGamesState.callback.isCallable()) {
                ownedGamesState.callback.call({false, errorMsg, QJSValue()});
            } else if (crossReferenceState.callback.isCallable()) {
                crossReferenceState.callback.call({false, errorMsg, QJSValue()});
            }
        }
    }
}

void CloudCatalogBackend::fetchOwnedGamesPage()
{
    QString url = "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements";
    QUrlQuery query;
    query.addQueryItem("fields", "game_meta");
    query.addQueryItem("entitlement_type", "5");
    query.addQueryItem("start", QString::number(ownedGamesState.currentStart));
    query.addQueryItem("size", QString::number(OwnedGamesState::PAGE_SIZE));
    
    QUrl fullUrl(url);
    fullUrl.setQuery(query);
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Fetching owned games (page) ===";
        qInfo() << "  URL:" << fullUrl.toString();
        qInfo() << "  Start:" << ownedGamesState.currentStart << "Size:" << OwnedGamesState::PAGE_SIZE;
        qInfo() << "  Method: GET";
    }
    
    QNetworkRequest request{fullUrl};
    request.setRawHeader("Authorization", QString("Bearer %1").arg(ownedGamesState.oauthToken).toUtf8());
    request.setRawHeader("Accept", "application/json");
    
    QNetworkReply *gamesReply = networkManager->get(request);
    connect(gamesReply, &QNetworkReply::finished, this, &CloudCatalogBackend::handleOwnedGamesResponse);
}

void CloudCatalogBackend::handleOwnedGamesResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: Owned Games Response ===";
        qInfo() << "  Status:" << statusCode;
    }
    
    reply->deleteLater();
    
    // Check for authentication errors (401, 403)
    if (statusCode == 401 || statusCode == 403) {
        QString errorMsg = "Authentication failed. Please login to PSN and enter a valid NPSSO token. You also need a valid PS Plus subscription to access cloud play.";
        qWarning() << "CloudCatalogBackend: Authentication error (HTTP" << statusCode << ")";
        // Clear OAuth token on authentication failure - token is invalid/expired
        ownedGamesState.oauthToken.clear();
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, errorMsg, QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, errorMsg, QJSValue()});
        }
        return;
    }
    
    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "Owned games fetch error:" << reply->errorString();
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, reply->errorString(), QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, reply->errorString(), QJSValue()});
        }
        return;
    }
    
    QByteArray data = reply->readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (!doc.isObject()) {
        if (ownedGamesState.callback.isCallable()) {
            ownedGamesState.callback.call({false, "Invalid response format", QJSValue()});
        } else if (crossReferenceState.callback.isCallable()) {
            crossReferenceState.callback.call({false, "Invalid response format", QJSValue()});
        }
        return;
    }
    
    QJsonObject obj = doc.object();
    
    // Get entitlements from this page
    QJsonArray pageEntitlements;
    if (obj.contains("entitlements") && obj["entitlements"].isArray()) {
        pageEntitlements = obj["entitlements"].toArray();
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  Page entitlements:" << pageEntitlements.size();
        qInfo() << "  Accumulated so far:" << ownedGamesState.accumulatedEntitlements.size();
    }
    
    // Accumulate entitlements from this page
    for (const QJsonValue &ent : pageEntitlements) {
        ownedGamesState.accumulatedEntitlements.append(ent);
    }
    
    // Check if we need to fetch more pages (got a full page means more may exist)
    if (pageEntitlements.size() >= OwnedGamesState::PAGE_SIZE) {
        ownedGamesState.currentStart += pageEntitlements.size();
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "  More pages to fetch... scheduling next page";
        }
        // Apply 100ms cooldown between page requests to avoid rate limiting
        QTimer::singleShot(100, this, &CloudCatalogBackend::fetchOwnedGamesPage);
        return;
    }
    
    // All pages fetched, process the accumulated results
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: All owned games pages fetched ===";
        qInfo() << "  Total accumulated entitlements:" << ownedGamesState.accumulatedEntitlements.size();
    }
    
    // Filter for PS5 games (package_type=PSGD)
    QJsonArray ps5Games = filterOwnedPs5Games(ownedGamesState.accumulatedEntitlements);
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  PS5 games (PSGD):" << ps5Games.size();
    }
    
    QJsonObject result;
    result["games"] = ps5Games;
    result["total"] = ps5Games.size();
    
    QJsonDocument resultDoc(result);
    
    // Cache the result
    setCachedData("ps5_cloud_library", resultDoc);
    
    // If cross-reference is active, populate its state
    if (crossReferenceState.callback.isCallable() && !crossReferenceState.ownedGamesFetched) {
        crossReferenceState.ownedGames = ps5Games;
        crossReferenceState.ownedGamesFetched = true;
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "[CROSS-REF] Fetched owned PS5 games from API:" << ps5Games.size() << "games";
        }
        // Check if both are fetched now
        if (crossReferenceState.catalogFetched && crossReferenceState.ownedGamesFetched) {
            processCrossReferenceComplete();
        }
    }
    
    // Call callback
    if (ownedGamesState.callback.isCallable()) {
        QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        ownedGamesState.callback.call({true, "Success", QJSValue(jsonStr)});
    }
}

QJsonArray CloudCatalogBackend::filterOwnedPs5Games(const QJsonArray &entitlements)
{
    QJsonArray ps5Games;
    
    for (const QJsonValue &ent : entitlements) {
        if (ent.isObject()) {
            QJsonObject entObj = ent.toObject();
            
            // Check for game_meta and package_type
            if (entObj.contains("game_meta") && entObj["game_meta"].isObject()) {
                QJsonObject gameMeta = entObj["game_meta"].toObject();
                QString packageType = gameMeta["package_type"].toString();
                
                // Filter for PS5 games (PSGD)
                if (packageType == "PSGD") {
                    // Skip subscriptions/services (Product IDs starting with IP or SUB)
                    QString productId = entObj["product_id"].toString();
                    if (!productId.startsWith("IP") && !productId.startsWith("SUB")) {
                        // Extract cover image from game_meta.icon_url (this is the primary field for entitlements API)
                        QString coverImageUrl;
                        
                        // Check game_meta.icon_url first (this is where the API returns images)
                        if (gameMeta.contains("icon_url")) {
                            coverImageUrl = gameMeta["icon_url"].toString();
                        }
                        
                        // Fallback: try extractCoverImageFromGameObject for images array if present
                        if (coverImageUrl.isEmpty()) {
                            coverImageUrl = extractCoverImageFromGameObject(gameMeta);
                        }
                        if (coverImageUrl.isEmpty()) {
                            coverImageUrl = extractCoverImageFromGameObject(entObj);
                        }
                        
                        // Additional fallbacks for other common image field names
                        if (coverImageUrl.isEmpty()) {
                            if (gameMeta.contains("imageUrl")) {
                                coverImageUrl = gameMeta["imageUrl"].toString();
                            } else if (gameMeta.contains("image_url")) {
                                coverImageUrl = gameMeta["image_url"].toString();
                            } else if (gameMeta.contains("thumbnail_url")) {
                                coverImageUrl = gameMeta["thumbnail_url"].toString();
                            } else if (entObj.contains("imageUrl")) {
                                coverImageUrl = entObj["imageUrl"].toString();
                            } else if (entObj.contains("image_url")) {
                                coverImageUrl = entObj["image_url"].toString();
                            } else if (entObj.contains("thumbnail_url")) {
                                coverImageUrl = entObj["thumbnail_url"].toString();
                            }
                        }
                        
                        if (!coverImageUrl.isEmpty()) {
                            entObj["imageUrl"] = coverImageUrl;
                            if (settings && settings->GetLogVerbose()) {
                                QString gameName = gameMeta.contains("name") ? gameMeta["name"].toString() : productId;
                                qInfo() << "  Extracted cover image for PS5 game:" << gameName << "from icon_url";
                            }
                        } else {
                            if (settings && settings->GetLogVerbose()) {
                                QString gameName = gameMeta.contains("name") ? gameMeta["name"].toString() : productId;
                                qInfo() << "  No image found in entitlement response for PS5 game:" << gameName;
                            }
                        }
                        
                        ps5Games.append(entObj);
                    }
                }
            }
        }
    }
    
    return ps5Games;
}

void CloudCatalogBackend::getOwnedPs5CloudGames(const QJSValue &callback)
{
    // This method cross-references owned PS5 games with the cloud catalog
    // First fetch both catalogs (checking cache first), then match by product_id
    
    // Initialize cross-reference state
    crossReferenceState.callback = callback;
    crossReferenceState.cloudCatalogGames = QJsonArray();
    crossReferenceState.ownedGames = QJsonArray();
    crossReferenceState.catalogFetched = false;
    crossReferenceState.ownedGamesFetched = false;
    
    // Check cache for both catalogs first
    QString cachedCatalog = getCachedData("ps5_cloud_catalog", CACHE_DURATION_CATALOG);
    
    QString cachedOwned = getCachedData("ps5_cloud_library", CACHE_DURATION_CATALOG);
    
    bool catalogFromCache = !cachedCatalog.isEmpty();
    bool ownedFromCache = !cachedOwned.isEmpty();
    
    if (catalogFromCache) {
        // Parse cached catalog
        QJsonDocument doc = QJsonDocument::fromJson(cachedCatalog.toUtf8());
        if (doc.isObject()) {
            QJsonObject obj = doc.object();
            if (obj.contains("games") && obj["games"].isArray()) {
                crossReferenceState.cloudCatalogGames = obj["games"].toArray();
                crossReferenceState.catalogFetched = true;
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "[CROSS-REF] Loaded PS5 cloud catalog from cache:" << crossReferenceState.cloudCatalogGames.size() << "games";
                }
            }
        }
    }
    
    if (ownedFromCache) {
        // Parse cached owned games
        QJsonDocument doc = QJsonDocument::fromJson(cachedOwned.toUtf8());
        if (doc.isObject()) {
            QJsonObject obj = doc.object();
            if (obj.contains("games") && obj["games"].isArray()) {
                crossReferenceState.ownedGames = obj["games"].toArray();
                crossReferenceState.ownedGamesFetched = true;
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "[CROSS-REF] Loaded owned PS5 games from cache:" << crossReferenceState.ownedGames.size() << "games";
                }
            }
        }
    }
    
    // If we have both from cache, process immediately
    if (catalogFromCache && ownedFromCache) {
        processCrossReferenceComplete();
        return;
    }
    
    // Fetch missing data - use existing methods but they will populate cross-reference state
    // via modified response handlers
    if (!catalogFromCache) {
        // Use empty callback - handler will check cross-reference state
        fetchPs5CloudCatalog(QJSValue());
    }
    
    if (!ownedFromCache) {
        // Use empty callback - handler will check cross-reference state
        fetchOwnedPs5Games(QJSValue());
    }
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
    QString localeSetting = settings ? settings->GetCloudLanguagePSCloud() : "en-US";
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

QString CloudCatalogBackend::extractCoverImageFromGameObject(const QJsonObject &gameObj)
{
    // Check for images array in the game object
    if (gameObj.contains("images") && gameObj["images"].isArray()) {
        QJsonArray imagesArray = gameObj["images"].toArray();
        
        // Prefer cover (type 10) over landscape (type 12/13)
        for (const QJsonValue &img : imagesArray) {
            if (img.isObject()) {
                QJsonObject imgObj = img.toObject();
                int type = imgObj["type"].toInt();
                QString url = imgObj["url"].toString();
                
                // Type 10 = cover/box art (preferred)
                if (type == 10 && !url.isEmpty()) {
                    return url;
                }
            }
        }
        
        // Fallback to landscape if no cover
        for (const QJsonValue &img : imagesArray) {
            if (img.isObject()) {
                QJsonObject imgObj = img.toObject();
                int type = imgObj["type"].toInt();
                QString url = imgObj["url"].toString();
                
                // Type 12 = landscape 1080p or Type 13 = landscape 720p
                if ((type == 12 || type == 13) && !url.isEmpty()) {
                    return url;
                }
            }
        }
    }
    
    // Check for direct imageUrl field
    if (gameObj.contains("imageUrl")) {
        QString imageUrl = gameObj["imageUrl"].toString();
        if (!imageUrl.isEmpty()) {
            return imageUrl;
        }
    }
    
    return QString();
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
    bool isPsCloudLibrary = false;
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
        cacheKey = "ps5_cloud_catalog";
        isPsCloudLibrary = false;
    } else {
        qWarning() << "getGameLandscapeImage: Unknown service type:" << serviceType;
        return QString();
    }
    
    // Load cache - use very large maxAge to never invalidate cache (read-only operation)
    QString cached = getCachedData(cacheKey, INT_MAX);
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

void CloudCatalogBackend::clearCache()
{
    // Clear all cache files
    QDir dir(cacheDirectory);
    if (dir.exists()) {
        QStringList filters;
        filters << "*.json";
        QFileInfoList files = dir.entryInfoList(filters, QDir::Files);
        for (const QFileInfo &fileInfo : files) {
            QFile::remove(fileInfo.absoluteFilePath());
        }
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "Cleared cache directory:" << cacheDirectory;
        }
    }
}

void CloudCatalogBackend::processCrossReferenceComplete()
{
    // Cross-reference owned games with cloud catalog
    // Create a lookup map from cloud catalog using productId as key
    QMap<QString, QJsonObject> cloudCatalogMap;
    for (const QJsonValue &game : crossReferenceState.cloudCatalogGames) {
        if (game.isObject()) {
            QJsonObject gameObj = game.toObject();
            QString productId = gameObj["productId"].toString();
            if (!productId.isEmpty()) {
                cloudCatalogMap[productId] = gameObj;
            }
        }
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "[CROSS-REF] Cloud catalog map size:" << cloudCatalogMap.size();
        qInfo() << "[CROSS-REF] Owned games count:" << crossReferenceState.ownedGames.size();
    }
    
    // Filter owned games to only include those in the cloud catalog
    QJsonArray filteredGames;
    int matchedCount = 0;
    
    for (const QJsonValue &ownedGame : crossReferenceState.ownedGames) {
        if (ownedGame.isObject()) {
            QJsonObject ownedGameObj = ownedGame.toObject();
            QString productId = ownedGameObj["product_id"].toString();
            
            // Check if this game is in the cloud catalog (meaning it supports streaming)
            if (cloudCatalogMap.contains(productId)) {
                // Game supports streaming - include it
                // Optionally merge data from cloud catalog (e.g., better images)
                QJsonObject cloudGame = cloudCatalogMap[productId];
                
                // Prefer cloud catalog imageUrl if available
                if (cloudGame.contains("imageUrl") && !cloudGame["imageUrl"].toString().isEmpty()) {
                    ownedGameObj["imageUrl"] = cloudGame["imageUrl"];
                }
                
                // Add streamingSupported flag for clarity
                ownedGameObj["streamingSupported"] = true;
                
                filteredGames.append(ownedGameObj);
                matchedCount++;
            }
            // If not in catalog, skip it (doesn't support streaming)
        }
    }
    
    if (settings && settings->GetLogVerbose()) {
        qInfo() << "[CROSS-REF] Matched games (cloud streamable):" << matchedCount;
    }
    
    // Prepare result
    QJsonObject result;
    result["games"] = filteredGames;
    result["total"] = filteredGames.size();
    
    QJsonDocument resultDoc(result);
    
    // Call callback with filtered results
    if (crossReferenceState.callback.isCallable()) {
        QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        crossReferenceState.callback.call({true, "Success", QJSValue(jsonStr)});
    }
    
    // Clear cross-reference state
    crossReferenceState.callback = QJSValue();
    crossReferenceState.cloudCatalogGames = QJsonArray();
    crossReferenceState.ownedGames = QJsonArray();
    crossReferenceState.catalogFetched = false;
    crossReferenceState.ownedGamesFetched = false;
}

void CloudCatalogBackend::invalidateCache()
{
    // Invalidate specific cache files (PSNOW, PS5 cloud catalog, and PS5 cloud library)
    QString psnowPath = getCacheFilePath("psnow_catalog");
    QString ps5CatalogPath = getCacheFilePath("ps5_cloud_catalog");
    QString ps5LibraryPath = getCacheFilePath("ps5_cloud_library");
    
    bool invalidated = false;
    if (QFile::exists(psnowPath)) {
        QFile::remove(psnowPath);
        qInfo() << "[CACHE INVALIDATED] Removed PSNOW catalog cache";
        invalidated = true;
    }
    
    if (QFile::exists(ps5CatalogPath)) {
        QFile::remove(ps5CatalogPath);
        qInfo() << "[CACHE INVALIDATED] Removed PS5 cloud catalog cache";
        invalidated = true;
    }
    
    if (QFile::exists(ps5LibraryPath)) {
        QFile::remove(ps5LibraryPath);
        qInfo() << "[CACHE INVALIDATED] Removed PS5 cloud library cache";
        invalidated = true;
    }
    
    if (!invalidated) {
        qInfo() << "[CACHE INVALIDATED] No cache files found to invalidate";
    }
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
    
    // If running from extracted PSStream directory, use launch.sh instead of direct executable
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
}


