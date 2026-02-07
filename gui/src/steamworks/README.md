# Steamworks Integration Module

This module provides isolated Steamworks SDK integration for pylux.

## Purpose
- Provides Steam overlay integration for PSN OAuth workflow
- Isolated from main codebase to minimize merge conflicts
- Optional feature controlled by build flags

## Dependencies
- Steamworks SDK (place in `gui/third_party/steamworks_sdk/`)
- Your Steam App ID (configured in steamworks_api.cpp)

## Build Configuration
- Controlled by `CHIAKI_ENABLE_STEAMWORKS` CMake option
- Only links Steamworks when explicitly enabled
- Gracefully degrades when Steam is not available

## Usage
- Activates Steam overlay to display PlayStation OAuth page
- Fallback to system browser when Steam overlay unavailable



