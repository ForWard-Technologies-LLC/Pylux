// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "steamworks/steamworks_wrapper.h"
#include "steamworks/steamworks_cloud_sync.h"
#include "qmlmainwindow.h"

#ifdef CHIAKI_ENABLE_STEAMWORKS
    // Include Steamworks SDK headers
    #include "steam/steam_api.h"
#endif

#include <QDebug>
#include <QLoggingCategory>

SteamworksWrapper::SteamworksWrapper(QObject *parent)
    : QObject(parent)
    , m_initialized(false)
    , m_steamAvailable(false)
    , m_appId(3946320)
    , m_cloudSync(nullptr)
{
}

SteamworksWrapper::~SteamworksWrapper()
{
    shutdown();
}

bool SteamworksWrapper::initialize(uint32_t appId, Settings *settings)
{
#ifdef CHIAKI_ENABLE_STEAMWORKS
    m_appId = appId;
    
    if (appId == 0) {
        qCWarning(chiakiGui) << "SteamworksWrapper: Invalid App ID provided";
        return false;
    }
    
    // Check if Steam client is running
    if (!SteamAPI_IsSteamRunning()) {
        qCWarning(chiakiGui) << "SteamworksWrapper: Steam client is not running";
        return false;
    }
    
    // Initialize Steam API
    if (!SteamAPI_Init()) {
        qCWarning(chiakiGui) << "SteamworksWrapper: Failed to initialize Steam API";
        return false;
    }
    
    m_initialized = true;
    m_steamAvailable = true;
    
    // Initialize cloud sync
    qCInfo(chiakiGui) << "SteamworksWrapper: Creating cloud sync instance...";
    m_cloudSync = new SteamCloudSync(settings, this);
    if (m_cloudSync->initialize()) {
        qCInfo(chiakiGui) << "SteamworksWrapper: Cloud sync initialized successfully";
    } else {
        qCWarning(chiakiGui) << "SteamworksWrapper: Cloud sync initialization failed, but continuing";
    }
    
    qCInfo(chiakiGui) << "SteamworksWrapper: Successfully initialized with App ID" << appId;
    return true;
    
#else
    Q_UNUSED(appId)
    Q_UNUSED(settings)
    qCWarning(chiakiGui) << "SteamworksWrapper: Steamworks support not compiled in";
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
        // Clean up cloud sync
        if (m_cloudSync) {
            delete m_cloudSync;
            m_cloudSync = nullptr;
        }
        
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

    ISteamApps *steamApps = SteamApps();
    if (!steamApps) {
        qWarning() << "SteamworksWrapper: Failed to get SteamApps interface";
        return NotRunning;
    }
    
    bool isSubscribed = steamApps->BIsSubscribedApp(m_appId);
    
    runCallbacks();
    
    if (isSubscribed) {
        qInfo() << "SteamworksWrapper: License verified - User owns App ID" << m_appId;
        return HasLicense;
    } else {
        qWarning() << "SteamworksWrapper: User does not own App ID" << m_appId;
        return NoLicense;
    }
#else
    qWarning() << "SteamworksWrapper: Steamworks support not compiled in";
    return NotRunning;
#endif
}

bool SteamworksWrapper::setRichPresence(const QString &gameName)
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

    // Enhanced Rich Presence: Set data keys first
    bool success = true;
    
    if (!gameName.isEmpty()) {
        // Set the game name (uppercase GAME as per Steam convention)
        qInfo() << "SteamworksWrapper: Setting rich presence - Playing game:" << gameName;
        success = steamFriends->SetRichPresence("GAME", gameName.toUtf8().constData());
        qInfo() << "SteamworksWrapper: SetRichPresence(GAME," << gameName << ") ->" << (success ? "success" : "failed");
        
        // Set display token for when a game is being played
        bool displaySuccess = steamFriends->SetRichPresence("steam_display", "#StatusCloudGame");
        qInfo() << "SteamworksWrapper: SetRichPresence(steam_display, #StatusCloudGame) ->" << (displaySuccess ? "success" : "failed");
        success = success && displaySuccess;
    } else {
        // Clear game name if empty
        bool clearSuccess = steamFriends->SetRichPresence("GAME", nullptr);
        qInfo() << "SteamworksWrapper: SetRichPresence(GAME, nullptr) ->" << (clearSuccess ? "success" : "failed");
        
        // Set display token for remote play without specific game
        qInfo() << "SteamworksWrapper: Setting rich presence - Remote Play";
        success = steamFriends->SetRichPresence("steam_display", "#StatusRemotePlayGame");
        qInfo() << "SteamworksWrapper: SetRichPresence(steam_display, #StatusRemotePlayGame) ->" << (success ? "success" : "failed");
        success = success && clearSuccess;
    }
    
    runCallbacks();

    if (!success) {
        qWarning() << "SteamworksWrapper: Failed to set rich presence";
    }

    return success;
#else
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
        
        // Handle dynamic cloud sync updates
        if (m_cloudSync) {
            m_cloudSync->handleDynamicCloudChange();
        }
    }
#endif
}




