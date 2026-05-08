#pragma once

#include <QObject>
#include <QTimer>
#include <QElapsedTimer>
#include <QNetworkAccessManager>
#include <QVariantList>

#include "settings.h"
#ifdef CHIAKI_IS_MAC_APPSTORE
class MacStoreKit;
#endif

class DonationManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool enabled READ isEnabled CONSTANT)
    Q_PROPERTY(bool showDonationPrompt READ showDonationPrompt WRITE setShowDonationPrompt NOTIFY showDonationPromptChanged)
    Q_PROPERTY(bool donated READ isDonated NOTIFY donatedChanged)
    Q_PROPERTY(QString paymentUrl READ paymentUrl NOTIFY paymentUrlChanged)
    Q_PROPERTY(int promptShowCount READ promptShowCount NOTIFY promptShowCountChanged)
    Q_PROPERTY(bool isAppStore READ isAppStore CONSTANT)
    Q_PROPERTY(QVariantList iapTiers READ iapTiers NOTIFY iapTiersChanged)
    Q_PROPERTY(bool iapLoadFailed READ iapLoadFailed NOTIFY iapLoadFailedChanged)
    Q_PROPERTY(bool ownsDonation READ ownsDonation NOTIFY ownsDonationChanged)
    Q_PROPERTY(QString purchasingProductId READ purchasingProductId NOTIFY purchasingProductIdChanged)

public:
    explicit DonationManager(Settings *settings, QObject *parent = nullptr);

    bool isEnabled() const;
    bool showDonationPrompt() const { return m_showPrompt; }
    void setShowDonationPrompt(bool show);
    bool isDonated() const { return m_donated; }
    QString paymentUrl() const { return m_paymentUrl; }
    int promptShowCount() const { return m_settings->GetDonationPromptShowCount(); }

    Q_INVOKABLE void setPsnOnlineId(const QString &onlineId);
    Q_INVOKABLE QString psnOnlineId() const;
    Q_INVOKABLE void scheduleOfferIfEligible();
    Q_INVOKABLE void cancelScheduledOffer();
    Q_INVOKABLE void markConnected();
    Q_INVOKABLE void flushStreamTime();
    Q_INVOKABLE void openSupportFromSettings();
    Q_INVOKABLE void openInBrowser();
    Q_INVOKABLE void dismiss();
    Q_INVOKABLE QStringList donationPhrases() const;
    Q_INVOKABLE void purchaseProduct(const QString &productId);
    Q_INVOKABLE void restorePurchases();

    bool isAppStore() const;
    QVariantList iapTiers() const { return m_iapTiers; }
    bool iapLoadFailed() const { return m_iapLoadFailed; }
    bool ownsDonation() const { return m_ownsDonation; }
    QString purchasingProductId() const { return m_purchasingProductId; }

signals:
    void showDonationPromptChanged();
    void donatedChanged();
    void paymentUrlChanged();
    void promptShowCountChanged();
    void iapTiersChanged();
    void iapLoadFailedChanged();
    void ownsDonationChanged();
    void purchasingProductIdChanged();
    void restoreResult(const QString &result);
    void alreadyDonated();

private:
    void checkDonationStatusAndShow(bool settingsTriggered);
    void onApiResponse(bool donated, bool settingsTriggered);
    QString resolvePsnOnlineId() const;
    void fetchPsnOnlineId();

    Settings *m_settings;
    QNetworkAccessManager *m_nam;
    QTimer *m_delayTimer;
    QElapsedTimer m_sessionTimer;
    bool m_sessionTimerRunning = false;
    bool m_showPrompt = false;
    bool m_donated = false;
    QString m_paymentUrl;

    QVariantList m_iapTiers;
    bool m_iapLoadFailed = false;
    bool m_ownsDonation = false;
    QString m_purchasingProductId;
#ifdef CHIAKI_IS_MAC_APPSTORE
    MacStoreKit *m_storeKit = nullptr;
    void initStoreKit();
#endif

};
