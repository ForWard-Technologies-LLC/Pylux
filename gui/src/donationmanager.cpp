#include "donationmanager.h"
#include "settings.h"

#include <QDesktopServices>
#include <QUrl>
#include <QUrlQuery>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <QFile>
#include <QLoggingCategory>

#ifdef CHIAKI_IS_MAC_APPSTORE
#include "macstorekit.h"
#endif

Q_LOGGING_CATEGORY(chiakiDonation, "chiaki.donation")

DonationManager::DonationManager(Settings *settings, QObject *parent)
    : QObject(parent)
    , m_settings(settings)
    , m_nam(new QNetworkAccessManager(this))
    , m_delayTimer(new QTimer(this))
{
    m_delayTimer->setSingleShot(true);
    m_delayTimer->setInterval(DONATION_SHOW_DELAY_MS);
    connect(m_delayTimer, &QTimer::timeout, this, [this]() {
        checkDonationStatusAndShow(false);
    });

#ifdef CHIAKI_IS_MAC_APPSTORE
    qCInfo(chiakiDonation) << "Mac App Store build: using StoreKit IAP";
    initStoreKit();
#else
    if (resolvePsnOnlineId().isEmpty())
        fetchPsnOnlineId();
#endif
}

bool DonationManager::isEnabled() const
{
    return true;
}

bool DonationManager::isAppStore() const
{
#ifdef CHIAKI_IS_MAC_APPSTORE
    return true;
#else
    return false;
#endif
}

void DonationManager::scheduleOfferIfEligible()
{
    if (!isEnabled())
        return;

#ifndef CHIAKI_IS_MAC_APPSTORE
    QString psnId = resolvePsnOnlineId();
    if (psnId.isEmpty()) {
        qCDebug(chiakiDonation) << "No PSN online ID available, skipping donation prompt";
        return;
    }
#endif

    qint64 totalMs = m_settings->GetDonationTotalStreamTimeMs();
    if (totalMs < DONATION_MIN_STREAM_MS) {
        qCDebug(chiakiDonation) << "Not enough stream time:" << totalMs << "ms (need" << DONATION_MIN_STREAM_MS << ")";
        return;
    }

    qint64 lastMs = m_settings->GetDonationLastPromptWallClockMs();
    qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (lastMs > 0 && (nowMs - lastMs) < DONATION_PROMPT_COOLDOWN_MS) {
        qCDebug(chiakiDonation) << "Cooldown active, skipping donation prompt";
        return;
    }

    cancelScheduledOffer();
    qCDebug(chiakiDonation) << "Scheduling donation prompt in" << DONATION_SHOW_DELAY_MS << "ms";
    m_delayTimer->start();
}

void DonationManager::cancelScheduledOffer()
{
    if (m_delayTimer->isActive()) {
        qCDebug(chiakiDonation) << "Cancelling scheduled donation prompt";
        m_delayTimer->stop();
    }
}

void DonationManager::markConnected()
{
    if (!isEnabled())
        return;

    if (!m_sessionTimerRunning) {
        m_sessionTimer.start();
        m_sessionTimerRunning = true;
        qCDebug(chiakiDonation) << "Stream session timer started";
    }
}

void DonationManager::flushStreamTime()
{
    if (!m_sessionTimerRunning)
        return;

    qint64 elapsed = m_sessionTimer.elapsed();
    m_sessionTimerRunning = false;

    qint64 total = m_settings->GetDonationTotalStreamTimeMs() + elapsed;
    m_settings->SetDonationTotalStreamTimeMs(total);
    qCDebug(chiakiDonation) << "Flushed stream time: +" << elapsed << "ms, total:" << total << "ms";
}

void DonationManager::openSupportFromSettings()
{
    if (!isEnabled())
        return;

    qCInfo(chiakiDonation) << "Support button pressed from settings";
    cancelScheduledOffer();
    checkDonationStatusAndShow(true);
}

void DonationManager::openInBrowser()
{
    if (m_paymentUrl.isEmpty()) {
        qCWarning(chiakiDonation) << "No payment URL available";
        return;
    }
    qCInfo(chiakiDonation) << "Opening donation link in browser";
    QDesktopServices::openUrl(QUrl(m_paymentUrl));
}

void DonationManager::dismiss()
{
    setShowDonationPrompt(false);
    m_settings->SetDonationLastPromptWallClockMs(QDateTime::currentMSecsSinceEpoch());
    qCDebug(chiakiDonation) << "Donation prompt dismissed";
}

void DonationManager::setShowDonationPrompt(bool show)
{
    if (m_showPrompt == show)
        return;
    m_showPrompt = show;
    emit showDonationPromptChanged();
}

void DonationManager::checkDonationStatusAndShow(bool settingsTriggered)
{
#ifdef CHIAKI_IS_MAC_APPSTORE
    if (!m_storeKit)
        return;

    if (m_ownsDonation) {
        qCDebug(chiakiDonation) << "Already owns donation (StoreKit), skipping prompt";
        m_settings->SetDonationLastPromptWallClockMs(QDateTime::currentMSecsSinceEpoch());
        if (settingsTriggered) {
            qCInfo(chiakiDonation) << "Already supporting! (from settings, StoreKit)";
            emit alreadyDonated();
        }
        return;
    }

    static const QStringList productIds = {
        QStringLiteral("pylux_support_bronze"),
        QStringLiteral("pylux_support_silver"),
        QStringLiteral("pylux_support_gold"),
        QStringLiteral("pylux_support_platinum"),
    };
    if (m_iapTiers.isEmpty() && !m_iapLoadFailed)
        m_storeKit->loadProducts(productIds);

    m_settings->SetDonationPromptShowCount(m_settings->GetDonationPromptShowCount() + 1);
    emit promptShowCountChanged();
    m_settings->SetDonationLastPromptWallClockMs(QDateTime::currentMSecsSinceEpoch());
    setShowDonationPrompt(true);
    qCInfo(chiakiDonation) << "Showing donation prompt (App Store, show count:" << m_settings->GetDonationPromptShowCount() << ")";
#else
    QString psnId = resolvePsnOnlineId();
    if (psnId.isEmpty()) {
        fetchPsnOnlineId();
        if (settingsTriggered) {
            qCInfo(chiakiDonation) << "No PSN ID, showing prompt without donation check (settings-triggered)";
            onApiResponse(false, settingsTriggered);
        } else {
            qCDebug(chiakiDonation) << "No PSN online ID, cannot check donation status";
        }
        return;
    }

    bool cachedStatus = false;
    if (m_settings->GetDonationCachedStatus(&cachedStatus) && cachedStatus) {
        qCInfo(chiakiDonation) << "Donation status: already donated (cached)";
        m_donated = true;
        emit donatedChanged();
        m_settings->SetDonationLastPromptWallClockMs(QDateTime::currentMSecsSinceEpoch());
        if (settingsTriggered) {
            qCInfo(chiakiDonation) << "Already supporting! (from settings, cached)";
            emit alreadyDonated();
        }
        return;
    }

    QUrl url(QString("%1/api/donations/status").arg(DONATION_API_BASE_URL));
    QUrlQuery query;
    query.addQueryItem("psn_username", psnId);
    url.setQuery(query);

    QNetworkRequest req(url);
    req.setTransferTimeout(5000);

    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, settingsTriggered]() {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            qCDebug(chiakiDonation) << "Donation API unreachable:" << reply->errorString();
            onApiResponse(false, settingsTriggered);
            return;
        }

        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        QJsonObject obj = doc.object();
        bool donated = obj.value("donated").toBool(false);
        qCInfo(chiakiDonation) << "Donation status: donated =" << donated << "(from API)";

        if (!donated) {
            QString serverPaymentUrl = obj.value("payment_url").toString();
            if (!serverPaymentUrl.isEmpty() && m_paymentUrl != serverPaymentUrl) {
                m_paymentUrl = serverPaymentUrl;
                emit paymentUrlChanged();
                qCInfo(chiakiDonation) << "Payment URL from server:" << serverPaymentUrl;
            }
        }

        if (donated)
            m_settings->SetDonationCachedStatus(true);
        onApiResponse(donated, settingsTriggered);
    });
#endif
}

void DonationManager::onApiResponse(bool donated, bool settingsTriggered)
{
    m_donated = donated;
    emit donatedChanged();

    if (donated) {
        m_settings->SetDonationLastPromptWallClockMs(QDateTime::currentMSecsSinceEpoch());
        if (settingsTriggered) {
            qCInfo(chiakiDonation) << "Already supporting! (from settings, from API)";
            emit alreadyDonated();
        }
        return;
    }

    m_settings->SetDonationPromptShowCount(m_settings->GetDonationPromptShowCount() + 1);
    emit promptShowCountChanged();
    m_settings->SetDonationLastPromptWallClockMs(QDateTime::currentMSecsSinceEpoch());
    setShowDonationPrompt(true);
    qCInfo(chiakiDonation) << "Showing donation prompt (show count:" << m_settings->GetDonationPromptShowCount() << ")";
}

void DonationManager::setPsnOnlineId(const QString &onlineId)
{
    QString trimmed = onlineId.trimmed();
    if (trimmed.isEmpty())
        return;

    if (m_settings->GetDonationPsnOnlineId() != trimmed) {
        m_settings->SetDonationPsnOnlineId(trimmed);
        qCInfo(chiakiDonation) << "PSN online ID cached:" << trimmed;
    }
}

QString DonationManager::psnOnlineId() const
{
    return resolvePsnOnlineId();
}

QString DonationManager::resolvePsnOnlineId() const
{
    return m_settings->GetDonationPsnOnlineId();
}

void DonationManager::fetchPsnOnlineId()
{
    QString authToken = m_settings->GetPsnAuthToken();
    if (authToken.isEmpty()) {
        qCDebug(chiakiDonation) << "No PSN auth token, cannot fetch online ID";
        return;
    }

    QUrl accountInfoUrl(QString("https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/%1").arg(authToken));

    QNetworkRequest req(accountInfoUrl);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QString basicAuth = QString("Basic %1").arg(
        QString(QByteArray("ba495a24-818c-472b-b12d-ff231c1b5745:mvaiZkRsAsI1IBkY").toBase64()));
    req.setRawHeader("Authorization", basicAuth.toUtf8());
    req.setTransferTimeout(5000);

    qCInfo(chiakiDonation) << "Fetching PSN online ID from account info endpoint";

    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            qCWarning(chiakiDonation) << "Failed to fetch PSN online ID:" << reply->errorString();
            return;
        }

        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        QString onlineId = doc.object().value("online_id").toString();
        if (!onlineId.isEmpty()) {
            m_settings->SetDonationPsnOnlineId(onlineId);
            qCInfo(chiakiDonation) << "PSN online ID fetched and cached:" << onlineId;
        } else {
            qCDebug(chiakiDonation) << "No online_id in account info response";
        }
    });
}

QStringList DonationManager::donationPhrases() const
{
    QFile f(QStringLiteral(":/donation_prompt_phrases.json"));
    if (!f.open(QIODevice::ReadOnly)) {
        qCWarning(chiakiDonation) << "Cannot open donation_prompt_phrases.json from resources";
        return {};
    }

    QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    QJsonObject root = doc.object();
    QJsonArray order = root.value("category_order").toArray();
    QJsonObject cats = root.value("categories").toObject();

    QStringList result;
    for (const QJsonValue &catKey : order) {
        QJsonArray phrases = cats.value(catKey.toString()).toObject().value("phrases").toArray();
        for (const QJsonValue &p : phrases)
            result.append(p.toString());
    }
    return result;
}

void DonationManager::purchaseProduct(const QString &productId)
{
#ifdef CHIAKI_IS_MAC_APPSTORE
    if (!m_storeKit || productId.isEmpty())
        return;
    m_purchasingProductId = productId;
    emit purchasingProductIdChanged();
    m_storeKit->purchase(productId);
#else
    Q_UNUSED(productId);
#endif
}

void DonationManager::restorePurchases()
{
#ifdef CHIAKI_IS_MAC_APPSTORE
    if (!m_storeKit)
        return;
    m_storeKit->restorePurchases();
#endif
}

#ifdef CHIAKI_IS_MAC_APPSTORE
void DonationManager::initStoreKit()
{
    m_storeKit = new MacStoreKit(this);

    connect(m_storeKit, &MacStoreKit::productsLoaded, this, [this](const QVariantList &products) {
        m_iapTiers = products;
        m_iapLoadFailed = false;
        emit iapTiersChanged();
        emit iapLoadFailedChanged();
        qCInfo(chiakiDonation) << "Loaded" << products.size() << "IAP tiers";
    });

    connect(m_storeKit, &MacStoreKit::productLoadFailed, this, [this]() {
        m_iapTiers.clear();
        m_iapLoadFailed = true;
        emit iapTiersChanged();
        emit iapLoadFailedChanged();
        qCWarning(chiakiDonation) << "Failed to load IAP products";
    });

    connect(m_storeKit, &MacStoreKit::purchaseSucceeded, this, [this](const QString &productId) {
        qCInfo(chiakiDonation) << "Purchase succeeded:" << productId;
        m_purchasingProductId.clear();
        m_ownsDonation = true;
        m_donated = true;
        emit purchasingProductIdChanged();
        emit ownsDonationChanged();
        emit donatedChanged();
        setShowDonationPrompt(false);
    });

    connect(m_storeKit, &MacStoreKit::purchaseCancelled, this, [this]() {
        qCInfo(chiakiDonation) << "Purchase cancelled";
        m_purchasingProductId.clear();
        emit purchasingProductIdChanged();
    });

    connect(m_storeKit, &MacStoreKit::purchaseFailed, this, [this](const QString &error) {
        qCWarning(chiakiDonation) << "Purchase failed:" << error;
        m_purchasingProductId.clear();
        emit purchasingProductIdChanged();
    });

    connect(m_storeKit, &MacStoreKit::restoreFinished, this, [this](const QString &result) {
        qCInfo(chiakiDonation) << "Restore result:" << result;
        if (result == QStringLiteral("alreadyOnDevice")) {
            m_ownsDonation = true;
            m_donated = true;
            emit ownsDonationChanged();
            emit donatedChanged();
        }
        emit restoreResult(result);
    });

    static const QStringList productIds = {
        QStringLiteral("pylux_support_bronze"),
        QStringLiteral("pylux_support_silver"),
        QStringLiteral("pylux_support_gold"),
        QStringLiteral("pylux_support_platinum"),
    };
    m_storeKit->loadProducts(productIds);

    QTimer::singleShot(2000, this, [this]() {
        if (m_storeKit && !m_ownsDonation) {
            qCInfo(chiakiDonation) << "Checking StoreKit ownership on startup";
            m_storeKit->checkOwnership();
        }
    });
}
#endif
