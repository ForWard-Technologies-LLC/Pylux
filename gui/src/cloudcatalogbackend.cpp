// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudcatalogbackend.h"
#include "cloudstreamingbackend.h"
#include "cloudstreaming/pskamajisession.h"
#ifdef CHIAKI_GUI_ENABLE_STEAM_SHORTCUT
#include "steamtools.h"
#endif
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
    crossReferenceState.plusLibrarySupplement = QJsonArray();
    crossReferenceState.ownedGames = QJsonArray();
    crossReferenceState.productIdAliases.clear();
    crossReferenceState.componentIdsByProductId.clear();
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

    const QString expectedLocale = settings ? settings->GetCloudLanguagePSCloud() : QStringLiteral("en-US");
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
        QString errorMsg = "NPSSO token is required for Game Catalog. Please login to PSN and enter a valid NPSSO token.";
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
        QString errorMsg = "NPSSO token is required for Game Catalog. Please login to PSN and enter a valid NPSSO token.";
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
    if (!country.isEmpty() && !language.isEmpty() && settings) {
        // Format: language-COUNTRY (e.g., "nl-NL" or "en-US")
        const QString sessionLocale = QString("%1-%2").arg(language.toLower(), country.toUpper());
        const QString previousLocale = settings->GetCloudLanguagePSCloud();
        // The country is the real region signal; the language part may get
        // auto-corrected later (the imagic fetch settles e.g. hu-HU on en-HU).
        // Only re-save when the country actually changes, otherwise we'd clobber
        // the validated locale on every visit and thrash the cache.
        const QString previousCountry = previousLocale.section(QLatin1Char('-'), 1, 1).toUpper();
        if (previousCountry != country.toUpper()) {
            settings->SetCloudLanguagePSCloud(sessionLocale);
            qInfo() << "[PSNOW] Region changed, saved locale from session:" << sessionLocale
                    << "(was" << previousLocale << ") - invalidating cache";
            invalidateCache();
        } else if (settings->GetLogVerbose()) {
            qInfo() << "[PSNOW] Session country unchanged (" << country
                    << "), keeping validated locale" << previousLocale;
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

// ---------------------------------------------------------------------------
// PS3 Classics catalog (public Apollo container walk)
//
// The PS Plus PC ("Apollo") app browses the streamable catalog through the public
// pcnow container API at psnow.playstation.com. There is a dedicated PS3 container,
// STORE-MSF192018-APOLLOPS3GAMES, that lists ~300 streamable PS3 titles with their
// PS3 product ids (NPUA/NPUB/BLUS/BCUS) -- none of which appear in the imagic
// gameslist the rest of the catalog uses. The container API needs no OAuth or
// per-account session (unlike /user/stores, which 404s in regions where the PC app
// is unavailable, e.g. Hungary), so we can walk it directly in any region. The
// resulting titles carry playable_platform ["PS3"] and stream via the existing
// PSNOW -> Gaikai konan path.
// ---------------------------------------------------------------------------
// Resolve the account's region group from its store locale (e.g. "en-HU" -> "HU").
// pcnow has two Classics id families (Americas/SCEA and PAL/SCEE); a PS Plus account is
// authorized at Gaikai only for the family of its own region group, so the catalog must
// be browsed in that group. See KamajiConsts::classicsStoreCountry / classicsPs3ContainerId.
QString CloudCatalogBackend::ps3AccountCountry() const
{
    QString locale = settings ? settings->GetCloudLanguagePSCloud() : QStringLiteral("en-US");
    QStringList parts = locale.split(QLatin1Char('-'));
    QString cc = parts.size() > 1 ? parts[1] : QStringLiteral("US");
    return cc.toUpper();
}

void CloudCatalogBackend::fetchPs3Catalog(const QJSValue &callback)
{
    const QString cc = ps3AccountCountry();
    // Region-group-specific cache key so an Americas/PAL switch doesn't serve stale ids.
    const QString cacheKey = QStringLiteral("ps3_catalog_") + KamajiConsts::classicsStoreCountry(cc);
    QString cached = getCachedData(cacheKey, CACHE_DURATION_CATALOG);
    if (!cached.isEmpty()) {
        qInfo() << "[CACHE] Using cached PS3 catalog";
        QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
        if (callback.isCallable())
            callback.call({true, "Cached", QJSValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)))});
        return;
    }

    if (ps3State.inProgress) {
        qInfo() << "[PS3] Catalog fetch already in progress";
        if (callback.isCallable())
            callback.call({false, "Request already in progress", QJSValue()});
        return;
    }

    ps3State.containerUrl = QStringLiteral(
        "https://psnow.playstation.com/store/api/pcnow/00_09_000/container/%1/en/19/%2")
        .arg(KamajiConsts::classicsStoreCountry(cc), KamajiConsts::classicsPs3ContainerId(cc));
    qInfo() << "[API CALL] Fetching PS3 Classics catalog (region group"
            << KamajiConsts::classicsStoreCountry(cc) << "for account country" << cc << ")";
    ps3State.callback = callback;
    ps3State.allGames = QJsonArray();
    ps3State.currentStart = 0;
    ps3State.totalResults = -1;
    ps3State.inProgress = true;
    fetchPs3CatalogPage();
}

void CloudCatalogBackend::fetchPs3CatalogPage()
{
    QString url = QString("%1?useOffers=true&gkb=1&gkb2=1&start=%2&size=100")
                      .arg(ps3State.containerUrl)
                      .arg(ps3State.currentStart);

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PS3 catalog page ===";
        qInfo() << "  URL:" << url;
    }

    QNetworkRequest req{QUrl(url)};
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("User-Agent", KamajiConsts::USER_AGENT.toUtf8());

    QNetworkReply *reply = networkManager->get(req);
    connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePs3CatalogPageResponse);
}

void CloudCatalogBackend::handlePs3CatalogPageResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    reply->deleteLater();

    int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QByteArray data = reply->readAll();

    if (reply->error() != QNetworkReply::NoError || statusCode != 200) {
        QString errorMsg = QString("PS3 catalog fetch failed (HTTP %1): %2")
                               .arg(statusCode).arg(reply->errorString());
        qWarning() << "CloudCatalogBackend:" << errorMsg;
        if (ps3State.allGames.isEmpty()) {
            ps3State.inProgress = false;
            if (ps3State.callback.isCallable())
                ps3State.callback.call({false, errorMsg, QJSValue()});
            return;
        }
        // Partial data already collected: return what we have.
        finishPs3Catalog();
        return;
    }

    QJsonObject obj = QJsonDocument::fromJson(data).object();
    if (ps3State.totalResults < 0)
        ps3State.totalResults = obj.value("total_results").toInt();

    QJsonArray links = obj.value("links").toArray();
    int productCount = 0;
    for (const QJsonValue &v : links) {
        QJsonObject g = v.toObject();
        if (g.value("container_type").toString() != QLatin1String("product"))
            continue;
        QString img = extractCoverImageFromGameObject(g);
        if (!img.isEmpty())
            g["imageUrl"] = img;
        ps3State.allGames.append(g);
        productCount++;
    }

    if (settings && settings->GetLogVerbose())
        qInfo() << "  PS3 page games:" << productCount << "accumulated:" << ps3State.allGames.size()
                << "of" << ps3State.totalResults;

    ps3State.currentStart += 100;
    if (productCount > 0 && ps3State.currentStart < ps3State.totalResults) {
        fetchPs3CatalogPage();
    } else {
        finishPs3Catalog();
    }
}

void CloudCatalogBackend::finishPs3Catalog()
{
    QJsonObject result;
    result["games"] = ps3State.allGames;
    result["total"] = ps3State.allGames.size();
    QJsonDocument resultDoc(result);
    setCachedData(QStringLiteral("ps3_catalog_") + KamajiConsts::classicsStoreCountry(ps3AccountCountry()), resultDoc);

    qInfo() << "[PS3] Catalog complete:" << ps3State.allGames.size() << "PS3 titles";

    ps3State.inProgress = false;
    if (ps3State.callback.isCallable())
        ps3State.callback.call({true, "Success", QJSValue(QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact)))});
}

namespace {

// Canonicalize a "language-COUNTRY" locale to lowercase-language / uppercase-country.
static QString canonicalStoreLocale(const QString &raw)
{
    QString s = raw.trimmed();
    if (s.isEmpty())
        return QStringLiteral("en-US");
    const QStringList parts = s.split(QLatin1Char('-'));
    QString lang = parts.value(0).toLower();
    QString country = parts.value(1).toUpper();
    if (lang.isEmpty())
        lang = QStringLiteral("en");
    if (country.isEmpty())
        country = QStringLiteral("US");
    return lang + QLatin1Char('-') + country;
}

// Build the ordered list of store locales to try. Sony's storefront/imagic endpoints
// only serve a fixed set of language-COUNTRY combinations: the country is always
// served, but the language may not be (e.g. a Hungarian-language account yields
// "hu-HU", which 404s, while "en-HU" works). Fall back to English for the same
// country, then en-US, so the catalog loads in every region.
static QStringList buildStoreLocaleFallbackChain(const QString &stored)
{
    const QString canonical = canonicalStoreLocale(stored);
    const QString country = canonical.section(QLatin1Char('-'), 1, 1);
    QStringList chain;
    auto add = [&chain](const QString &loc) {
        if (!loc.isEmpty() && !chain.contains(loc))
            chain.append(loc);
    };
    add(canonical);
    add(QStringLiteral("en-") + country);
    add(QStringLiteral("en-US"));
    return chain;
}

static const QStringList kPs5ImagicCategoryLists = {
    QStringLiteral("plus-games-list"),
    QStringLiteral("ubisoft-classics-list"),
    QStringLiteral("plus-classics-list"),
    QStringLiteral("plus-monthly-games-list"),
    QStringLiteral("free-to-play-list"),
    QStringLiteral("all-ps5-list"),
};

// PS Plus cloud streaming covers PS4 and PS5 titles (PS3 is not present in these
// imagic lists). A PS4-only title such as God of War (2018) is streamable when
// owned even though it carries device ["PS4"], so the catalog must not discard it.
static bool isCloudDeviceGame(const QJsonObject &gameObj)
{
    const QJsonArray devices = gameObj.value(QStringLiteral("device")).toArray();
    for (const QJsonValue &device : devices) {
        const QString d = device.toString();
        if (d == QLatin1String("PS5") || d == QLatin1String("PS4"))
            return true;
    }
    return false;
}

static bool isCloudStreamingGame(const QJsonObject &gameObj)
{
    if (!gameObj.value(QStringLiteral("streamingSupported")).toBool())
        return false;
    return isCloudDeviceGame(gameObj);
}

static QString ps5CloudConceptKey(const QJsonObject &gameObj)
{
    const QJsonValue conceptIdVal = gameObj.value(QStringLiteral("conceptId"));
    if (conceptIdVal.isDouble()) {
        const qint64 conceptId = static_cast<qint64>(conceptIdVal.toDouble());
        if (conceptId > 0)
            return QString::number(conceptId);
    } else if (conceptIdVal.isString()) {
        const QString conceptId = conceptIdVal.toString();
        if (!conceptId.isEmpty())
            return conceptId;
    }
    return gameObj.value(QStringLiteral("productId")).toString();
}

// Platform token from a product id's title id: CUSA = PS4, PPSA = PS5.
static QString ps5CloudPlatformToken(const QString &productId)
{
    if (productId.contains(QLatin1String("PPSA")))
        return QStringLiteral("ps5");
    if (productId.contains(QLatin1String("CUSA")))
        return QStringLiteral("ps4");
    return QString();
}

// Catalog dedupe identity: one entry per game PER PLATFORM, so a cross-gen title that Sony lists
// as separate PS4 and PS5 editions (e.g. Deliver Us The Moon) shows as two cards, while duplicate
// same-platform SKUs still collapse. (conceptId alone collapsed the PS4/PS5 editions into one.)
static QString ps5CloudEditionKey(const QJsonObject &gameObj)
{
    const QString concept = ps5CloudConceptKey(gameObj);
    if (concept.isEmpty())
        return QString();
    return concept + QLatin1Char('|')
           + ps5CloudPlatformToken(gameObj.value(QStringLiteral("productId")).toString());
}

// A "full game" entitlement (vs an add-on / avatar / theme). PSN marks the base game with
// feature_type 3 and a *GD package_type (PSGD/PS4GD); add-ons use feature_type 0 and
// PS4MISC/PSAL/etc. Used to keep the base game when collapsing same-platform SKUs.
static bool ps5CloudIsFullGameEntitlement(const QJsonObject &ownedGameObj)
{
    if (ownedGameObj.value(QStringLiteral("feature_type")).toInt() == 3)
        return true;
    const QString pt = ownedGameObj.value(QStringLiteral("game_meta")).toObject()
                           .value(QStringLiteral("package_type")).toString();
    return pt.endsWith(QStringLiteral("GD"));
}

// Rank an owned entitlement as THE streaming candidate for its edition (higher = preferred).
// Upgrade / bonus / cross-buy SKUs collapse to the same conceptId+platform as the base game, so we
// must pick which one's product_id the card streams. The package_type/feature_type flags are not
// enough: Death Stranding DC's "Bonus Content" SKU is ALSO PSGD + feature_type 3, identical to the
// game. The reliable signal is that the BASE GAME's entitlement id EQUALS its product_id (e.g.
// ...DEATHSTRANDINGEU == ...DEATHSTRANDINGEU), while bonus/upgrade SKUs carry a different id (the
// bonus is product_id ...DEATHSTRADCDDE01 but id ...PPSA02624...). Prefer the canonical full-game
// entitlement so getStreamingIdentifier streams the real game's product_id, not a DLC product that
// Gaikai has no game for (-> noGameForEntitlementId).
static int ps5CloudOwnedStreamRank(const QJsonObject &ownedGameObj)
{
    const QString id = ownedGameObj.value(QStringLiteral("id")).toString();
    const QString pid = ownedGameObj.value(QStringLiteral("product_id")).toString();
    int rank = 0;
    if (!pid.isEmpty() && pid == id) rank += 4;            // canonical product (the base game SKU)
    if (ps5CloudIsFullGameEntitlement(ownedGameObj)) rank += 2; // full game (feature_type 3 / *GD)
    if (!id.isEmpty()) rank += 1;                          // has a real entitlement id
    return rank;
}

static QString ps5CloudProductIdStableKey(const QString &productId)
{
    if (productId.isEmpty())
        return QString();
    QStringList tokens;
    const QStringList dashParts = productId.split(QLatin1Char('-'), Qt::SkipEmptyParts);
    for (const QString &dashPart : dashParts) {
        const QStringList underscoreParts = dashPart.split(QLatin1Char('_'), Qt::SkipEmptyParts);
        for (const QString &token : underscoreParts)
            tokens.append(token);
    }
    if (tokens.size() < 2)
        return QString();
    tokens.removeLast();
    return tokens.join(QLatin1Char('|'));
}

static QMap<QString, QJsonObject> buildStableKeyIndex(const QJsonArray &games)
{
    QMap<QString, QJsonObject> index;
    for (const QJsonValue &game : games) {
        if (!game.isObject())
            continue;
        const QJsonObject gameObj = game.toObject();
        const QString productId = gameObj.value(QStringLiteral("productId")).toString();
        const QString key = ps5CloudProductIdStableKey(productId);
        if (key.isEmpty() || index.contains(key))
            continue;
        index.insert(key, gameObj);
    }
    return index;
}

// imagic encodes conceptId as a JSON number; entitlements (if present) may use a
// number or string. Normalize to a non-empty decimal string, else empty.
static QString ps5CloudConceptIdString(const QJsonValue &conceptIdVal)
{
    if (conceptIdVal.isDouble()) {
        const qint64 c = static_cast<qint64>(conceptIdVal.toDouble());
        return c > 0 ? QString::number(c) : QString();
    }
    if (conceptIdVal.isString())
        return conceptIdVal.toString();
    return QString();
}

// conceptId is region-stable (227770 for God of War 2018) whereas product IDs are
// region-prefixed (EP9000 vs UP9000) and vary by edition, so it is the most reliable
// owned->catalog match when both sides carry one.
static QMap<QString, QJsonObject> buildConceptIdIndex(const QJsonArray &games)
{
    QMap<QString, QJsonObject> index;
    for (const QJsonValue &game : games) {
        if (!game.isObject())
            continue;
        const QJsonObject gameObj = game.toObject();
        const QString concept = ps5CloudConceptIdString(gameObj.value(QStringLiteral("conceptId")));
        if (concept.isEmpty() || index.contains(concept))
            continue;
        index.insert(concept, gameObj);
    }
    return index;
}

// Pull a conceptId out of an owned entitlement, checking the field names the
// commerce API and our merged objects use. Returns empty if none is present.
static QString ownedEntitlementConceptId(const QJsonObject &ownedGameObj)
{
    QString concept = ps5CloudConceptIdString(ownedGameObj.value(QStringLiteral("conceptId")));
    if (concept.isEmpty())
        concept = ps5CloudConceptIdString(ownedGameObj.value(QStringLiteral("concept_id")));
    if (concept.isEmpty()) {
        const QJsonObject gameMeta = ownedGameObj.value(QStringLiteral("game_meta")).toObject();
        concept = ps5CloudConceptIdString(gameMeta.value(QStringLiteral("conceptId")));
        if (concept.isEmpty())
            concept = ps5CloudConceptIdString(gameMeta.value(QStringLiteral("concept_id")));
    }
    return concept;
}

static QJsonObject productIdAliasesToJson(const QMap<QString, QString> &aliases)
{
    QJsonObject obj;
    for (auto it = aliases.cbegin(); it != aliases.cend(); ++it)
        obj.insert(it.key(), it.value());
    return obj;
}

static QMap<QString, QString> productIdAliasesFromJson(const QJsonObject &obj)
{
    QMap<QString, QString> aliases;
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        const QString canonical = it.value().toString();
        if (!canonical.isEmpty())
            aliases.insert(it.key(), canonical);
    }
    return aliases;
}

// The PS Plus subscription "Game Catalog" (what Sony lists on the PS Plus games page) is the
// union of these curated lists. The other source we fetch, "all-ps5-list", is the entire
// cloud-streamable PS5 universe (~7000 titles) — useful for matching owned games but NOT the
// subscription catalog, so it must not inflate the Catalog tab.
static bool isPlusCatalogList(const QString &categoryList)
{
    return categoryList == QLatin1String("plus-games-list")
        || categoryList == QLatin1String("plus-classics-list")
        || categoryList == QLatin1String("ubisoft-classics-list")
        || categoryList == QLatin1String("plus-monthly-games-list");
}

static void mergeImagicListIntoPs5Catalog(const QString &categoryList,
                                          const QJsonDocument &doc,
                                          QMap<QString, QJsonObject> &gamesByConceptId,
                                          QMap<QString, QJsonObject> &plusLibrarySupplementByProductId,
                                          QMap<QString, QString> &productIdAliases,
                                          int &totalGamesSeen)
{
    const bool plusCatalog = isPlusCatalogList(categoryList);
    if (!doc.isArray())
        return;

    for (const QJsonValue &category : doc.array()) {
        if (!category.isObject())
            continue;
        const QJsonObject catObj = category.toObject();
        const QJsonArray games = catObj.value(QStringLiteral("games")).toArray();
        totalGamesSeen += games.size();
        for (const QJsonValue &game : games) {
            if (!game.isObject())
                continue;
            QJsonObject gameObj = game.toObject();
            // Accept both PS4 and PS5 cloud titles. The old PS5-only gate silently
            // dropped PS4-only PS-Plus-catalog games (e.g. God of War 2018) before
            // they could reach the library-stream supplement below.
            if (!isCloudDeviceGame(gameObj))
                continue;

            // Subscription-catalog titles excluded from public cloud browse (library-stream
            // candidates): streamingSupported=false but streamable once owned/acquired. Capture
            // these from EVERY subscription list (plus-games, classics, ubisoft, monthly) so the
            // Game Catalog includes them too — not just plus-games-list.
            if (plusCatalog
                && !gameObj.value(QStringLiteral("streamingSupported")).toBool()) {
                const QString productId = gameObj.value(QStringLiteral("productId")).toString();
                if (!productId.isEmpty()) {
                    gameObj.insert(QStringLiteral("plusCatalog"), true);
                    plusLibrarySupplementByProductId.insert(productId, gameObj);
                }
                continue;
            }

            if (!isCloudStreamingGame(gameObj))
                continue;

            // Dedupe per game PER PLATFORM so cross-gen PS4/PS5 editions both appear.
            const QString key = ps5CloudEditionKey(gameObj);
            const QString productId = gameObj.value(QStringLiteral("productId")).toString();
            if (key.isEmpty() || productId.isEmpty())
                continue;

            if (gamesByConceptId.contains(key)) {
                QJsonObject existing = gamesByConceptId.value(key);
                const QString canonicalProductId = existing.value(QStringLiteral("productId")).toString();
                if (!canonicalProductId.isEmpty() && productId != canonicalProductId
                    && !productIdAliases.contains(productId)) {
                    productIdAliases.insert(productId, canonicalProductId);
                }
                // Lists are fetched in parallel, so a title may be seen first via all-ps5-list
                // (not subscription) and later via a subscription list. Upgrade the flag so the
                // subscription membership wins regardless of arrival order.
                if (plusCatalog && !existing.value(QStringLiteral("plusCatalog")).toBool()) {
                    existing.insert(QStringLiteral("plusCatalog"), true);
                    gamesByConceptId.insert(key, existing);
                }
                continue;
            }

            gameObj.insert(QStringLiteral("plusCatalog"), plusCatalog);
            gamesByConceptId.insert(key, gameObj);
        }
    }
}

} // namespace

void CloudCatalogBackend::fetchPs5CloudCatalog(const QJSValue &callback)
{
    // Check cache first
    QString cached = getCachedPs5CatalogV3(CACHE_DURATION_CATALOG);
    if (!cached.isEmpty()) {
        qInfo() << "[CACHE] Using cached PS5 cloud catalog";
        QJsonDocument doc = QJsonDocument::fromJson(cached.toUtf8());
        if (callback.isCallable()) {
            callback.call({true, "Cached", QJSValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)))});
        }
        return;
    }

    qInfo() << "[API CALL] Fetching PS5 cloud catalog (6 imagic lists, cache miss or expired)";
    ps5State.callback = callback;

    // Build the store-locale fallback chain (session locale -> en-COUNTRY -> en-US)
    // and start with the first tier. Tiers escalate only when a whole tier 404s.
    ps5State.localeChain =
        buildStoreLocaleFallbackChain(settings ? settings->GetCloudLanguagePSCloud()
                                               : QStringLiteral("en-US"));
    ps5State.localeTierIndex = 0;
    startPs5ImagicListFetch();
}

void CloudCatalogBackend::startPs5ImagicListFetch()
{
    ps5State.activeLocale = ps5State.localeChain.value(ps5State.localeTierIndex,
                                                       QStringLiteral("en-US"));
    const QString locale = ps5State.activeLocale.toLower(); // imagic wants "en-us"

    // Reset per-tier accumulators so a failed tier leaves nothing behind.
    ps5State.gamesByConceptId.clear();
    ps5State.plusLibrarySupplementByProductId.clear();
    ps5State.productIdAliases.clear();
    ps5State.totalGamesSeen = 0;
    ps5State.succeededListFetches = 0;
    ps5State.allPs5ListSucceeded = false;
    ps5State.failedLists.clear();
    ps5State.pendingListFetches = kPs5ImagicCategoryLists.size();

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "[API CALL] PS5 imagic fetch using locale tier" << ps5State.localeTierIndex
                << ":" << ps5State.activeLocale;
    }

    for (const QString &categoryList : kPs5ImagicCategoryLists) {
        const QString url = QStringLiteral(
            "https://www.playstation.com/bin/imagic/gameslist?locale=%1&categoryList=%2")
                                .arg(locale, categoryList);

        QNetworkRequest request{QUrl(url)};
        request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
        request.setRawHeader("Accept", "application/json");
        request.setRawHeader("User-Agent",
                             "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");

        QNetworkReply *reply = networkManager->get(request);
        reply->setProperty("imagicCategoryList", categoryList);
        connect(reply, &QNetworkReply::finished, this, &CloudCatalogBackend::handlePs5ImagicListResponse);
    }
}

void CloudCatalogBackend::handlePs5ImagicListResponse()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply)
        return;

    const QString categoryList = reply->property("imagicCategoryList").toString();
    const int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const bool networkError = reply->error() != QNetworkReply::NoError;

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "=== CloudCatalogBackend: PS5 imagic list ===";
        qInfo() << "  Category:" << categoryList;
        qInfo() << "  Status:" << statusCode;
    }

    const QString errorString = reply->errorString();
    const QByteArray data = reply->readAll();
    reply->deleteLater();

    if (networkError || statusCode != 200) {
        qWarning() << "PS5 imagic list fetch failed:" << categoryList
                   << (networkError ? errorString : QString("HTTP %1").arg(statusCode));
        ps5State.failedLists.append(categoryList);
    } else {
        const QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isArray()) {
            qWarning() << "PS5 imagic list invalid JSON:" << categoryList;
            ps5State.failedLists.append(categoryList);
        } else {
            ps5State.succeededListFetches++;
            if (categoryList == QLatin1String("all-ps5-list"))
                ps5State.allPs5ListSucceeded = true;
            mergeImagicListIntoPs5Catalog(categoryList, doc, ps5State.gamesByConceptId,
                                          ps5State.plusLibrarySupplementByProductId,
                                          ps5State.productIdAliases,
                                          ps5State.totalGamesSeen);
        }
    }

    ps5State.pendingListFetches--;
    if (ps5State.pendingListFetches <= 0) {
        if (ps5State.succeededListFetches <= 0) {
            // The whole tier failed (typically a 404 for an unsupported store
            // locale such as hu-HU). Escalate to the next locale tier before
            // giving up, so regions Sony only serves in English still load.
            if (ps5State.localeTierIndex + 1 < ps5State.localeChain.size()) {
                ps5State.localeTierIndex++;
                qWarning() << "[API] All imagic lists failed for locale"
                           << ps5State.activeLocale << "- retrying with"
                           << ps5State.localeChain.value(ps5State.localeTierIndex);
                startPs5ImagicListFetch();
                return;
            }
            if (ps5State.callback.isCallable()) {
                ps5State.callback.call({false,
                                          QStringLiteral("All imagic lists failed to load"),
                                          QJSValue()});
            }
        } else {
            finalizePs5CloudCatalogFetch();
        }
    }
}

void CloudCatalogBackend::finalizePs5CloudCatalogFetch()
{
    QJsonArray allGames;
    for (QJsonObject gameObj : ps5State.gamesByConceptId) {
        if (!gameObj.contains(QStringLiteral("imageUrl"))
            || gameObj.value(QStringLiteral("imageUrl")).toString().isEmpty()) {
            const QString coverImageUrl = extractCoverImageFromGameObject(gameObj);
            if (!coverImageUrl.isEmpty())
                gameObj.insert(QStringLiteral("imageUrl"), coverImageUrl);
        }
        allGames.append(gameObj);
    }

    QJsonArray plusSupplementGames;
    for (QJsonObject gameObj : ps5State.plusLibrarySupplementByProductId) {
        if (!gameObj.contains(QStringLiteral("imageUrl"))
            || gameObj.value(QStringLiteral("imageUrl")).toString().isEmpty()) {
            const QString coverImageUrl = extractCoverImageFromGameObject(gameObj);
            if (!coverImageUrl.isEmpty())
                gameObj.insert(QStringLiteral("imageUrl"), coverImageUrl);
        }
        plusSupplementGames.append(gameObj);
    }

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  Imagic rows scanned:" << ps5State.totalGamesSeen;
        qInfo() << "  PS5 streaming games (deduped by conceptId):" << allGames.size();
        qInfo() << "  Plus library-stream supplement (stream=false):" << plusSupplementGames.size();
        qInfo() << "  Product ID aliases (same conceptId):" << ps5State.productIdAliases.size();
    }

    // Persist the locale that actually worked so game-details fetches and the
    // cache locale check all agree on it (e.g. a hu-HU account settles on en-HU).
    const QString workingLocale = !ps5State.activeLocale.isEmpty()
                                      ? ps5State.activeLocale
                                      : (settings ? settings->GetCloudLanguagePSCloud()
                                                  : QStringLiteral("en-US"));
    if (settings && settings->GetCloudLanguagePSCloud() != workingLocale) {
        qInfo() << "[PSCLOUD] Store locale settled on" << workingLocale
                << "(was" << settings->GetCloudLanguagePSCloud() << ")";
        settings->SetCloudLanguagePSCloud(workingLocale);
    }

    QJsonObject result;
    result.insert(QStringLiteral("locale"), workingLocale);
    result[QStringLiteral("games")] = allGames;
    result[QStringLiteral("total")] = allGames.size();
    result[QStringLiteral("plusLibrarySupplement")] = plusSupplementGames;
    if (!ps5State.productIdAliases.isEmpty())
        result[QStringLiteral("productIdAliases")] = productIdAliasesToJson(ps5State.productIdAliases);

    const QJsonDocument resultDoc(result);

    if (ps5State.allPs5ListSucceeded)
        setCachedData(QStringLiteral("ps5_cloud_catalog_v6"), resultDoc);

    QString callbackMessage = QStringLiteral("Success");
    if (!ps5State.failedLists.isEmpty()) {
        callbackMessage = QStringLiteral("Some catalog lists failed to load (%1). Catalog may be incomplete.")
                              .arg(ps5State.failedLists.join(QStringLiteral(", ")));
        qWarning() << "[API]" << callbackMessage;
    }

    if (crossReferenceState.callback.isCallable() && !crossReferenceState.catalogFetched) {
        crossReferenceState.cloudCatalogGames = allGames;
        crossReferenceState.plusLibrarySupplement = plusSupplementGames;
        crossReferenceState.productIdAliases = ps5State.productIdAliases;
        crossReferenceState.catalogFetched = true;
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "[CROSS-REF] Fetched PS5 cloud catalog from API:" << allGames.size() << "games";
        }
        if (crossReferenceState.catalogFetched && crossReferenceState.ownedGamesFetched) {
            processCrossReferenceComplete();
        }
    }

    if (ps5State.callback.isCallable()) {
        const QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        ps5State.callback.call({true, callbackMessage, QJSValue(jsonStr)});
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

    // Map each bundle product_id -> the entitlement ids that share it, so a bundle (e.g. RE7 Gold,
    // whose components each carry the bundle product_id but a distinct entitlement id) can expand to
    // its component games during cross-reference (upstream PR #15's bundle-sibling matching).
    QMap<QString, QStringList> componentIds;
    for (const QJsonValue &ent : ownedGamesState.accumulatedEntitlements) {
        if (!ent.isObject())
            continue;
        const QJsonObject o = ent.toObject();
        const QString pid = o.value(QStringLiteral("product_id")).toString();
        const QString eid = o.value(QStringLiteral("id")).toString();
        if (!pid.isEmpty() && !eid.isEmpty())
            componentIds[pid].append(eid);
    }

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "  PS5 games (PSGD):" << ps5Games.size();
    }

    QJsonObject result;
    result["games"] = ps5Games;
    result["total"] = ps5Games.size();
    QJsonObject componentObj;
    for (auto it = componentIds.cbegin(); it != componentIds.cend(); ++it)
        componentObj.insert(it.key(), QJsonArray::fromStringList(it.value()));
    result[QStringLiteral("componentIdsByProductId")] = componentObj;

    QJsonDocument resultDoc(result);

    // Cache the result
    setCachedData("ps5_cloud_library", resultDoc);

    // If cross-reference is active, populate its state
    if (crossReferenceState.callback.isCallable() && !crossReferenceState.ownedGamesFetched) {
        crossReferenceState.ownedGames = ps5Games;
        crossReferenceState.componentIdsByProductId = componentIds;
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
        if (!ent.isObject())
            continue;
        QJsonObject entObj = ent.toObject();

        // Must look like a game entitlement (has game_meta).
        if (!entObj.contains("game_meta") || !entObj["game_meta"].isObject())
            continue;
        QJsonObject gameMeta = entObj["game_meta"].toObject();
        const QString packageType = gameMeta["package_type"].toString();

        // Skip inactive entitlements (active_flag must be true).
        const bool activeFlag = entObj.contains("active_flag") && entObj["active_flag"].toBool();
        if (!activeFlag)
            continue;

        // Skip subscriptions/services (Product IDs starting with IP or SUB).
        const QString productId = entObj["product_id"].toString();
        if (productId.startsWith("IP") || productId.startsWith("SUB"))
            continue;

        // Hide EXTRAS: feature_type==0 is DLC / add-ons / themes / avatars / season passes / cross-buy
        // "tracks" (PS4MISC/PSAL/PSTRACK/PS4AC/...), NEVER a base game -- every *GD game package is
        // feature_type 1 (trial / free-to-play) or 3/5 (full game). Dropping ft==0 keeps add-ons from
        // cluttering the library or marking a game "owned" via DLC, and is safe (it can't hide a game).
        // Trials/free (ft1) and full games (ft3/5) are KEPT; the trial-vs-full split is handled when
        // merging owned games into the catalog (a trial stays its own card so the full version can
        // still show "Add Game").
        if (entObj.value(QStringLiteral("feature_type")).toInt() == 0)
            continue;

        // Previously this required package_type == "PSGD" (PS5 only), which dropped
        // owned PS4 titles (e.g. God of War 2018) and PS3 titles. We now accept every
        // active game entitlement; streamability is enforced downstream by the catalog
        // cross-reference (only titles present in the streamable catalog/supplement are
        // shown), and matches are deduped by conceptId, so non-streamable or add-on
        // entitlements are harmlessly dropped there.
        const QString gameName = gameMeta.contains("name") ? gameMeta["name"].toString() : productId;
        if (settings && settings->GetLogVerbose()) {
            qInfo() << "  Owned entitlement:" << gameName
                    << "package_type:" << (packageType.isEmpty() ? QStringLiteral("(none)") : packageType)
                    << "product_id:" << productId;
        }

        // Extract cover image from game_meta.icon_url (the primary field for the entitlements API).
        QString coverImageUrl;
        if (gameMeta.contains("icon_url")) {
            coverImageUrl = gameMeta["icon_url"].toString();
        }
        if (coverImageUrl.isEmpty()) {
            coverImageUrl = extractCoverImageFromGameObject(gameMeta);
        }
        if (coverImageUrl.isEmpty()) {
            coverImageUrl = extractCoverImageFromGameObject(entObj);
        }
        // Additional fallbacks for other common image field names.
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
        }

        ps5Games.append(entObj);
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
    crossReferenceState.plusLibrarySupplement = QJsonArray();
    crossReferenceState.ownedGames = QJsonArray();
    crossReferenceState.productIdAliases.clear();
    crossReferenceState.componentIdsByProductId.clear();
    crossReferenceState.catalogFetched = false;
    crossReferenceState.ownedGamesFetched = false;
    
    // Check cache for both catalogs first
    QString cachedCatalog = getCachedPs5CatalogV3(CACHE_DURATION_CATALOG);
    
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
            if (obj.contains(QStringLiteral("plusLibrarySupplement"))
                && obj.value(QStringLiteral("plusLibrarySupplement")).isArray()) {
                crossReferenceState.plusLibrarySupplement =
                    obj.value(QStringLiteral("plusLibrarySupplement")).toArray();
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "[CROSS-REF] Loaded Plus library supplement from cache:"
                            << crossReferenceState.plusLibrarySupplement.size() << "games";
                }
            }
            if (obj.contains(QStringLiteral("productIdAliases"))
                && obj.value(QStringLiteral("productIdAliases")).isObject()) {
                crossReferenceState.productIdAliases =
                    productIdAliasesFromJson(obj.value(QStringLiteral("productIdAliases")).toObject());
                if (settings && settings->GetLogVerbose()) {
                    qInfo() << "[CROSS-REF] Loaded product ID aliases from cache:"
                            << crossReferenceState.productIdAliases.size();
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
            // Bundle->components map for bundle-sibling matching (upstream PR #15).
            if (obj.contains(QStringLiteral("componentIdsByProductId"))
                && obj.value(QStringLiteral("componentIdsByProductId")).isObject()) {
                const QJsonObject m = obj.value(QStringLiteral("componentIdsByProductId")).toObject();
                crossReferenceState.componentIdsByProductId.clear();
                for (auto it = m.begin(); it != m.end(); ++it) {
                    QStringList ids;
                    for (const QJsonValue &v : it.value().toArray())
                        ids.append(v.toString());
                    crossReferenceState.componentIdsByProductId.insert(it.key(), ids);
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
        cacheKey = "ps5_cloud_catalog_v6";
        isPsCloudLibrary = false;
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
    // Cross-reference owned games with browse catalog + Plus library-stream supplement
    QMap<QString, QJsonObject> cloudCatalogMap;
    QMap<QString, QJsonObject> plusSupplementMap;

    for (const QJsonValue &game : crossReferenceState.cloudCatalogGames) {
        if (game.isObject()) {
            QJsonObject gameObj = game.toObject();
            QString productId = gameObj["productId"].toString();
            if (!productId.isEmpty()) {
                cloudCatalogMap[productId] = gameObj;
            }
        }
    }

    for (auto it = crossReferenceState.productIdAliases.cbegin();
         it != crossReferenceState.productIdAliases.cend(); ++it) {
        if (cloudCatalogMap.contains(it.key()))
            continue;
        if (cloudCatalogMap.contains(it.value()))
            cloudCatalogMap.insert(it.key(), cloudCatalogMap.value(it.value()));
    }

    for (const QJsonValue &game : crossReferenceState.plusLibrarySupplement) {
        if (game.isObject()) {
            QJsonObject gameObj = game.toObject();
            const QString productId = gameObj.value(QStringLiteral("productId")).toString();
            if (!productId.isEmpty())
                plusSupplementMap.insert(productId, gameObj);
        }
    }

    const QMap<QString, QJsonObject> browseStableKey =
        buildStableKeyIndex(crossReferenceState.cloudCatalogGames);
    const QMap<QString, QJsonObject> supplementStableKey =
        buildStableKeyIndex(crossReferenceState.plusLibrarySupplement);
    const QMap<QString, QJsonObject> browseByConcept =
        buildConceptIdIndex(crossReferenceState.cloudCatalogGames);
    const QMap<QString, QJsonObject> supplementByConcept =
        buildConceptIdIndex(crossReferenceState.plusLibrarySupplement);

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "[CROSS-REF] Cloud catalog map size:" << cloudCatalogMap.size();
        qInfo() << "[CROSS-REF] Product ID aliases:" << crossReferenceState.productIdAliases.size();
        qInfo() << "[CROSS-REF] Plus library supplement map size:" << plusSupplementMap.size();
        qInfo() << "[CROSS-REF] Concept-id index (browse/supplement):"
                << browseByConcept.size() << "/" << supplementByConcept.size();
        qInfo() << "[CROSS-REF] Owned games count:" << crossReferenceState.ownedGames.size();
    }

    QJsonArray filteredGames;
    int matchedCount = 0;
    int productIdMatchCount = 0;
    int entitlementIdMatchCount = 0;
    int supplementMatchCount = 0;
    int conceptIdBrowseMatchCount = 0;
    int conceptIdSupplementMatchCount = 0;
    int stableKeyBrowseMatchCount = 0;
    int stableKeySupplementMatchCount = 0;
    QMap<QString, QJsonObject> ownedByKey;

    for (const QJsonValue &ownedGame : crossReferenceState.ownedGames) {
        if (!ownedGame.isObject())
            continue;

        QJsonObject ownedGameObj = ownedGame.toObject();
        const QString productId = ownedGameObj.value(QStringLiteral("product_id")).toString();
        const QString entitlementId = ownedGameObj.value(QStringLiteral("id")).toString();
        const QString entName = ownedGameObj.value(QStringLiteral("game_meta")).toObject()
                                    .value(QStringLiteral("name")).toString();
        const bool skipStableDemo = entName.contains(QStringLiteral("demo"), Qt::CaseInsensitive);
        const QString stableKey = ps5CloudProductIdStableKey(productId);
        const QString entStableKey = ps5CloudProductIdStableKey(entitlementId);
        const QString ownedConceptId = ownedEntitlementConceptId(ownedGameObj);

        // Enrich the owned entitlement with a matched catalog row and dedupe it into ownedByKey, in
        // OUR field convention (catalogProductId = streamable catalog variant, productId = owned
        // product, conceptId+PLATFORM dedupe, canonical-entitlement rank). Called once for a direct
        // match, or once per component for a bundle (upstream PR #15 bundle-sibling expansion).
        auto emitOwned = [&](const QJsonObject &meta, bool fromSupplement) {
            QJsonObject entry = ownedGameObj;
            if (meta.contains(QStringLiteral("name"))) {
                const QString imagicName = meta.value(QStringLiteral("name")).toString();
                if (!imagicName.isEmpty())
                    entry.insert(QStringLiteral("name"), imagicName);
            }
            if (meta.contains(QStringLiteral("imageUrl"))
                && !meta.value(QStringLiteral("imageUrl")).toString().isEmpty()) {
                entry.insert(QStringLiteral("imageUrl"), meta.value(QStringLiteral("imageUrl")));
            }
            if (meta.contains(QStringLiteral("conceptUrl"))) {
                entry.insert(QStringLiteral("conceptUrl"), meta.value(QStringLiteral("conceptUrl")));
            }
            // Carry the catalog device list so the UI can tell PS4 from PS5 and route PS4 via Kamaji.
            if (meta.contains(QStringLiteral("device"))) {
                entry.insert(QStringLiteral("device"), meta.value(QStringLiteral("device")));
            }
            // Cloud streaming binds to the catalog product variant (carries the PS Plus streaming
            // offer), not the owned download product (e.g. God of War owned ...GODOFWAR vs catalog
            // ...GODOFWARN). Keep the catalog productId so PS4 streaming converts the right variant.
            const QString metaProductId = meta.value(QStringLiteral("productId")).toString();
            if (!metaProductId.isEmpty())
                entry.insert(QStringLiteral("catalogProductId"), metaProductId);
            entry.insert(QStringLiteral("productId"), productId);
            entry.insert(QStringLiteral("streamingSupported"), !fromSupplement);

            const QString conceptId = ps5CloudConceptIdString(meta.value(QStringLiteral("conceptId")));
            if (!conceptId.isEmpty())
                entry.insert(QStringLiteral("conceptId"), conceptId);
            // Dedupe identity = conceptId + PLATFORM (the catalog edition key): a cross-gen title
            // owned on PS4 and PS5 stays as two cards; same-platform SKUs (bonus/avatars) merge.
            const QString platformToken = ps5CloudPlatformToken(productId);
            const QString dedupeKey = !conceptId.isEmpty() ? QStringLiteral("c:") + conceptId + QLatin1Char(':') + platformToken
                                    : !productId.isEmpty() ? QStringLiteral("p:") + productId
                                    : !entitlementId.isEmpty() ? QStringLiteral("e:") + entitlementId
                                    : QStringLiteral("u:") + productId + QLatin1Char(':') + entitlementId;
            if (ownedByKey.contains(dedupeKey)) {
                const QJsonObject existing = ownedByKey.value(dedupeKey);
                // Keep the best streaming candidate: the canonical full-game entitlement (its
                // product_id is the real streamable game, not a DLC/bonus product Gaikai rejects).
                if (ps5CloudOwnedStreamRank(entry) > ps5CloudOwnedStreamRank(existing))
                    ownedByKey.insert(dedupeKey, entry);
            } else {
                ownedByKey.insert(dedupeKey, entry);
            }
            matchedCount++;
        };

        QJsonObject meta;
        bool found = false;
        bool fromSupplement = false;

        if (!productId.isEmpty() && cloudCatalogMap.contains(productId)) {
            meta = cloudCatalogMap.value(productId);
            found = true;
            productIdMatchCount++;
        } else if (!entitlementId.isEmpty() && cloudCatalogMap.contains(entitlementId)) {
            meta = cloudCatalogMap.value(entitlementId);
            found = true;
            entitlementIdMatchCount++;
        } else if (!ownedConceptId.isEmpty() && browseByConcept.contains(ownedConceptId)) {
            meta = browseByConcept.value(ownedConceptId);
            found = true;
            conceptIdBrowseMatchCount++;
        } else if (!ownedConceptId.isEmpty() && supplementByConcept.contains(ownedConceptId)) {
            meta = supplementByConcept.value(ownedConceptId);
            found = true;
            fromSupplement = true;
            conceptIdSupplementMatchCount++;
        } else if (!productId.isEmpty() && !entitlementId.isEmpty()
                   && entitlementId == productId && plusSupplementMap.contains(productId)) {
            meta = plusSupplementMap.value(productId);
            found = true;
            fromSupplement = true;
            supplementMatchCount++;
        } else if (!stableKey.isEmpty() && !skipStableDemo && browseStableKey.contains(stableKey)) {
            meta = browseStableKey.value(stableKey);
            found = true;
            stableKeyBrowseMatchCount++;
        } else if (!stableKey.isEmpty() && !skipStableDemo
                   && supplementStableKey.contains(stableKey)) {
            meta = supplementStableKey.value(stableKey);
            found = true;
            fromSupplement = true;
            stableKeySupplementMatchCount++;
        } else if (!entStableKey.isEmpty() && !skipStableDemo && browseStableKey.contains(entStableKey)) {
            // Stable-key match on the ENTITLEMENT id (upstream PR #15): catches cross-gen / upgrade
            // entitlement ids whose stable key matches a catalog row even when product_id did not.
            meta = browseStableKey.value(entStableKey);
            found = true;
            stableKeyBrowseMatchCount++;
        } else if (!entStableKey.isEmpty() && !skipStableDemo && supplementStableKey.contains(entStableKey)) {
            meta = supplementStableKey.value(entStableKey);
            found = true;
            fromSupplement = true;
            stableKeySupplementMatchCount++;
        }

        if (found) {
            emitOwned(meta, fromSupplement);
            continue;
        }

        // Bundle-sibling expansion (upstream PR #15): a bundle entitlement (e.g. RE7 Gold) has no
        // direct catalog row, but its component entitlement ids each map to a component game. Emit
        // each distinct component as its own owned entry (via emitOwned, so OUR dedupe/rank apply).
        QStringList seenMetaPids;
        for (const QString &siblingId : crossReferenceState.componentIdsByProductId.value(productId)) {
            QJsonObject siblingMeta;
            bool siblingFromSupplement = false;
            if (cloudCatalogMap.contains(siblingId)) {
                siblingMeta = cloudCatalogMap.value(siblingId);
            } else if (plusSupplementMap.contains(siblingId)) {
                siblingMeta = plusSupplementMap.value(siblingId);
                siblingFromSupplement = true;
            } else {
                const QString siblingStableKey = ps5CloudProductIdStableKey(siblingId);
                if (!siblingStableKey.isEmpty() && !skipStableDemo) {
                    if (browseStableKey.contains(siblingStableKey)) {
                        siblingMeta = browseStableKey.value(siblingStableKey);
                    } else if (supplementStableKey.contains(siblingStableKey)) {
                        siblingMeta = supplementStableKey.value(siblingStableKey);
                        siblingFromSupplement = true;
                    }
                }
            }
            if (siblingMeta.isEmpty())
                continue;
            const QString siblingPid = siblingMeta.value(QStringLiteral("productId")).toString();
            if (siblingPid.isEmpty() || seenMetaPids.contains(siblingPid))
                continue;
            seenMetaPids.append(siblingPid);
            emitOwned(siblingMeta, siblingFromSupplement);
        }
    }

    // Disc-upgrade rescue. feature_type 5 marks a PS4-disc -> PS5 *disc upgrade* license; Gaikai
    // refuses to cloud-stream it ("disc-upgrade-unsupported"). The browse catalog often binds a
    // concept to exactly that SKU (e.g. Horizon Forbidden West concept 10000886 -> PPSA01521), while
    // the user's streamable full-game entitlement is a DIFFERENT title id (e.g. Complete Edition
    // PPSA17903) that is absent from the catalog and carries no conceptId -- so the cross-reference
    // never matches it and only the disc-upgrade SKU survives the dedupe. When a concept winner is a
    // disc upgrade, adopt the product id of a same-name full-game (feature_type 3) owned SKU so the
    // card streams the edition Gaikai accepts.
    //
    // Entitlements carry no conceptId (the commerce API omits it) and the disc-upgrade SKU shares no
    // id/sku with the real edition, so the only in-data bridge is the title name. To keep that safe:
    //   - SAME PLATFORM only (a PS5/PPSA disc upgrade must never pull in a PS4/CUSA SKU of a
    //     same-named game),
    //   - prefer the CANONICAL base game (product_id == entitlement id, i.e. not a bundle/add-on SKU),
    //   - and BAIL on genuine ambiguity (two distinct base games sharing one name) rather than guess.
    auto normalizeTitle = [](const QString &raw) {
        return raw.toLower().remove(QChar(0x2122)).remove(QChar(0x00AE)).remove(QChar(0x2120)).simplified();
    };
    for (auto it = ownedByKey.begin(); it != ownedByKey.end(); ++it) {
        QJsonObject entry = it.value();
        if (entry.value(QStringLiteral("feature_type")).toInt() != 5)
            continue;
        const QString discPid = entry.value(QStringLiteral("product_id")).toString();
        const QString discPlatform = ps5CloudPlatformToken(discPid);
        const QString discName = normalizeTitle(entry.value(QStringLiteral("game_meta")).toObject()
                                                     .value(QStringLiteral("name")).toString());
        if (discName.isEmpty())
            continue;
        QStringList canonicalPids; // base-game SKUs (product_id == entitlement id)
        QStringList otherPids;     // non-canonical full-game SKUs (bundle/edition products)
        for (const QJsonValue &candVal : crossReferenceState.ownedGames) {
            if (!candVal.isObject())
                continue;
            const QJsonObject cand = candVal.toObject();
            // Require a standard digital full game (feature_type 3) -- not another disc upgrade,
            // DLC/add-on (ft 0) or trial (ft 1) -- whose name matches the disc-upgrade title.
            if (cand.value(QStringLiteral("feature_type")).toInt() != 3)
                continue;
            const QString candName = normalizeTitle(cand.value(QStringLiteral("game_meta")).toObject()
                                                        .value(QStringLiteral("name")).toString());
            if (candName != discName)
                continue;
            const QString candPid = cand.value(QStringLiteral("product_id")).toString();
            if (candPid.isEmpty() || candPid == discPid)
                continue;
            if (ps5CloudPlatformToken(candPid) != discPlatform)
                continue; // never cross platforms (PS5 disc upgrade must not resolve to a PS4 SKU)
            const QString candId = cand.value(QStringLiteral("id")).toString();
            if (candPid == candId) {
                if (!canonicalPids.contains(candPid)) canonicalPids.append(candPid);
            } else {
                if (!otherPids.contains(candPid)) otherPids.append(candPid);
            }
        }
        // A single canonical base game wins; else a single non-canonical full game; else bail.
        QString replacementPid;
        if (canonicalPids.size() == 1)
            replacementPid = canonicalPids.first();
        else if (canonicalPids.isEmpty() && otherPids.size() == 1)
            replacementPid = otherPids.first();
        if (replacementPid.isEmpty()) {
            if (!canonicalPids.isEmpty() || !otherPids.isEmpty())
                qWarning() << "[CROSS-REF] disc-upgrade rescue: ambiguous full-game candidates for"
                           << discName << "canonical=" << canonicalPids << "other=" << otherPids
                           << "-- leaving disc-upgrade SKU in place";
            continue;
        }
        entry.insert(QStringLiteral("product_id"), replacementPid);
        entry.insert(QStringLiteral("productId"), replacementPid);
        entry.insert(QStringLiteral("catalogProductId"), replacementPid);
        it.value() = entry;
        qInfo() << "[CROSS-REF] disc-upgrade rescue:" << discName << ":" << discPid
                << "-> streamable" << replacementPid;
    }

    for (const QJsonObject &gameObj : ownedByKey)
        filteredGames.append(gameObj);

    if (settings && settings->GetLogVerbose()) {
        qInfo() << "[CROSS-REF] Matched games (cloud streamable):" << matchedCount;
        qInfo() << "[CROSS-REF]   By product_id:" << productIdMatchCount;
        qInfo() << "[CROSS-REF]   By entitlement id (fallback):" << entitlementIdMatchCount;
        qInfo() << "[CROSS-REF]   By Plus library supplement:" << supplementMatchCount;
        qInfo() << "[CROSS-REF]   By conceptId (browse):" << conceptIdBrowseMatchCount;
        qInfo() << "[CROSS-REF]   By conceptId (supplement):" << conceptIdSupplementMatchCount;
        qInfo() << "[CROSS-REF]   By stable product id key (browse):" << stableKeyBrowseMatchCount;
        qInfo() << "[CROSS-REF]   By stable product id key (supplement):" << stableKeySupplementMatchCount;
    }

    QJsonObject result;
    result["games"] = filteredGames;
    result["total"] = filteredGames.size();

    QJsonDocument resultDoc(result);

    if (crossReferenceState.callback.isCallable()) {
        QString jsonStr = QString::fromUtf8(resultDoc.toJson(QJsonDocument::Compact));
        crossReferenceState.callback.call({true, "Success", QJSValue(jsonStr)});
    }

    crossReferenceState.callback = QJSValue();
    crossReferenceState.cloudCatalogGames = QJsonArray();
    crossReferenceState.plusLibrarySupplement = QJsonArray();
    crossReferenceState.ownedGames = QJsonArray();
    crossReferenceState.productIdAliases.clear();
    crossReferenceState.componentIdsByProductId.clear();
    crossReferenceState.catalogFetched = false;
    crossReferenceState.ownedGamesFetched = false;
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
    // Invalidate specific cache files (PSNOW, PS5 cloud catalog, and PS5 cloud library)
    QString psnowPath = getCacheFilePath("psnow_catalog");
    QString ps5CatalogPath = getCacheFilePath("ps5_cloud_catalog_v6");
    QString ps5CatalogV2Path = getCacheFilePath("ps5_cloud_catalog_v2");
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
    if (QFile::exists(ps5CatalogV2Path)) {
        QFile::remove(ps5CatalogV2Path);
        qInfo() << "[CACHE INVALIDATED] Removed PS5 cloud catalog v2 cache";
        invalidated = true;
    }
    // Drop legacy cache from pre-v2 catalog merge / conceptId dedupe fix
    const QString legacyPs5CatalogPath = getCacheFilePath("ps5_cloud_catalog");
    if (QFile::exists(legacyPs5CatalogPath)) {
        QFile::remove(legacyPs5CatalogPath);
        qInfo() << "[CACHE INVALIDATED] Removed legacy PS5 cloud catalog cache";
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


