// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CLOUDSTREAMINGBACKEND_H
#define CLOUDSTREAMINGBACKEND_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QJSValue>

// ============================================================================
// CONFIGURATION - Shared settings and values used by multiple classes
// ============================================================================
namespace CloudConfig {
    // Shared base values (used by both PSNOW and PSCLOUD)
    static const QString ACCOUNT_BASE = "https://ca.account.sony.com/api";
}

/**
 * CloudStreamingBackend - Orchestrates PlayStation Plus Cloud Gaming flow
 * 
 * This class is the main entry point for cloud gaming. It:
 * - Holds shared configuration (CloudConfig namespace in header)
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

    // Continue cloud session: runs the unified C
    // provisioning flow (chiaki_cloud_provision_session) on a worker thread and
    // hands the stream-ready result to StreamSession. Kamaji+Gaikai, the owned
    // fast-path and the one-shot noGameForEntitlementId retry all live in libchiaki.
    void continueCloudSessionAfterAuth(QString serviceType, QString gameIdentifier, const QJSValue &callback, QString npssoToken, QString sharedDuid);

    // Build StreamSessionConnectInfo from a successful provision result and start the session.
    void finishCloudSession(QString serviceType, QString serverIp, int serverPort,
                            QString handshakeKey, QString launchSpec, QString sessionId,
                            uint8_t psnWrapperType, uint32_t mtuIn, uint32_t mtuOut, uint64_t rttUs,
                            const QJSValue &callback);
    // Map a provisioning failure (error_message sentinels) to the right UI dialog.
    void handleProvisionError(QString serviceType, QString errorMessage, const QJSValue &callback);
    // C progress callback (called from the worker thread): marshals to setAllocationProgress.
    static void provisionProgressThunk(const char *stage, void *user);

    Settings *settings;
    QString allocation_progress;
    int queue_position = -1;  // -1 means not queued or no position available
    QString game_image_url;  // Landscape image URL for current cloud game
};

#endif // CLOUDSTREAMINGBACKEND_H
