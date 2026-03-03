# iOS Support for Chiaki (Pylux)

This folder contains the iOS build for the Chiaki library and a minimal iOS app.

## Mac vs iOS Build: What's Reused

The **Mac build** (see `.github/workflows-disabled/build-macos.yml`) and **iOS build** share some concepts but differ in key ways:

| Aspect | Mac Build | iOS Build |
|--------|-----------|-----------|
| **Toolchain** | Native (no special toolchain) | ios-cmake (`PLATFORM=OS64` or `SIMULATORARM64`) |
| **SDK** | `xcrun --sdk macosx` | `xcrun --sdk iphoneos` or `iphonesimulator` |
| **Dependencies** | Homebrew (openssl, json-c, miniupnpc, opus, etc.) | FetchContent (same as Android) |
| **Crypto** | OpenSSL (system) | mbedTLS (bundled) |
| **Output** | Qt GUI app | Lib only + minimal SwiftUI app |

**Reused from Mac/Apple:**
- `lib/CMakeLists.txt`: `-framework CoreServices` for APPLE; `-framework Security`, `-framework Foundation` for IOS
- `CMAKE_OSX_SYSROOT` and `xcrun` pattern (curl, third-party already use this)
- Same root CMakeLists.txt structure; IOS uses `CHIAKI_ENABLE_IOS` to build lib-only

**Same as Android:**
- FetchContent for json-c, miniupnpc, opus
- mbedTLS for crypto (curl + chiaki)
- FFmpeg OFF, RUDP ON

## Prerequisites

- macOS with Xcode (or Xcode Command Line Tools)
- CMake 3.10+
- Python 3 (for nanopb)
- protoc (protobuf compiler)

**Python protobuf:** The nanopb generator requires the `protobuf` Python package. With Homebrew Python (PEP 668), install with:
```bash
pip3 install --user --break-system-packages protobuf
```

## Build Script (like Android)

One script with dev/release modes:

```bash
# Dev (default): build lib + app, install and run on booted simulator
./build.sh dev
# or
./build.sh

# Release: build lib + app, create archive for App Store / TestFlight upload
./build.sh release

# Release + XCFramework
./build.sh release xcframework
```

**Dev mode:** If no simulator is booted, shows a warning and the manual command to install/launch.

**Release mode:** Creates `build-derived/Pylux.xcarchive`. Requires code signing: in Xcode, open Pylux.xcodeproj > Signing & Capabilities > select your Development Team. Then open Organizer to distribute to App Store or TestFlight.

## Output Locations

| Build | Location |
|-------|----------|
| chiaki-lib (device) | `build-iphoneos/parent/lib/libchiaki.a` |
| chiaki-lib (simulator) | `build-iphonesimulator/parent/lib/libchiaki.a` |
| Combined libs | `build-iphoneos/libchiaki_complete.a`, `build-iphonesimulator/libchiaki_complete.a` |
| Release archive | `build-derived/Pylux.xcarchive` |

The app links to chiaki-lib via `libchiaki_complete.a` and displays "Chiaki says: Success" from `chiaki_error_string(CHIAKI_ERR_SUCCESS)`.
