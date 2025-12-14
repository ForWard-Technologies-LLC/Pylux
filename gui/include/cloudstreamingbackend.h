// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CLOUDSTREAMINGBACKEND_H
#define CLOUDSTREAMINGBACKEND_H

#include "settings.h"

#include <QObject>
#include <QString>
#include <QJSValue>

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

public:
    explicit CloudStreamingBackend(Settings *settings, QObject *parent = nullptr);

    // MAIN ENTRY POINT - Complete cloud streaming session (Steps 1-13)
    Q_INVOKABLE void startCompleteCloudSession(const QJSValue &callback);

signals:
    // Emitted when a cloud streaming session is created and ready to be registered
    void sessionCreated(StreamSession *session);

private:
    Settings *settings;
};

#endif // CLOUDSTREAMINGBACKEND_H
