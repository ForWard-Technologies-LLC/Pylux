// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef STEAMWORKS_WRAPPER_H
#define STEAMWORKS_WRAPPER_H

#include <QString>
#include <QObject>

/**
 * Isolated Steamworks API wrapper for PSStream
 * 
 * This class provides a minimal interface to Steamworks SDK functionality
 * while keeping Steam integration completely separate from the main codebase.
 */
class SteamworksWrapper : public QObject
{
    Q_OBJECT

public:
    explicit SteamworksWrapper(QObject *parent = nullptr);
    ~SteamworksWrapper();

    /**
     * Initialize Steam API with the provided App ID
     * @param appId Your Steam App ID
     * @return true if Steam API initialized successfully
     */
    bool initialize(uint32_t appId);

    /**
     * Check if Steam client is running and API is available
     * @return true if Steam is available
     */
    bool isSteamAvailable() const;

    /**
     * Activate Steam overlay to web page (for PSN OAuth)
     * @param url The PlayStation OAuth URL to display
     * @return true if overlay was activated successfully
     */
    bool activateGameOverlayToWebPage(const QString &url);

    /**
     * Shutdown Steam API (called automatically in destructor)
     */
    void shutdown();

private:
    bool m_initialized;
    bool m_steamAvailable;
    uint32_t m_appId;
};

#endif // STEAMWORKS_WRAPPER_H



