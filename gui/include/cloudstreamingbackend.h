// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CLOUDSTREAMINGBACKEND_H
#define CLOUDSTREAMINGBACKEND_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QJSValue>
#include <QNetworkAccessManager>
#include <QNetworkCookie>

class QNetworkCookieJar;  // Forward declaration

/**
 * CloudStreamingBackend - Orchestrates PlayStation Plus Cloud Gaming flow
 * 
 * This class is the main entry point for cloud gaming. It:
 * - Holds shared configuration (CloudConfig namespace in .cpp)
 * - Orchestrates Kamaji authentication (PSKamajiSession) 
 * - Orchestrates Gaikai allocation (PSGaikaiStreaming)
 * - Provides a single unified API for the frontend
 * 
 * Architecture:
 *   CloudStreamingBackend (orchestrator)
 *     └─> PSKamajiSession (Steps 1-6: Kamaji auth)
 *     └─> PSGaikaiStreaming (Steps 7-13: Gaikai allocation)
 */
class StreamSession; // Forward declaration

class CloudStreamingBackend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString allocationProgress READ getAllocationProgress NOTIFY allocationProgressChanged)
    Q_PROPERTY(int queuePosition READ getQueuePosition NOTIFY queuePositionChanged)
    Q_PROPERTY(QString gameImageUrl READ getGameImageUrl WRITE setGameImageUrl NOTIFY gameImageUrlChanged)

public:
    explicit CloudStreamingBackend(Settings *settings, QObject *parent = nullptr);

    // MAIN ENTRY POINT - Complete cloud streaming session (Steps 1-13)
    // Parameters:
    //   serviceType: "psnow" or "pscloud"
    //   gameIdentifier: Product ID (PSNOW) or Entitlement ID (PSCLOUD)
    // Platform is automatically detected from API response for PSNOW, or hardcoded to "ps5" for PSCLOUD
    Q_INVOKABLE void startCompleteCloudSession(QString serviceType, QString gameIdentifier, const QJSValue &callback);
    
    QString getAllocationProgress() const { return allocation_progress; }
    int getQueuePosition() const { return queue_position; }
    QString getGameImageUrl() const { return game_image_url; }
    void setGameImageUrl(const QString &url);

signals:
    // Emitted when a cloud streaming session is created and ready to be registered
    void sessionCreated(StreamSession *session);
    // Emitted when allocation progress updates
    void allocationProgressChanged();
    // Emitted when queue position changes
    void queuePositionChanged();
    // Emitted when game image URL changes
    void gameImageUrlChanged();

private slots:
    void onAllocationProgress(QString message, int queuePosition = -1);

private:
    void setAllocationProgress(const QString &message);
    
    // Centralized authorization check (used by both PSNOW and PSCLOUD)
    void checkAuthorization(QString serviceType, QString npssoToken, QString duid, std::function<void(bool)> callback);
    
    // Continue cloud session after successful authorization
    void continueCloudSessionAfterAuth(QString serviceType, QString gameIdentifier, const QJSValue &callback, QString npssoToken, QString sharedDuid);

    Settings *settings;
    QString allocation_progress;
    int queue_position = -1;  // -1 means not queued or no position available
    QString game_image_url;  // Landscape image URL for current cloud game
    QNetworkAccessManager *authManager; // For authorization check
    
    // Helper method to start Gaikai allocation (shared between PSNOW and PSCLOUD flows)
    void startGaikaiAllocation(QString serviceType, QString platform, QString entitlementId,
                                QString duid, QNetworkCookieJar *cookieJar,
                                QString redirectUri, QString userAgent, QString oauthApiPath,
                                ChiakiTarget target, const QJSValue &callback, QObject *kamajiSession);
};

#endif // CLOUDSTREAMINGBACKEND_H
