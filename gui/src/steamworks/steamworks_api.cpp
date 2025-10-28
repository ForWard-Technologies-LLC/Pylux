// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "steamworks/steamworks_wrapper.h"

#ifdef CHIAKI_ENABLE_STEAMWORKS
    // Include Steamworks SDK headers
    #include "steam/steam_api.h"
#endif

#include <QDebug>
#include <QFile>

SteamworksWrapper::SteamworksWrapper(QObject *parent)
    : QObject(parent)
    , m_initialized(false)
    , m_steamAvailable(false)
    , m_appId(3946320)
{
}

SteamworksWrapper::~SteamworksWrapper()
{
    shutdown();
}

bool SteamworksWrapper::initialize(uint32_t appId)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    m_appId = appId;
    
    if (appId == 0) {
        qWarning() << "SteamworksWrapper: Invalid App ID provided";
        return false;
    }
    
    // Check if Steam client is running
    if (!SteamAPI_IsSteamRunning()) {
        qWarning() << "SteamworksWrapper: Steam client is not running";
        return false;
    }
    
    // Initialize Steam API
    if (!SteamAPI_Init()) {
        qWarning() << "SteamworksWrapper: Failed to initialize Steam API";
        return false;
    }
    
    m_initialized = true;
    m_steamAvailable = true;
    
    qInfo() << "SteamworksWrapper: Successfully initialized with App ID" << appId;
    return true;
    
#else
    Q_UNUSED(appId)
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return false;
#endif
}

bool SteamworksWrapper::isSteamAvailable() const
{
    return m_steamAvailable;
}

bool SteamworksWrapper::activateGameOverlayToWebPage(const QString &url)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_steamAvailable) {
        qWarning() << "SteamworksWrapper: Steam API not initialized or available";
        return false;
    }
    
    if (url.isEmpty()) {
        qWarning() << "SteamworksWrapper: Empty URL provided";
        return false;
    }
    
    // Get Steam Friends interface for overlay functionality
    ISteamFriends *steamFriends = SteamFriends();
    if (!steamFriends) {
        qWarning() << "SteamworksWrapper: Failed to get Steam Friends interface";
        return false;
    }
    
    // Activate overlay to web page
    qInfo() << "SteamworksWrapper: Activating Steam overlay to URL:" << url;
    steamFriends->ActivateGameOverlayToWebPage(url.toUtf8().constData());
    
    return true;
    
#else
    Q_UNUSED(url)
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return false;
#endif
}

void SteamworksWrapper::shutdown()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (m_initialized) {
        SteamAPI_Shutdown();
        m_initialized = false;
        m_steamAvailable = false;
        qInfo() << "SteamworksWrapper: Steam API shutdown";
    }
#endif
}

SteamworksWrapper::OwnershipResult SteamworksWrapper::checkOwnership()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_steamAvailable) {
        qWarning() << "SteamworksWrapper: Cannot check ownership - Steam API not initialized";
        return NotRunning;
    }

    ISteamUser *steamUser = SteamUser();
    if (!steamUser) {
        qWarning() << "SteamworksWrapper: Failed to get Steam User interface";
        return NotRunning;
    }

    CSteamID steamID = steamUser->GetSteamID();
    EUserHasLicenseForAppResult result = steamUser->UserHasLicenseForApp(steamID, m_appId);
    
    runCallbacks();
    
    switch (result) {
        case k_EUserHasLicenseResultHasLicense:
            qInfo() << "SteamworksWrapper: License verified successfully";
            return HasLicense;
        case k_EUserHasLicenseResultDoesNotHaveLicense:
            qWarning() << "SteamworksWrapper: User does not have license for App ID" << m_appId;
            return NoLicense;
        case k_EUserHasLicenseResultNoAuth:
            qInfo() << "SteamworksWrapper: User not yet authenticated for App ID" << m_appId;
            return NotRunning;
        default:
            qWarning() << "SteamworksWrapper: Unknown license check result:" << result;
            return NotRunning;
    }
#else
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return NotRunning;
#endif
}

bool SteamworksWrapper::syncConfigToCloud(const QString &filepath)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_steamAvailable) {
        qWarning() << "SteamworksWrapper: Cannot sync to cloud - Steam API not initialized";
        return false;
    }

    QFile file(filepath);
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning() << "SteamworksWrapper: Failed to open config file for reading:" << filepath;
        return false;
    }

    QByteArray fileData = file.readAll();
    file.close();

    if (fileData.isEmpty()) {
        qWarning() << "SteamworksWrapper: Config file is empty, skipping cloud sync";
        return false;
    }

    qInfo() << "SteamworksWrapper: Saving config to Steam Cloud..." << fileData.size() << "bytes";

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qWarning() << "SteamworksWrapper: Failed to get Steam Remote Storage interface";
        return false;
    }

    // Use filename without path for Steam Cloud
    QString cloudFilename = "PSStream.conf";
    bool success = remoteStorage->FileWrite(cloudFilename.toUtf8().constData(), 
                                            fileData.constData(), 
                                            fileData.size());
    
    runCallbacks();

    if (success) {
        qInfo() << "SteamworksWrapper: Config saved to cloud (" << fileData.size() << "bytes)";
    } else {
        qWarning() << "SteamworksWrapper: Failed to write config to Steam Cloud";
    }

    return success;
#else
    Q_UNUSED(filepath)
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return false;
#endif
}

bool SteamworksWrapper::loadConfigFromCloud(const QString &filepath)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_steamAvailable) {
        qWarning() << "SteamworksWrapper: Cannot load from cloud - Steam API not initialized";
        return false;
    }

    ISteamRemoteStorage *remoteStorage = SteamRemoteStorage();
    if (!remoteStorage) {
        qWarning() << "SteamworksWrapper: Failed to get Steam Remote Storage interface";
        return false;
    }

    QString cloudFilename = "PSStream.conf";
    
    // Check if file exists in cloud
    if (!remoteStorage->FileExists(cloudFilename.toUtf8().constData())) {
        qInfo() << "SteamworksWrapper: No config file found in Steam Cloud, skipping load";
        return false;
    }

    int32 fileSize = remoteStorage->GetFileSize(cloudFilename.toUtf8().constData());
    if (fileSize <= 0) {
        qWarning() << "SteamworksWrapper: Config file in cloud has invalid size:" << fileSize;
        return false;
    }

    qInfo() << "SteamworksWrapper: Loading config from Steam Cloud..." << fileSize << "bytes";

    QByteArray buffer(fileSize, 0);
    int32 bytesRead = remoteStorage->FileRead(cloudFilename.toUtf8().constData(), 
                                              buffer.data(), 
                                              fileSize);
    
    runCallbacks();

    if (bytesRead != fileSize) {
        qWarning() << "SteamworksWrapper: Failed to read complete config from cloud. Expected" 
                   << fileSize << "bytes, got" << bytesRead;
        return false;
    }

    // Write to local file
    QFile file(filepath);
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "SteamworksWrapper: Failed to open config file for writing:" << filepath;
        return false;
    }

    qint64 bytesWritten = file.write(buffer);
    file.close();

    if (bytesWritten != fileSize) {
        qWarning() << "SteamworksWrapper: Failed to write complete config to disk";
        return false;
    }

    qInfo() << "SteamworksWrapper: Config loaded from cloud (" << bytesRead << "bytes)";
    return true;
#else
    Q_UNUSED(filepath)
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return false;
#endif
}

bool SteamworksWrapper::setRichPresence(const QString &status, const QString &gameName)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (!m_initialized || !m_steamAvailable) {
        qWarning() << "SteamworksWrapper: Cannot set rich presence - Steam API not initialized";
        return false;
    }

    ISteamFriends *steamFriends = SteamFriends();
    if (!steamFriends) {
        qWarning() << "SteamworksWrapper: Failed to get Steam Friends interface";
        return false;
    }

    qInfo() << "SteamworksWrapper: Setting rich presence:" << status;

    // Set the status text
    bool success = steamFriends->SetRichPresence("status", status.toUtf8().constData());
    
    // Set game name if provided
    if (!gameName.isEmpty()) {
        steamFriends->SetRichPresence("game", gameName.toUtf8().constData());
    }
    
    runCallbacks();

    if (!success) {
        qWarning() << "SteamworksWrapper: Failed to set rich presence";
    }

    return success;
#else
    Q_UNUSED(status)
    Q_UNUSED(gameName)
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return false;
#endif
}

void SteamworksWrapper::runCallbacks()
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    if (m_initialized && m_steamAvailable) {
        SteamAPI_RunCallbacks();
    }
#endif
}




