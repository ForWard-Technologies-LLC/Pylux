// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_PSKAMAJISESSION_H
#define CHIAKI_PSKAMAJISESSION_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QNetworkAccessManager>
#include <QNetworkCookieJar>
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
        QString npsso,
        QString duid,
        QString accountBaseUrl,
        QString redirectUri,
        QString userAgent,
        QObject *parent = nullptr
    );

    /**
     * Start the complete Kamaji session creation flow (Steps 1-6)
     */
    void startSessionCreation();

    /**
     * Get the cookie jar with authenticated session cookies
     */
    QNetworkCookieJar* getCookieJar() const { return cookieJar; }
    
    /**
     * Get session data (only available after successful authentication)
     */
    QString getAccountId() const { return accountId; }
    QString getOnlineId() const { return onlineId; }
    QString getSessionUrl() const { return sessionUrl; }

signals:
    void sessionComplete(bool success, QString message);

private slots:
    void handleDeleteResponse(QNetworkReply *reply);
    void handleCreateResponse(QNetworkReply *reply);
    void handleSignOutResponse(QNetworkReply *reply);
    void handleAuthorizeCheckResponse(QNetworkReply *reply);
    void handleAuthCodeResponse(QNetworkReply *reply);
    void handleAuthSessionResponse(QNetworkReply *reply);

private:
    Settings *settings;
    QNetworkAccessManager *manager;
    QNetworkCookieJar *cookieJar;
    
    // Configuration passed from orchestrator
    QString npssoToken;
    QString kamajiBase;
    QString accountBase;
    QString kamajiClientId;
    QString duid;
    QString redirectUriUrl;
    QString scopesStr;
    QString userAgentString;
    
    // State tracking
    QString authorizationCode;
    
    // Session data (set after successful authentication)
    QString accountId;
    QString onlineId;
    QString sessionUrl;
    
    // Step functions (parallel to PSGaikaiStreaming structure)
    void step1_DeleteExisting();
    void step2_CreateAnonymous();
    void step3_SignOut();
    void step4_AuthorizeCheck();
    void step5_GetAuthCode();
    void step6_CreateAuthSession();
};

#endif // CHIAKI_PSKAMAJISESSION_H

