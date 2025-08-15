// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "steamworks/steamworks_wrapper.h"

#ifdef CHIAKI_ENABLE_STEAMWORKS
    // Include Steamworks SDK headers
    #include "steam/steam_api.h"
#endif

#include <QDebug>

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
    
    // TODO: Replace with your actual Steam App ID
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




