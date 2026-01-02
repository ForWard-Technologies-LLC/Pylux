// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef STEAMWORKS_WRAPPER_H
#define STEAMWORKS_WRAPPER_H

#include <QString>
#include <QObject>

// Forward declarations
class SteamCloudSync;
class Settings;

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
    enum OwnershipResult
    {
        HasLicense,
        NoLicense,
        NotRunning,
        NotAuthenticated
    };

    explicit SteamworksWrapper(QObject *parent = nullptr);
    ~SteamworksWrapper();

    /**
     * Initialize Steam API with the provided App ID
     * @param appId Your Steam App ID
     * @param settings Settings object for cloud sync (optional)
     * @return true if Steam API initialized successfully
     */
    bool initialize(uint32_t appId, Settings *settings = nullptr);

    /**
     * Check if Steam client is running and API is available
     * @return true if Steam is available
     */
    bool isSteamAvailable() const;

    /**
     * Check if the current user owns the app
     * @return OwnershipResult indicating license status
     */
    OwnershipResult checkOwnership();

    /**
     * Set Steam Enhanced Rich Presence status
     * Uses Enhanced Rich Presence with localization tokens:
     * - If gameName is provided: Shows "Playing: [gameName]" via #StatusCloudGame token
     * - If gameName is empty: Shows "Remote Play" via #StatusRemotePlayGame token
     * @param gameName Optional game name - if provided, displays it in rich presence
     * @return true if rich presence was set successfully
     * 
     * Note: Requires localization file to be uploaded to Steamworks Partner portal
     * See: third-party/steamworks/rich_presence_localization.vdf
     */
    bool setRichPresence(const QString &gameName = QString());

    /**
     * Call SteamAPI_RunCallbacks to process Steam events
     */
    void runCallbacks();

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

    /**
     * Get cloud sync instance
     * @return Pointer to cloud sync manager, or nullptr if not available
     */
    SteamCloudSync* getCloudSync() const { return m_cloudSync; }

private:
    bool m_initialized;
    bool m_steamAvailable;
    uint32_t m_appId;
    SteamCloudSync* m_cloudSync;
};

#endif // STEAMWORKS_WRAPPER_H



