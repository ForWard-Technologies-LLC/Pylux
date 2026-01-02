# Steamworks SDK Setup

This directory contains the Steamworks SDK integration for chiaki-ng.

## Installation

1. Download the Steamworks SDK from the Steamworks Partner site
2. Extract the SDK and place the contents in `steamworks_sdk/` directory inside this folder

The directory structure should look like:
```
third-party/steamworks/
├── CMakeLists.txt
├── README_STEAMWORKS.md
└── steamworks_sdk/
    ├── public/
    │   └── steam/
    │       └── steam_api.h
    └── redistributable_bin/
        ├── linux64/
        │   └── libsteam_api.so
        ├── osx/
        │   └── libsteam_api.dylib
        └── win64/
            ├── steam_api64.dll
            └── steam_api64.lib
```

## Usage

The Steamworks integration is controlled by the `CHIAKI_ENABLE_STEAMWORKS` CMake option:

```bash
cmake -DCHIAKI_ENABLE_STEAMWORKS=ON ...
```

When enabled, this creates a `steamworks` CMake target that can be linked like any other library.

## Enhanced Rich Presence

The Steamworks integration uses Enhanced Rich Presence for displaying status information in Steam friends lists.

### Localization File

A rich presence localization file template is provided at:
```
third-party/steamworks/rich_presence_localization.vdf
```

**Important**: This file must be uploaded to the Steamworks Partner portal for rich presence to work properly.

1. Log in to your Steamworks Partner account
2. Navigate to your app's configuration
3. Go to **Features** → **Enhanced Rich Presence**
4. Upload the localization file or configure the tokens in the web interface

The localization file defines tokens that control how rich presence is displayed:
- `#StatusCloudGame` - Used when playing a specific game (displays "Playing: %GAME%")
- `#StatusRemotePlayGame` - Used when in remote play mode without a specific game (displays "Remote Play")

For more information, see:
- [Enhanced Rich Presence Documentation](https://partner.steamgames.com/doc/features/enhancedrichpresence)
- [Rich Presence Localization](https://partner.steamgames.com/doc/api/ISteamFriends#richpresencelocalization)


