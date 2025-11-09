// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef STEAMWORKS_CLOUD_SYNC_H
#define STEAMWORKS_CLOUD_SYNC_H

#include <QString>
#include <QObject>
#include <QDateTime>

class Settings;

/**
 * Isolated Steam Cloud Sync for PSStream config files
 * 
 * Handles automatic synchronization of all profile config files with Steam Cloud,
 * including intelligent conflict resolution, backup management, and graceful error handling.
 */
class SteamCloudSync : public QObject
{
    Q_OBJECT

public:
    explicit SteamCloudSync(Settings *settings, QObject *parent = nullptr);
    ~SteamCloudSync();

    /**
     * Initialize cloud sync (must be called after SteamAPI_Init)
     * @return true if initialization successful
     */
    bool initialize();

    /**
     * Bidirectional sync - intelligently sync newer files in both directions
     * @return true if sync completed successfully
     */
    bool syncBidirectional();

    /**
     * Upload all profile config files to Steam Cloud
     * @return true if upload successful
     */
    bool syncAllProfilesToCloud();

    /**
     * Download all profile config files from Steam Cloud
     * @return true if download successful
     */
    int syncAllProfilesFromCloud();

    /**
     * Delete all PSStream config files from Steam Cloud
     * @return true if deletion successful
     */
    bool clearAllCloudData();

    /**
     * Delete a specific profile from Steam Cloud
     * @param profileName Profile name (e.g. "2333" or "default")
     * @return true if deletion successful
     */
    bool deleteProfileFromCloud(const QString &profileName);

    /**
     * Create timestamped backup of a file
     * @param filepath Path to file to backup
     * @return Path to backup file, empty string on failure
     */
    QString createBackup(const QString &filepath);

    /**
     * Remove backup files older than 7 days
     */
    void cleanOldBackups();

    /**
     * Handle dynamic cloud sync changes (Steam Deck suspend/resume)
     */
    void handleDynamicCloudChange();

    /**
     * Check if cloud sync is enabled
     * @return true if enabled
     */
    bool isEnabled() const;

    /**
     * Enable or disable cloud sync
     * @param enabled true to enable, false to disable
     */
    void setEnabled(bool enabled);

    /**
     * Get last sync timestamp
     * @return Last successful sync time
     */
    QDateTime getLastSyncTime() const { return m_lastSyncTime; }

signals:
    /**
     * Emitted when sync completes (success or failure)
     * @param success true if sync was successful
     * @param message Status message
     */
    void syncCompleted(bool success, const QString &message);
    
    /**
     * Emitted when a profile is synced for the first time
     * @param profileName Profile name ("default" or profile number like "2333")
     * @param isUpload true if uploading, false if downloading
     */
    void profileFirstSync(const QString &profileName, bool isUpload);

private:
    /**
     * Get list of all profile config files on disk
     * @return List of absolute file paths
     */
    QStringList getLocalConfigFiles() const;

    /**
     * Get list of all profile config files in Steam Cloud
     * @return List of cloud filenames
     */
    QStringList getCloudConfigFiles() const;

    /**
     * Get cloud filename from local file path (removes path, keeps filename)
     * @param localPath Local file path
     * @return Cloud filename
     */
    QString getCloudFilename(const QString &localPath) const;

    /**
     * Get local file path from cloud filename
     * @param cloudFilename Cloud filename
     * @return Local file path
     */
    QString getLocalFilePath(const QString &cloudFilename) const;

    /**
     * Upload a single file to Steam Cloud with timestamp check
     * @param localPath Local file path
     * @return true if upload successful
     */
    bool uploadFile(const QString &localPath);

    /**
     * Download a single file from Steam Cloud with timestamp check
     * @param cloudFilename Cloud filename
     * @return true if download successful
     */
    bool downloadFile(const QString &cloudFilename);

    /**
     * Compare timestamps and determine which file is newer
     * @param localPath Local file path
     * @param cloudFilename Cloud filename
     * @return -1 if local newer, 0 if equal, 1 if cloud newer, -999 on error
     */
    int compareTimestamps(const QString &localPath, const QString &cloudFilename) const;
    
    /**
     * Extract profile name from filename (PSStream.conf -> "default", PSStream-2333.conf -> "2333")
     * @param filename Config filename
     * @return Profile name
     */
    QString extractProfileName(const QString &filename) const;
    
    /**
     * Check if this profile is new (not yet in the profiles list)
     * @param filename Config filename
     * @return true if profile is new
     */
    bool isNewProfile(const QString &filename) const;

    Settings *m_settings;
    bool m_initialized;
    bool m_enabled;
    QDateTime m_lastSyncTime;
    QString m_configDirectory;
};

#endif // STEAMWORKS_CLOUD_SYNC_H


