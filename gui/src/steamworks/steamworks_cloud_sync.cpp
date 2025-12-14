// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "steamworks/steamworks_cloud_sync.h"
#include "qmlmainwindow.h"
#include "settings.h"

#ifdef CHIAKI_ENABLE_STEAMWORKS
    #include "steam/steam_api.h"
#endif

#include <QDebug>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QStandardPaths>
#include <QSettings>
#include <QDateTime>
#include <QElapsedTimer>
#include <QLoggingCategory>

// Backup retention period (7 days)
static const int BACKUP_RETENTION_DAYS = 7;

// Sync timeout (5 seconds)
static const int SYNC_TIMEOUT_MS = 5000;

SteamCloudSync::SteamCloudSync(Settings *settings, QObject *parent)
    : QObject(parent)
    , m_settings(settings)
    , m_initialized(false)
    , m_enabled(true)
{
    m_configDirectory = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    
    if (m_settings) {
        qCInfo(chiakiGui) << "SteamCloudSync: Constructor - Settings object provided, will read enabled state dynamically";
    } else {
        qCWarning(chiakiGui) << "SteamCloudSync: Constructor - No Settings object provided, defaulting to enabled";
    }
}

SteamCloudSync::~SteamCloudSync()
{
}

bool SteamCloudSync::initialize()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    qCInfo(chiakiGui) << "SteamCloudSync: Starting initialization...";
    
    if (!SteamAPI_IsSteamRunning()) {
        qCWarning(chiakiGui) << "SteamCloudSync: Steam client not running";
        return false;
    }
    qCInfo(chiakiGui) << "SteamCloudSync: Steam client is running";

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to get Steam Remote Storage interface";
        return false;
    }
    qCInfo(chiakiGui) << "SteamCloudSync: Got Steam Remote Storage interface";

    // Check if Steam Cloud is enabled for this app in Steamworks Partner
    bool appEnabled = remoteStorage->IsCloudEnabledForApp();
    qCInfo(chiakiGui) << "SteamCloudSync: IsCloudEnabledForApp() returned:" << appEnabled;
    
    if (!appEnabled) {
        qCWarning(chiakiGui) << "SteamCloudSync: Steam Cloud is not enabled for this app in Steamworks Partner dashboard";
        m_initialized = false;
        return false;
    }

    // Check if user has Steam Cloud enabled in their Steam client settings
    bool accountEnabled = remoteStorage->IsCloudEnabledForAccount();
    qCInfo(chiakiGui) << "SteamCloudSync: IsCloudEnabledForAccount() returned:" << accountEnabled;
    
    if (!accountEnabled) {
        qCWarning(chiakiGui) << "SteamCloudSync: Steam Cloud is disabled in user's Steam client settings";
        qCWarning(chiakiGui) << "SteamCloudSync: User can enable it in Steam > Settings > Cloud";
        m_initialized = false;
        return false;
    }

    m_initialized = true;
    qCInfo(chiakiGui) << "SteamCloudSync: ✓ Initialized successfully (Cloud enabled for app and account)";
    
    // Clean up old backups on initialization
    cleanOldBackups();
    
    return true;
#else
    qCWarning(chiakiGui) << "SteamCloudSync: Steamworks support not compiled in";
    return false;
#endif
}

bool SteamCloudSync::syncBidirectional()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot sync - not initialized";
        return false;
    }
    
    if (!m_enabled) {
        qCInfo(chiakiGui) << "SteamCloudSync: Sync skipped - disabled in settings";
        return false;
    }

    QElapsedTimer timer;
    timer.start();

    qCInfo(chiakiGui) << "SteamCloudSync: Starting bidirectional sync...";

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qCWarning(chiakiGui) << "SteamCloudSync: Remote storage interface not available";
        return false;
    }

    bool overallSuccess = true;
    int uploaded = 0, downloaded = 0, skipped = 0;

    // Get all local and cloud files
    QStringList localFiles = getLocalConfigFiles();
    QStringList cloudFiles = getCloudConfigFiles();

    qCInfo(chiakiGui) << "SteamCloudSync: Found" << localFiles.size() << "local config file(s)";
    for (const QString &file : localFiles) {
        qCInfo(chiakiGui) << "  Local:" << file;
    }
    qCInfo(chiakiGui) << "SteamCloudSync: Found" << cloudFiles.size() << "cloud config file(s)";
    for (const QString &file : cloudFiles) {
        qCInfo(chiakiGui) << "  Cloud:" << file;
    }

    // Create a set of all unique filenames
    QSet<QString> allFiles;
    for (const QString &localPath : localFiles) {
        allFiles.insert(getCloudFilename(localPath));
    }
    // Qt 6: toSet() was removed, convert manually
    for (const QString &cloudFile : cloudFiles) {
        allFiles.insert(cloudFile);
    }

    qCInfo(chiakiGui) << "SteamCloudSync: Processing" << allFiles.size() << "unique file(s)";

    // Begin batch write operation
    remoteStorage->BeginFileWriteBatch();

    // Process each file
    for (const QString &cloudFilename : allFiles) {
        // Check timeout
        if (timer.elapsed() > SYNC_TIMEOUT_MS) {
            qCWarning(chiakiGui) << "SteamCloudSync: Sync timeout after" << timer.elapsed() << "ms";
            break;
        }

        QString localPath = getLocalFilePath(cloudFilename);
        bool localExists = QFile::exists(localPath);
        bool cloudExists = remoteStorage->FileExists(cloudFilename.toUtf8().constData());

        qCInfo(chiakiGui) << "SteamCloudSync: Processing" << cloudFilename 
                << "- Local:" << (localExists ? "EXISTS" : "MISSING")
                << "- Cloud:" << (cloudExists ? "EXISTS" : "MISSING");

        if (!localExists && !cloudExists) {
            qCInfo(chiakiGui) << "  Skipping (neither exists)";
            continue; // Neither exists, skip
        }

        if (localExists && !cloudExists) {
            // Only local exists, upload
            qCInfo(chiakiGui) << "  Action: UPLOAD (only local exists)";
            if (uploadFile(localPath)) {
                uploaded++;
            } else {
                overallSuccess = false;
            }
        } else if (!localExists && cloudExists) {
            // Only cloud exists, download
            qCInfo(chiakiGui) << "  Action: DOWNLOAD (only cloud exists)";
            if (downloadFile(cloudFilename)) {
                downloaded++;
            } else {
                overallSuccess = false;
            }
        } else {
            // Both exist, compare timestamps
            qCInfo(chiakiGui) << "  Action: COMPARE (both exist)";
            int comparison = compareTimestamps(localPath, cloudFilename);
            
            if (comparison < 0 && comparison != -999) {
                // Local is newer, upload
                if (uploadFile(localPath)) {
                    uploaded++;
                } else {
                    overallSuccess = false;
                }
            } else if (comparison > 0) {
                // Cloud is newer, download (with backup)
                QString backup = createBackup(localPath);
                
                if (downloadFile(cloudFilename)) {
                    downloaded++;
                } else {
                    overallSuccess = false;
                }
            } else if (comparison == 0) {
                // Timestamps equal, skip
                qCInfo(chiakiGui) << "  Action: SKIP (files are in sync)";
                skipped++;
            }
        }
    }

    // End batch write operation
    remoteStorage->EndFileWriteBatch();

    // Run callbacks to ensure uploads complete
    SteamAPI_RunCallbacks();

    m_lastSyncTime = QDateTime::currentDateTime();

    QString message = QString("Sync complete: %1 uploaded, %2 downloaded, %3 skipped")
                        .arg(uploaded).arg(downloaded).arg(skipped);
    qCInfo(chiakiGui) << "SteamCloudSync:" << message;
    
    emit syncCompleted(overallSuccess, message);
    
    return overallSuccess;
#else
    return false;
#endif
}

bool SteamCloudSync::syncAllProfilesToCloud()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_enabled) {
        return false;
    }

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        return false;
    }

    QStringList localFiles = getLocalConfigFiles();
    if (localFiles.isEmpty()) {
        qCInfo(chiakiGui) << "SteamCloudSync: No local config files to upload";
        return true;
    }

    remoteStorage->BeginFileWriteBatch();
    
    bool success = true;
    for (const QString &localPath : localFiles) {
        if (!uploadFile(localPath)) {
            success = false;
        }
    }
    
    remoteStorage->EndFileWriteBatch();
    SteamAPI_RunCallbacks();

    return success;
#else
    return false;
#endif
}

int SteamCloudSync::syncAllProfilesFromCloud()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot download - not initialized";
        return 0;
    }
    
    if (!m_enabled) {
        qCInfo(chiakiGui) << "SteamCloudSync: Download skipped - disabled in settings";
        return 0;
    }

    qCInfo(chiakiGui) << "SteamCloudSync: Starting download from cloud...";

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qCWarning(chiakiGui) << "SteamCloudSync: Remote storage interface not available";
        return 0;
    }

    QStringList cloudFiles = getCloudConfigFiles();
    if (cloudFiles.isEmpty()) {
        qCInfo(chiakiGui) << "SteamCloudSync: No cloud config files to download";
        return 0;
    }
    
    qCInfo(chiakiGui) << "SteamCloudSync: Found" << cloudFiles.size() << "file(s) in cloud to download";

    int downloadedCount = 0;
    for (const QString &cloudFilename : cloudFiles) {
        QString localPath = getLocalFilePath(cloudFilename);
        bool shouldDownload = false;
        bool isNew = isNewProfile(cloudFilename);
        
        if (!QFile::exists(localPath)) {
            // Local file doesn't exist, download it
            qCInfo(chiakiGui) << "SteamCloudSync: Local file doesn't exist, will download:" << cloudFilename;
            shouldDownload = true;
        } else {
            // Local file exists, check if cloud version is newer
            QFileInfo localInfo(localPath);
            QDateTime localModTime = localInfo.lastModified();
            
            int32 fileSize = remoteStorage->GetFileSize(cloudFilename.toUtf8().constData());
            int64 timestamp = remoteStorage->GetFileTimestamp(cloudFilename.toUtf8().constData());
            QDateTime cloudModTime = QDateTime::fromSecsSinceEpoch(timestamp);
            
            if (cloudModTime > localModTime) {
                qCInfo(chiakiGui) << "SteamCloudSync: Cloud version is newer, will download:" << cloudFilename;
                qCInfo(chiakiGui) << "  Local:" << localModTime << "Cloud:" << cloudModTime;
                createBackup(localPath);
                shouldDownload = true;
            }
        }
        
        if (shouldDownload && downloadFile(cloudFilename)) {
            // Only count as "downloaded" for toast if it's a new profile
            // (AddProfile is already called inside downloadFile to register it)
            if (isNew) {
                downloadedCount++;
            }
        }
    }

    qCInfo(chiakiGui) << "SteamCloudSync: Downloaded" << downloadedCount << "profile(s) from Steam Cloud";
    return downloadedCount;
#else
    return 0;
#endif
}

bool SteamCloudSync::clearAllCloudData()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    qCInfo(chiakiGui) << "SteamCloudSync: clearAllCloudData() called";
    
    if (!m_initialized) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot clear cloud data - not initialized";
        return false;
    }

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot clear cloud data - failed to get Steam Remote Storage interface";
        return false;
    }

    QStringList cloudFiles = getCloudConfigFiles();
    qCInfo(chiakiGui) << "SteamCloudSync: Found" << cloudFiles.size() << "cloud file(s) to delete";
    
    if (cloudFiles.isEmpty()) {
        qCInfo(chiakiGui) << "SteamCloudSync: No cloud files to delete";
        return true;
    }
    
    for (const QString &file : cloudFiles) {
        qCInfo(chiakiGui) << "SteamCloudSync:   - Will delete:" << file;
    }

    remoteStorage->BeginFileWriteBatch();
    
    int deletedCount = 0;
    int failedCount = 0;
    bool success = true;
    
    for (const QString &cloudFilename : cloudFiles) {
        qCInfo(chiakiGui) << "SteamCloudSync: Attempting to delete" << cloudFilename;
        
        if (remoteStorage->FileDelete(cloudFilename.toUtf8().constData())) {
            qCInfo(chiakiGui) << "SteamCloudSync: ✓ Successfully deleted" << cloudFilename << "from cloud";
            deletedCount++;
        } else {
            qCWarning(chiakiGui) << "SteamCloudSync: ✗ Failed to delete" << cloudFilename << "from cloud";
            failedCount++;
            success = false;
        }
    }
    
    remoteStorage->EndFileWriteBatch();
    SteamAPI_RunCallbacks();
    
    qCInfo(chiakiGui) << "SteamCloudSync: Clear operation complete -" << deletedCount << "deleted," << failedCount << "failed";

    return success;
#else
    qCWarning(chiakiGui) << "SteamCloudSync: Steamworks support not compiled in";
    return false;
#endif
}

bool SteamCloudSync::deleteProfileFromCloud(const QString &profileName)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    qCInfo(chiakiGui) << "SteamCloudSync: deleteProfileFromCloud() called for profile:" << profileName;
    
    if (!m_initialized) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot delete profile from cloud - not initialized";
        return false;
    }

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot delete profile - failed to get Steam Remote Storage interface";
        return false;
    }

    // Convert profile name to cloud filename
    QString cloudFilename;
    if (profileName.isEmpty() || profileName == "default") {
        cloudFilename = "PSStream.conf";
    } else {
        cloudFilename = QString("PSStream-%1.conf").arg(profileName);
    }

    // Check if file exists in cloud
    if (!remoteStorage->FileExists(cloudFilename.toUtf8().constData())) {
        qCInfo(chiakiGui) << "SteamCloudSync: Profile" << profileName << "(" << cloudFilename << ") not found in cloud";
        return true; // Not an error if it doesn't exist
    }

    qCInfo(chiakiGui) << "SteamCloudSync: Attempting to delete" << cloudFilename << "from cloud";
    
    if (remoteStorage->FileDelete(cloudFilename.toUtf8().constData())) {
        qCInfo(chiakiGui) << "SteamCloudSync: ✓ Successfully deleted" << cloudFilename << "from Steam Cloud";
        SteamAPI_RunCallbacks();
        return true;
    } else {
        qCWarning(chiakiGui) << "SteamCloudSync: ✗ Failed to delete" << cloudFilename << "from Steam Cloud";
        return false;
    }
#else
    Q_UNUSED(profileName)
    qCWarning(chiakiGui) << "SteamCloudSync: Steamworks support not compiled in";
    return false;
#endif
}

QString SteamCloudSync::createBackup(const QString &filepath)
{
    QFileInfo fileInfo(filepath);
    if (!fileInfo.exists()) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot backup non-existent file:" << filepath;
        return QString();
    }

    // Create backup directory if it doesn't exist
    QString backupDir = m_configDirectory + "/profile_backups";
    QDir dir;
    if (!dir.exists(backupDir)) {
        if (!dir.mkpath(backupDir)) {
            qCWarning(chiakiGui) << "SteamCloudSync: Failed to create backup directory:" << backupDir;
            return QString();
        }
    }

    QString timestamp = QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss");
    QString backupPath = QString("%1/%2.backup-%3")
                            .arg(backupDir)
                            .arg(fileInfo.fileName())
                            .arg(timestamp);

    qCInfo(chiakiGui) << "SteamCloudSync: Creating backup of" << fileInfo.fileName()
            << "- Size:" << fileInfo.size() << "bytes"
            << "- Modified:" << fileInfo.lastModified().toString("yyyy-MM-dd HH:mm:ss");

    if (QFile::copy(filepath, backupPath)) {
        qCInfo(chiakiGui) << "SteamCloudSync: Backup saved to: profile_backups/" << QFileInfo(backupPath).fileName();
        return backupPath;
    } else {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to create backup of" << filepath;
        return QString();
    }
}

void SteamCloudSync::cleanOldBackups()
{
    QString backupDir = m_configDirectory + "/profile_backups";
    QDir backupDirectory(backupDir);
    if (!backupDirectory.exists()) {
        return;
    }

    // Find all backup files
    QStringList filters;
    filters << "*.backup-*";
    QFileInfoList backups = backupDirectory.entryInfoList(filters, QDir::Files);

    QDateTime cutoffDate = QDateTime::currentDateTime().addDays(-BACKUP_RETENTION_DAYS);
    int deletedCount = 0;

    for (const QFileInfo &backup : backups) {
        if (backup.lastModified() < cutoffDate) {
            if (QFile::remove(backup.absoluteFilePath())) {
                deletedCount++;
                qCInfo(chiakiGui) << "SteamCloudSync: Deleted old backup:" << backup.fileName();
            }
        }
    }

    if (deletedCount > 0) {
        qCInfo(chiakiGui) << "SteamCloudSync: Cleaned up" << deletedCount << "old backup file(s) from profile_backups";
    }
}

void SteamCloudSync::handleDynamicCloudChange()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_enabled) {
        return;
    }

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        return;
    }

    // Check for local file changes
    int changeCount = remoteStorage->GetLocalFileChangeCount();
    if (changeCount > 0) {
        qCInfo(chiakiGui) << "SteamCloudSync: Detected" << changeCount << "file changes from cloud";
        
        for (int i = 0; i < changeCount; i++) {
            ERemoteStorageLocalFileChange changeType;
            ERemoteStorageFilePathType pathType;
            
            const char* filename = remoteStorage->GetLocalFileChange(i, &changeType, &pathType);
            if (filename) {
                qCInfo(chiakiGui) << "SteamCloudSync: File change detected:" << filename << "Type:" << changeType;
                
                // Reload config if it was changed
                if (changeType == k_ERemoteStorageLocalFileChange_FileUpdated || 
                    changeType == k_ERemoteStorageLocalFileChange_FileDeleted) {
                    // Emit signal to notify UI that configs may have changed
                    emit syncCompleted(true, QString("Cloud file updated: %1").arg(filename));
                }
            }
        }
    }
#endif
}

QString SteamCloudSync::extractProfileName(const QString &filename) const
{
    // Extract just the filename without path
    QFileInfo fileInfo(filename);
    QString basename = fileInfo.fileName();
    
    // PSStream.conf -> "default"
    if (basename == "PSStream.conf") {
        return "default";
    }
    
    // PSStream-2333.conf -> "2333"
    if (basename.startsWith("PSStream-") && basename.endsWith(".conf")) {
        QString profile = basename.mid(9); // Remove "PSStream-"
        profile = profile.left(profile.length() - 5); // Remove ".conf"
        return profile;
    }
    
    return basename;
}

bool SteamCloudSync::isNewProfile(const QString &filename) const
{
    if (!m_settings) {
        return false;
    }
    
    QString profileName = extractProfileName(filename);
    if (profileName.isEmpty()) {
        return false;
    }
    
    // Default profile is always considered "not new"
    if (profileName == "default") {
        return false;
    }
    
    // Check if profile exists in the profiles list
    QList<QString> existingProfiles = m_settings->GetProfiles();
    return !existingProfiles.contains(profileName);
}

bool SteamCloudSync::isEnabled() const
{
    // Always read from Settings to get real-time value (user can change via UI)
    if (m_settings) {
        return m_settings->GetSteamCloudSync();
    }
    return m_enabled;
}

void SteamCloudSync::setEnabled(bool enabled)
{
    // Save to Settings object (respects active profile)
    if (m_settings) {
        bool currentValue = m_settings->GetSteamCloudSync();
        if (currentValue != enabled) {
            m_settings->SetSteamCloudSync(enabled);
            qCInfo(chiakiGui) << "SteamCloudSync: Sync" << (enabled ? "enabled" : "disabled") << "and saved to active profile";
        }
    } else {
        qCWarning(chiakiGui) << "SteamCloudSync: No Settings object, cannot save enabled state";
        m_enabled = enabled;  // Fallback to cached value if no Settings
    }
}

QStringList SteamCloudSync::getLocalConfigFiles() const
{
    QDir configDir(m_configDirectory);
    if (!configDir.exists()) {
        return QStringList();
    }

    // Find PSStream.conf and PSStream-*.conf files
    QStringList filters;
    filters << "PSStream.conf" << "PSStream-*.conf";
    
    QFileInfoList files = configDir.entryInfoList(filters, QDir::Files);
    QStringList paths;
    
    for (const QFileInfo &file : files) {
        paths.append(file.absoluteFilePath());
    }
    
    return paths;
}

QStringList SteamCloudSync::getCloudConfigFiles() const
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        return QStringList();
    }

    QStringList cloudFiles;
    int32 fileCount = remoteStorage->GetFileCount();
    
    for (int32 i = 0; i < fileCount; i++) {
        int32 fileSize;
        const char *filename = remoteStorage->GetFileNameAndSize(i, &fileSize);
        
        QString name = QString::fromUtf8(filename);
        // Only include PSStream config files
        if (name.startsWith("PSStream") && name.endsWith(".conf")) {
            cloudFiles.append(name);
        }
    }
    
    return cloudFiles;
#else
    return QStringList();
#endif
}

QString SteamCloudSync::getCloudFilename(const QString &localPath) const
{
    return QFileInfo(localPath).fileName();
}

QString SteamCloudSync::getLocalFilePath(const QString &cloudFilename) const
{
    return m_configDirectory + "/" + cloudFilename;
}

bool SteamCloudSync::uploadFile(const QString &localPath)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        return false;
    }

    // Verify cloud is still enabled
    if (!remoteStorage->IsCloudEnabledForApp() || !remoteStorage->IsCloudEnabledForAccount()) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot upload - Steam Cloud is not enabled";
        return false;
    }

    QFile file(localPath);
    if (!file.open(QIODevice::ReadOnly)) {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to open file for reading:" << localPath;
        return false;
    }

    QByteArray data = file.readAll();
    file.close();

    if (data.isEmpty()) {
        qCWarning(chiakiGui) << "SteamCloudSync: File is empty, skipping upload:" << localPath;
        return false;
    }
    
    // Additional validation: ensure file size is reasonable
    if (data.size() <= 0 || data.size() > 20 * 1024 * 1024) {  // Max 20MB for profile configs
        qCWarning(chiakiGui) << "SteamCloudSync: File size invalid or too large:" << localPath 
                   << "- Size:" << data.size() << "bytes";
        return false;
    }

    // Get local file info for logging
    QFileInfo localInfo(localPath);
    QString cloudFilename = getCloudFilename(localPath);
    
    qCInfo(chiakiGui) << "SteamCloudSync: Uploading" << cloudFilename 
            << "- Size:" << data.size() << "bytes"
            << "- Modified:" << localInfo.lastModified().toString("yyyy-MM-dd HH:mm:ss");
    
    bool success = remoteStorage->FileWrite(cloudFilename.toUtf8().constData(),
                                            data.constData(),
                                            data.size());

    if (success) {
        // Verify the upload by checking the cloud file size
        int32 cloudFileSize = remoteStorage->GetFileSize(cloudFilename.toUtf8().constData());
        if (cloudFileSize == data.size()) {
            qCInfo(chiakiGui) << "SteamCloudSync: Successfully uploaded" << cloudFilename << "to Steam Cloud"
                     << "- Verified size:" << cloudFileSize << "bytes";
        } else {
            qCWarning(chiakiGui) << "SteamCloudSync: Upload succeeded but size mismatch for" << cloudFilename
                       << "- Expected:" << data.size() << "bytes, Cloud has:" << cloudFileSize << "bytes";
            
            // Delete the corrupted upload
            remoteStorage->FileDelete(cloudFilename.toUtf8().constData());
            qCWarning(chiakiGui) << "SteamCloudSync: Deleted corrupted upload:" << cloudFilename;
            return false;
        }
    } else {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to upload" << cloudFilename;
        qCWarning(chiakiGui) << "SteamCloudSync: This usually means Steam Cloud is not enabled in Steamworks Partner";
    }

    return success;
#else
    Q_UNUSED(localPath)
    return false;
#endif
}

bool SteamCloudSync::downloadFile(const QString &cloudFilename)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        return false;
    }

    // Verify cloud is still enabled
    if (!remoteStorage->IsCloudEnabledForApp() || !remoteStorage->IsCloudEnabledForAccount()) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cannot download - Steam Cloud is not enabled";
        return false;
    }

    if (!remoteStorage->FileExists(cloudFilename.toUtf8().constData())) {
        qCWarning(chiakiGui) << "SteamCloudSync: Cloud file does not exist:" << cloudFilename;
        return false;
    }

    int32 fileSize = remoteStorage->GetFileSize(cloudFilename.toUtf8().constData());
    if (fileSize <= 0) {
        qCWarning(chiakiGui) << "SteamCloudSync: Invalid file size for" << cloudFilename;
        qCWarning(chiakiGui) << "SteamCloudSync: Deleting corrupted cloud file:" << cloudFilename;
        
        // Delete the corrupted file from Steam Cloud
        bool deleted = remoteStorage->FileDelete(cloudFilename.toUtf8().constData());
        if (deleted) {
            qCInfo(chiakiGui) << "SteamCloudSync: Successfully deleted corrupted file:" << cloudFilename;
        } else {
            qCWarning(chiakiGui) << "SteamCloudSync: Failed to delete corrupted file:" << cloudFilename;
        }
        
        return false;
    }

    // Get cloud file info for logging
    int64 cloudTimestamp = remoteStorage->GetFileTimestamp(cloudFilename.toUtf8().constData());
    QDateTime cloudTime = QDateTime::fromSecsSinceEpoch(cloudTimestamp);
    
    qCInfo(chiakiGui) << "SteamCloudSync: Downloading" << cloudFilename 
            << "- Size:" << fileSize << "bytes"
            << "- Modified:" << cloudTime.toString("yyyy-MM-dd HH:mm:ss");

    QByteArray buffer(fileSize, 0);
    int32 bytesRead = remoteStorage->FileRead(cloudFilename.toUtf8().constData(),
                                              buffer.data(),
                                              fileSize);

    if (bytesRead != fileSize) {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to read complete file from cloud:" << cloudFilename 
                   << "- Expected:" << fileSize << "bytes, Got:" << bytesRead << "bytes";
        return false;
    }

    QString localPath = getLocalFilePath(cloudFilename);
    QFile file(localPath);
    if (!file.open(QIODevice::WriteOnly)) {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to open file for writing:" << localPath;
        return false;
    }

    qint64 bytesWritten = file.write(buffer);
    file.close();

    if (bytesWritten != fileSize) {
        qCWarning(chiakiGui) << "SteamCloudSync: Failed to write complete file:" << localPath
                   << "- Expected:" << fileSize << "bytes, Wrote:" << bytesWritten << "bytes";
        return false;
    }

    qCInfo(chiakiGui) << "SteamCloudSync: Successfully downloaded" << cloudFilename << "from Steam Cloud";
    
    // Register the profile in settings if it doesn't exist
    // This both makes it available in the UI and marks it as "synced"
    if (m_settings) {
        QString profileName = extractProfileName(cloudFilename);
        if (!profileName.isEmpty() && profileName != "default") {
            QList<QString> existingProfiles = m_settings->GetProfiles();
            if (!existingProfiles.contains(profileName)) {
                qCInfo(chiakiGui) << "SteamCloudSync: Registering new profile in settings:" << profileName;
                m_settings->AddProfile(profileName);
                qCInfo(chiakiGui) << "SteamCloudSync: Profile" << profileName << "is now available in the UI";
            } else {
                qCInfo(chiakiGui) << "SteamCloudSync: Profile" << profileName << "already registered";
            }
        }
    }
    
    return true;
#else
    Q_UNUSED(cloudFilename)
    return false;
#endif
}

int SteamCloudSync::compareTimestamps(const QString &localPath, const QString &cloudFilename) const
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        return -999;
    }

    QFileInfo localInfo(localPath);
    if (!localInfo.exists()) {
        return -999;
    }

    if (!remoteStorage->FileExists(cloudFilename.toUtf8().constData())) {
        return -999;
    }

    // Get local modification time
    QDateTime localTime = localInfo.lastModified();
    
    // Get cloud file timestamp
    int64 cloudTimestamp = remoteStorage->GetFileTimestamp(cloudFilename.toUtf8().constData());
    QDateTime cloudTime = QDateTime::fromSecsSinceEpoch(cloudTimestamp);

    // Get file sizes for logging
    qint64 localSize = localInfo.size();
    int32 cloudSize = remoteStorage->GetFileSize(cloudFilename.toUtf8().constData());

    // Compare with 1-second tolerance to account for filesystem precision
    qint64 diff = localTime.secsTo(cloudTime);
    
    qCInfo(chiakiGui) << "SteamCloudSync: Comparing" << cloudFilename;
    qCInfo(chiakiGui) << "  Local:  Modified:" << localTime.toString("yyyy-MM-dd HH:mm:ss") 
            << "- Size:" << localSize << "bytes";
    qCInfo(chiakiGui) << "  Cloud:  Modified:" << cloudTime.toString("yyyy-MM-dd HH:mm:ss") 
            << "- Size:" << cloudSize << "bytes";
    qCInfo(chiakiGui) << "  Time difference:" << diff << "seconds";
    
    if (diff < -1) {
        qCInfo(chiakiGui) << "  Result: Local is NEWER (will upload)";
        return -1; // Local is newer
    } else if (diff > 1) {
        qCInfo(chiakiGui) << "  Result: Cloud is NEWER (will download)";
        return 1; // Cloud is newer
    } else {
        qCInfo(chiakiGui) << "  Result: Times are EQUAL (will skip)";
        return 0; // Equal (within tolerance)
    }
#else
    Q_UNUSED(localPath)
    Q_UNUSED(cloudFilename)
    return -999;
#endif
}

