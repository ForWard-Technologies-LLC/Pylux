// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_PSKAMAJISESSION_H
#define CHIAKI_PSKAMAJISESSION_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QJSValue>

/**
 * PSKamajiSession - Handles PlayStation Cloud Gaming Kamaji Authentication (Steps 1-6)
 * 
 * Kamaji is Sony's authentication layer for cloud gaming. This class:
 * - Creates and manages cookie-based sessions
 * - Handles OAuth2 authorization flow
 * - Integrates with Sony's account system
 * 
 * Usage:
 *   PSKamajiSession *session = new PSKamajiSession(settings, npsso, kamajiBase, accountBase, ...);
 *   connect(session, &PSKamajiSession::sessionComplete, ...);
 *   session->startSessionCreation();
 */
class PSKamajiSession : public QObject
{
    Q_OBJECT

public:
    explicit PSKamajiSession(
        Settings *settings,
        QString duid,
        QString productId, // Product ID (will be converted to Entitlement ID)
        QString accountBaseUrl,
        QString redirectUri,
        QString userAgent,
        QObject *parent = nullptr
    );

    /**
     * Start the complete Kamaji session creation flow (Steps 0.5a-0.5d, 5-6)
     */
    void startSessionCreation();
    
    /**
     * Get session data (only available after successful authentication)
     */
    QString getAccountId() const { return accountId; }
    QString getOnlineId() const { return onlineId; }
    QString getSessionUrl() const { return sessionUrl; }
    QString getEntitlementId() const { return entitlementId; }
    QString getPlatform() const { return platform; }

signals:
    void sessionComplete(bool success, QString message, QString entitlementId);
    void psPlusSubscriptionError();

private slots:
    void handleAnonAuthCodeResponse(QNetworkReply *reply);
    void handleAnonSessionResponse(QNetworkReply *reply);
    void handleProductIdConversionResponse(QNetworkReply *reply);
    void handleCommerceOAuthTokenResponse(QNetworkReply *reply);
    void handleCheckEntitlementResponse(QNetworkReply *reply);
    void handleCheckoutPreviewResponse(QNetworkReply *reply);
    void handleCheckoutBuynowResponse(QNetworkReply *reply);
    void handleAuthCodeResponse(QNetworkReply *reply);
    void handleAuthSessionResponse(QNetworkReply *reply);

private:
    Settings *settings;
    QNetworkAccessManager *manager;
    
    // Configuration passed from orchestrator
    QString npssoToken;
    QString kamajiBase;
    QString accountBase;
    QString kamajiClientId;
    QString duid;
    QString platform;
    QString productId;
    QString redirectUriUrl;
    QString scopesStr;
    QString userAgentString;
    
    // State tracking
    QString anonAuthCode;      // OAuth code for anonymous session
    QString authorizationCode; // OAuth code for authenticated session
    QString jsessionId;        // JSESSIONID from anonymous session
    QString entitlementId;     // Converted from productId
    QString streamingSku;      // SKU from product ID conversion (for entitlement check)
    QString commerceOAuthToken; // OAuth token for Commerce API (Bearer token)
    
    // Session data (set after successful authentication)
    QString accountId;
    QString onlineId;
    QString sessionUrl;
    
    // Step functions (simplified PSNOW flow)
    // Note: step0_5a_AuthorizeCheck is now handled centrally by CloudStreamingBackend
    void step0_5b_GetAnonymousAuthCode(); // GET /oauth/authorize (for anonymous session code)
    void step0_5c_CreateAnonymousSession(); // POST /user/session (anonymous, with OAuth code)
    void step0_5d_ConvertProductId();   // GET /store/api/pcnow/.../container/.../{PRODUCT_ID}
    void step0_5e_CheckEntitlement();   // Check and acquire entitlement if needed (entitlement_check.py flow)
    void step0_5e_GetCommerceOAuthToken(); // GET /oauth/authorize (response_type=token for Commerce API)
    void step0_5e_CheckEntitlementExists(); // GET /commerce/api/v1/users/me/internal_entitlements/{entitlementId}
    void step0_5e_CheckoutPreview();    // POST /checkout/buynow/preview
    void step0_5e_CheckoutBuynow();     // POST /checkout/buynow
    void step5_GetAuthCode();           // GET /oauth/authorize (for authenticated session code)
    void step6_CreateAuthSession();     // POST /user/session (authenticated, with OAuth code)
};

#endif // CHIAKI_PSKAMAJISESSION_H

