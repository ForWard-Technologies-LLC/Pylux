#!/bin/bash
# iOS build script for Pylux (Chiaki)
# Similar to android/build.ps1: dev = simulator + run, release = production archive
#
# Usage:
#   ./build.sh [dev|release]     - dev (default): build and run on device/simulator
#                                  release: build archive for App Store upload
#   ./build.sh launch            - Skip build, launch app and stream logs only
#   ./build.sh iterate           - Fast loop: optional full lib, xcodebuild, install, launch,
#                                  background syslog (auto-stops after PYLUX_LOG_MINUTES, default 20)
#   PYLUX_FULL_BUILD=1 ./build.sh iterate  - Rebuild chiaki-lib via CMake first
#   PYLUX_XCODE_QUIET=1        - Optional: pass xcodebuild -quiet (default: full build log to terminal)
#   PYLUX_XCODE_CONFIGURATION=Release ./build.sh dev|iterate  - Release build (matches shipped log masks); default Debug
#   PYLUX_DEV_NO_STREAM=1      - After install/launch, skip foreground log streaming (script exits; default dev waits on logs)
#   PYLUX_SYSLOG_NETWORK=1     - idevicesyslog always uses -n (override auto USB vs Wi‑Fi)
#   ./build.sh stop-logs         - Stop capture (reads logs/pylux-capture.pid if present)
#   ./build.sh release xcframework - Also create XCFramework after release build
#   ./build.sh ship - Archive + export IPA + Fastlane upload (TestFlight). Uses generic/platform=iOS only;
#       does not install on a device or stream logs. Requires: brew install fastlane + API key env (see below).
#       export APP_STORE_CONNECT_API_KEY_KEY_ID=...
#       export APP_STORE_CONNECT_API_KEY_ISSUER_ID=...
#       export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH=/path/to/AuthKey_XXXX.p8
#
# Prerequisites: Xcode, Homebrew (cmake, ninja, protobuf, python)
# For release/ship: Set DEVELOPMENT_TEAM in Xcode for code signing

set -e

MODE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_URL="https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake"
TOOLCHAIN_FILE="$SCRIPT_DIR/ios.toolchain.cmake"
SCHEME="Pylux"
BUNDLE_ID="com.pylux.stream"
PYLUX_XCODE_CONFIGURATION="${PYLUX_XCODE_CONFIGURATION:-Debug}"

# xcodebuild prints full compile output by default. Set PYLUX_XCODE_QUIET=1 to reduce noise.
if [ "${PYLUX_XCODE_QUIET:-0}" = "1" ]; then
    _PYLUX_XCODE_EXTRA=(-quiet)
else
    _PYLUX_XCODE_EXTRA=()
fi

# idevicesyslog needs usbmux/network UDID (not devicectl Core Device UUID). Prefer USB list, then Wi‑Fi list, then caller fallback.
_pylux_resolve_syslog_udid() {
    local fallback="${1:-}"
    local u
    u=$(idevice_id -l 2>/dev/null | head -1)
    [ -n "$u" ] && { echo "$u"; return; }
    u=$(idevice_id -ln 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$u" ] && { echo "$u"; return; }
    [ -n "$fallback" ] && echo "$fallback"
}

# USB by default; use -n when device is only on idevice_id -ln, or when PYLUX_SYSLOG_NETWORK=1.
_pylux_idevicesyslog_use_network_flag() {
    local udid="$1"
    [ -z "$udid" ] && return 1
    [ "${PYLUX_SYSLOG_NETWORK:-0}" = "1" ] && return 0
    idevice_id -l 2>/dev/null | grep -qxF "$udid" && return 1
    idevice_id -ln 2>/dev/null | grep -qF "$udid" && return 0
    return 1
}

# idevicesyslog -p Pylux (PATH includes Homebrew before any run_*). Fallback: pymobiledevice3.
_pylux_stream_phys_device_syslog() {
    local udid="$1"
    local log_file="$2"
    local isys
    isys=$(command -v idevicesyslog 2>/dev/null || true)
    if [ -n "$isys" ]; then
        if _pylux_idevicesyslog_use_network_flag "$udid"; then
            echo "device syslog: $isys -n -u $udid -p Pylux" >&2
            exec "$isys" -n -u "$udid" -p Pylux 2>&1 | tee "$log_file"
        else
            echo "device syslog: $isys -u $udid -p Pylux" >&2
            exec "$isys" -u "$udid" -p Pylux 2>&1 | tee "$log_file"
        fi
    elif python3 -c "import pymobiledevice3" 2>/dev/null; then
        echo "WARN: no idevicesyslog (brew install libimobiledevice); using pymobiledevice3" >&2
        local extra=()
        [ -n "$udid" ] && extra+=(--udid "$udid")
        exec env PYTHONUNBUFFERED=1 python3 -u -m pymobiledevice3 syslog live "${extra[@]}" 2>&1 | tee "$log_file"
    else
        echo "ERROR: install libimobiledevice (idevicesyslog) or pymobiledevice3 for device logs." >&2
        exit 1
    fi
}

_pylux_start_phys_device_syslog_bg() {
    local udid="$1"
    local log_file="$2"
    local isys
    isys=$(command -v idevicesyslog 2>/dev/null || true)
    if [ -n "$isys" ]; then
        if _pylux_idevicesyslog_use_network_flag "$udid"; then
            echo "device syslog (bg): $isys -n -u $udid -p Pylux" >&2
            "$isys" -n -u "$udid" -p Pylux >> "$log_file" 2>&1 &
        else
            echo "device syslog (bg): $isys -u $udid -p Pylux" >&2
            "$isys" -u "$udid" -p Pylux >> "$log_file" 2>&1 &
        fi
        PYLUX_SYSLOG_BG_PID=$!
    elif python3 -c "import pymobiledevice3" 2>/dev/null; then
        echo "WARN: no idevicesyslog; using pymobiledevice3" >&2
        local extra=()
        [ -n "$udid" ] && extra+=(--udid "$udid")
        env PYTHONUNBUFFERED=1 python3 -u -m pymobiledevice3 syslog live "${extra[@]}" >> "$log_file" 2>&1 &
        PYLUX_SYSLOG_BG_PID=$!
    else
        echo "ERROR: install libimobiledevice or pymobiledevice3 for device logs." >&2
        exit 1
    fi
}

# Setup: Homebrew deps (match macOS build)
if ! command -v brew &>/dev/null; then
    echo "Homebrew not found. Install from https://brew.sh"
    exit 1
fi
export PATH="$(brew --prefix)/bin:$(brew --prefix)/opt/protobuf@29/bin:$(brew --prefix)/opt/protobuf/bin:$(brew --prefix)/opt/python@3.12/bin:$(brew --prefix)/opt/python@3.11/bin:$(brew --prefix)/opt/python@3.10/bin:$PATH"

if ! command -v cmake &>/dev/null; then
    echo "Installing build dependencies via Homebrew..."
    brew update
    brew install cmake ninja protobuf@29 python3
fi

# nanopb generator needs Python protobuf (Homebrew Python: --break-system-packages)
if ! python3 -c "import google.protobuf" 2>/dev/null; then
    echo "Installing Python protobuf for nanopb generator..."
    pip3 install --user --break-system-packages protobuf 2>/dev/null || pip3 install protobuf
fi

if [ ! -f "$TOOLCHAIN_FILE" ]; then
    echo "Downloading ios.toolchain.cmake..."
    curl -sL -o "$TOOLCHAIN_FILE" "$TOOLCHAIN_URL"
fi

if [ "$(uname -m)" = "arm64" ]; then
    SIMULATOR_PLATFORM="SIMULATORARM64"
else
    SIMULATOR_PLATFORM="SIMULATOR64"
fi

CMAKE_EXTRA="-DCMAKE_POLICY_VERSION_MINIMUM=3.5"

# CMakeCache can pin an old iPhoneOS*.sdk path; after Xcode upgrades that folder is gone and
# ZLIB/curl fail with "non-existent path". Remove the tree so the next cmake run is clean.
drop_stale_ios_cmake_build() {
    local dir="$1"
    local cache="$dir/CMakeCache.txt"
    [ -f "$cache" ] || return 0
    local line sysroot
    line=$(grep '^CMAKE_OSX_SYSROOT:INTERNAL=' "$cache" 2>/dev/null | head -1) || return 0
    sysroot="${line#CMAKE_OSX_SYSROOT:INTERNAL=}"
    [ -n "$sysroot" ] || return 0
    if [ ! -d "$sysroot" ]; then
        echo "=== Removing stale $dir (cached SDK missing: $sysroot) ==="
        rm -rf "$dir"
    fi
}

# --- Build chiaki-lib (device + simulator) ---
build_lib() {
    drop_stale_ios_cmake_build "$SCRIPT_DIR/build-iphoneos"
    drop_stale_ios_cmake_build "$SCRIPT_DIR/build-iphonesimulator"

    echo "=== Building chiaki-lib for iOS device ==="
    cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/build-iphoneos" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DPLATFORM=OS64 \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_LIBIDN2=OFF \
        -DCURL_USE_LIBPSL=OFF \
        $CMAKE_EXTRA
    cmake --build "$SCRIPT_DIR/build-iphoneos" --config Release --target chiaki-lib

    echo ""
    echo "=== Building chiaki-lib for iOS simulator ($SIMULATOR_PLATFORM) ==="
    cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/build-iphonesimulator" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DPLATFORM="$SIMULATOR_PLATFORM" \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_LIBIDN2=OFF \
        -DCURL_USE_LIBPSL=OFF \
        $CMAKE_EXTRA
    cmake --build "$SCRIPT_DIR/build-iphonesimulator" --config Release --target chiaki-lib

    echo ""
    echo "=== Creating combined libraries ==="
    create_combined_lib "$SCRIPT_DIR/build-iphoneos" "$SCRIPT_DIR/build-iphoneos/libchiaki_complete.a"
    create_combined_lib "$SCRIPT_DIR/build-iphonesimulator" "$SCRIPT_DIR/build-iphonesimulator/libchiaki_complete.a"
}

# Create libchiaki_complete.a by combining all static libs. Fails if libtool fails.
# Search full build_dir (parent + _deps) so mbedtls, opus, etc. are included.
create_combined_lib() {
    local build_dir="$1" output_path="$2"
    if ! find "$build_dir" -name "*.a" -print0 2>/dev/null | xargs -0 libtool -static -o "$output_path" 2>/dev/null; then
        echo "ERROR: libtool failed to create combined library. Check that the CMake build completed successfully."
        exit 1
    fi
}

# xcodebuild -showdestinations lists "Any iOS Device" (id dvtdevice-DVTiPhonePlaceholder-iphoneos) as platform:iOS.
# That is not a real phone — building to it hangs / empty supported platforms.
_filter_real_ios_device_destinations() {
    grep -vE 'DVTiPhonePlaceholder|DVTiPadPlaceholder' || true
}

# --- Dev: build app for device (if connected) or simulator (fallback) ---
run_dev() {
    build_lib

    # Check for connected physical devices
    echo ""
    echo "=== Checking for connected devices ==="
    DEVICE_UDID=""
    DEVICE_NAME=""
    
    # Use xcodebuild for build destination (it needs legacy UDID e.g. 00008101-...)
    # devicectl uses CoreDevice ID (e.g. E0A55DB7-...) - only for install/launch
    DESTINATIONS=$(xcodebuild -project "$SCRIPT_DIR/Pylux.xcodeproj" -scheme "$SCHEME" -showdestinations 2>/dev/null | grep "platform:iOS," | grep -v "Simulator" | grep "name:" | _filter_real_ios_device_destinations)
    if [ -n "$DESTINATIONS" ]; then
        DEVICE_LINE=$(echo "$DESTINATIONS" | head -1)
        DEVICE_UDID=$(echo "$DEVICE_LINE" | grep -oE 'id:[^,}]+' | head -1 | cut -d: -f2)
        DEVICE_NAME=$(echo "$DEVICE_LINE" | grep -oE 'name:[^,}]+' | head -1 | cut -d: -f2- | sed 's/^ *//')
        # For devicectl install/launch we need CoreDevice ID; get from devicectl if xcodebuild UDID fails later
        DEVICECTL_INFO=$(xcrun devicectl list devices 2>/dev/null | grep -E "iPhone|iPad" | grep -v "unavailable" | grep -v "disconnected" | head -1)
        DEVICECTL_UDID=$(echo "$DEVICECTL_INFO" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
    fi

    if [ -n "$DEVICE_UDID" ]; then
        echo "Found physical device: $DEVICE_NAME ($DEVICE_UDID)"
        echo ""
        echo "=== Forcing Xcode to use fresh libraries ==="
        # Touch the library files to force Xcode to relink
        touch "$SCRIPT_DIR/build-iphoneos/libchiaki_complete.a"
        touch "$SCRIPT_DIR/build-iphonesimulator/libchiaki_complete.a"
        # Clean build folder to force relink
        rm -rf "$SCRIPT_DIR/build-derived/Build/Intermediates.noindex"
        echo ""
        echo "=== Building Pylux app for physical device ==="
        # Note: Code signing required for physical devices. Make sure you have a valid
        # provisioning profile or enable "Automatically manage signing" in Xcode.
        (cd "$SCRIPT_DIR" && xcodebuild -project Pylux.xcodeproj -scheme "$SCHEME" -sdk iphoneos -configuration "$PYLUX_XCODE_CONFIGURATION" clean build \
            -destination "id=$DEVICE_UDID" \
            -derivedDataPath "$SCRIPT_DIR/build-derived" \
            -allowProvisioningUpdates \
            "${_PYLUX_XCODE_EXTRA[@]}")

        APP_PATH="$SCRIPT_DIR/build-derived/Build/Products/${PYLUX_XCODE_CONFIGURATION}-iphoneos/Pylux.app"
        if [ ! -d "$APP_PATH" ]; then
            echo "ERROR: App not found at $APP_PATH"
            exit 1
        fi

        echo ""
        echo "=== Installing app on device ==="
        INSTALL_UDID="${DEVICECTL_UDID:-$DEVICE_UDID}"
        xcrun devicectl device install app --device "$INSTALL_UDID" "$APP_PATH"
        
        # Kill existing instance to ensure fresh start
        xcrun devicectl device process kill --device "$INSTALL_UDID" "$BUNDLE_ID" 2>/dev/null || true
        sleep 1
        
        xcrun devicectl device process launch --device "$INSTALL_UDID" "$BUNDLE_ID" || true
        
        echo ""
        echo "App launched on physical device: $DEVICE_NAME"
        echo ""
        
        # Create logs directory and file
        LOGS_DIR="$SCRIPT_DIR/logs"
        mkdir -p "$LOGS_DIR"
        LOG_FILE="$LOGS_DIR/pylux.log"
        
        if [ "${PYLUX_DEV_NO_STREAM:-0}" = "1" ]; then
            echo "PYLUX_DEV_NO_STREAM=1: skipping foreground log stream. Tail logs: ./build.sh launch or Console.app"
            exit 0
        fi
        echo "=== Streaming logs (press Ctrl+C to stop) ==="
        echo "Logs also being saved to: $LOG_FILE"
        sleep 1

        SYSLOG_UDID="$(_pylux_resolve_syslog_udid "$DEVICE_UDID")"
        _pylux_stream_phys_device_syslog "$SYSLOG_UDID" "$LOG_FILE"
    else
        echo "No physical device found, falling back to simulator"
        echo ""
        echo "=== Forcing Xcode to use fresh libraries ==="
        # Touch the library files to force Xcode to relink
        touch "$SCRIPT_DIR/build-iphoneos/libchiaki_complete.a"
        touch "$SCRIPT_DIR/build-iphonesimulator/libchiaki_complete.a"
        # Clean build folder to force relink
        rm -rf "$SCRIPT_DIR/build-derived/Build/Intermediates.noindex"
        echo ""
        echo "=== Building Pylux app for simulator ==="
        # Must match SIMULATOR_PLATFORM: arm64 on Apple Silicon, x86_64 on Intel
        if [ "$(uname -m)" = "arm64" ]; then
            XC_ARCHS="ARCHS=arm64"
        else
            XC_ARCHS="ARCHS=x86_64"
        fi
        (cd "$SCRIPT_DIR" && xcodebuild -project Pylux.xcodeproj -scheme "$SCHEME" -sdk iphonesimulator -configuration "$PYLUX_XCODE_CONFIGURATION" clean build \
            -destination 'generic/platform=iOS Simulator' \
            "$XC_ARCHS" \
            -derivedDataPath "$SCRIPT_DIR/build-derived" \
            "${_PYLUX_XCODE_EXTRA[@]}")

        APP_PATH="$SCRIPT_DIR/build-derived/Build/Products/${PYLUX_XCODE_CONFIGURATION}-iphonesimulator/Pylux.app"
        if [ ! -d "$APP_PATH" ]; then
            echo "ERROR: App not found at $APP_PATH"
            exit 1
        fi

        BOOTED=$(xcrun simctl list devices | grep "Booted" | head -1)
        if [ -z "$BOOTED" ]; then
            echo ""
            echo "WARNING: No simulator is booted. Start one from Xcode (Window > Devices and Simulators) or:"
            echo "  xcrun simctl boot 'iPhone 16'"
            echo ""
            echo "Then run: xcrun simctl install booted \"$APP_PATH\" && xcrun simctl launch booted $BUNDLE_ID"
            exit 0
        fi

        echo ""
        echo "=== Installing and launching on simulator ==="
        xcrun simctl install booted "$APP_PATH"
        xcrun simctl launch booted "$BUNDLE_ID"
        echo ""
        echo "App launched on simulator."
        echo ""
        if [ "${PYLUX_DEV_NO_STREAM:-0}" = "1" ]; then
            echo "PYLUX_DEV_NO_STREAM=1: skipping log stream. Stream: xcrun simctl spawn booted log stream --predicate 'subsystem == \"com.pylux.stream\"'"
            exit 0
        fi
        echo "=== Streaming logs (press Ctrl+C to stop) ==="
        LOGS_DIR="$SCRIPT_DIR/logs"
        mkdir -p "$LOGS_DIR"
        LOG_FILE="$LOGS_DIR/pylux.log"
        echo "Logs also being saved to: $LOG_FILE"
        sleep 2
        
        xcrun simctl spawn booted log stream \
            --predicate 'subsystem == "com.pylux.stream"' \
            --level info 2>&1 | tee "$LOG_FILE"
    fi
}

# --- Release: build app for device, create archive ---
ARCHIVE_PATH="$SCRIPT_DIR/build-derived/Pylux.xcarchive"

create_release_archive() {
    echo ""
    echo "=== Creating archive for release ==="
    (cd "$SCRIPT_DIR" && xcodebuild -project Pylux.xcodeproj -scheme "$SCHEME" -sdk iphoneos -configuration Release archive \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$SCRIPT_DIR/build-derived")

    if [ ! -d "$ARCHIVE_PATH" ]; then
        echo ""
        echo "Archive failed. For release builds, set DEVELOPMENT_TEAM in Xcode:"
        echo "  Open Pylux.xcodeproj > Signing & Capabilities > select your Team"
        exit 1
    fi
    echo ""
    echo "Release archive created:"
    echo "  $ARCHIVE_PATH"
}

run_release() {
    build_lib
    create_release_archive
    echo ""
    echo "To upload: Open Xcode > Window > Organizer, select the archive, then Distribute App."
    echo "  Or: ./build.sh ship (with App Store Connect API key env vars, see script header)"

    if [ "${2:-}" = "xcframework" ]; then
        echo ""
        echo "=== Creating XCFramework ==="
        create_xcframework
    fi
}

# --- Ship: archive + export IPA + upload to App Store Connect (TestFlight) ---
run_ship() {
    if ! command -v fastlane &>/dev/null; then
        echo "fastlane not found. Install: brew install fastlane"
        exit 1
    fi
    for var in APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID APP_STORE_CONNECT_API_KEY_KEY_FILEPATH; do
        if [ -z "${!var:-}" ]; then
            echo "Missing required environment variable: $var"
            echo "Create an API key: App Store Connect → Users and Access → Integrations → App Store Connect API"
            echo "Then export:"
            echo "  export APP_STORE_CONNECT_API_KEY_KEY_ID=XXXXXXXXXX"
            echo "  export APP_STORE_CONNECT_API_KEY_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
            echo "  export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH=\"\$HOME/Downloads/AuthKey_XXXXXXXXXX.p8\""
            exit 1
        fi
    done
    if [ ! -f "${APP_STORE_CONNECT_API_KEY_KEY_FILEPATH}" ]; then
        echo "API key file not found: ${APP_STORE_CONNECT_API_KEY_KEY_FILEPATH}"
        exit 1
    fi

    build_lib
    create_release_archive

    EXPORT_DIR="$SCRIPT_DIR/build-derived/export"
    rm -rf "$EXPORT_DIR"
    mkdir -p "$EXPORT_DIR"
    echo ""
    echo "=== Exporting IPA (app-store) ==="
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
        -allowProvisioningUpdates

    IPA=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.ipa" 2>/dev/null | head -1)
    if [ -z "$IPA" ] || [ ! -f "$IPA" ]; then
        echo "Export failed: no .ipa under $EXPORT_DIR"
        exit 1
    fi
    echo "IPA: $IPA"

    export PYLUX_IPA_PATH="$IPA"
    echo ""
    echo "=== Uploading to App Store Connect (TestFlight) ==="
    (cd "$SCRIPT_DIR" && fastlane upload_pylux_ipa)
    echo ""
    echo "Done. When processing finishes, the build appears in App Store Connect → TestFlight."
}

create_xcframework() {
    COMBINED_DEVICE="$SCRIPT_DIR/build-iphoneos/libchiaki_complete.a"
    COMBINED_SIM="$SCRIPT_DIR/build-iphonesimulator/libchiaki_complete.a"
    FRAMEWORK_DIR="$SCRIPT_DIR/Pylux.xcframework"
    rm -rf "$FRAMEWORK_DIR"
    mkdir -p "$FRAMEWORK_DIR/ios-arm64/chiaki.framework"
    mkdir -p "$FRAMEWORK_DIR/ios-arm64_x86_64-simulator/chiaki.framework"
    cp "$COMBINED_DEVICE" "$FRAMEWORK_DIR/ios-arm64/chiaki.framework/chiaki"
    cp "$COMBINED_SIM" "$FRAMEWORK_DIR/ios-arm64_x86_64-simulator/chiaki.framework/chiaki"
    cat > "$FRAMEWORK_DIR/ios-arm64/chiaki.framework/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>chiaki</string>
    <key>CFBundleIdentifier</key><string>org.chiaki.chiaki</string>
    <key>CFBundleName</key><string>chiaki</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
</dict>
</plist>
PLIST
    cp "$FRAMEWORK_DIR/ios-arm64/chiaki.framework/Info.plist" "$FRAMEWORK_DIR/ios-arm64_x86_64-simulator/chiaki.framework/"
    cat > "$FRAMEWORK_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key><string>ios-arm64</string>
            <key>LibraryPath</key><string>chiaki.framework</string>
            <key>SupportedArchitectures</key><array><string>arm64</string></array>
            <key>SupportedPlatform</key><string>ios</string>
        </dict>
        <dict>
            <key>LibraryIdentifier</key><string>ios-arm64_x86_64-simulator</string>
            <key>LibraryPath</key><string>chiaki.framework</string>
            <key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
            <key>SupportedPlatform</key><string>ios</string>
            <key>SupportedPlatformVariant</key><string>simulator</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key><string>XFWK</string>
    <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
    echo "  XCFramework: $FRAMEWORK_DIR"
}

run_launch() {
    echo "=== Launch mode: skipping build, launching app only ==="
    echo ""
    
    # Check for physical device using devicectl
    DEVICE_INFO=$(xcrun devicectl list devices 2>/dev/null | grep -E "iPhone|iPad" | grep -v "unavailable" | grep -v "disconnected" | head -1)
    
    if [ -n "$DEVICE_INFO" ]; then
        # Get device name and CoreDevice UDID
        DEVICE_NAME=$(echo "$DEVICE_INFO" | awk '{print $2}')
        DEVICE_UDID=$(echo "$DEVICE_INFO" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
        
        SYSLOG_UDID="$(_pylux_resolve_syslog_udid "$DEVICE_UDID")"

        echo "Found physical device: $DEVICE_NAME ($DEVICE_UDID)"
        echo ""
        echo "=== Killing existing app instance (if running) ==="
        xcrun devicectl device process kill --device "$DEVICE_UDID" com.pylux.stream 2>/dev/null || true
        sleep 1
        
        echo "=== Launching app on physical device ==="
        xcrun devicectl device process launch --device "$DEVICE_UDID" com.pylux.stream
        
        echo ""
        echo "App launched on physical device: $DEVICE_NAME"
        echo ""
        
        # Create logs directory and file
        LOGS_DIR="$SCRIPT_DIR/logs"
        mkdir -p "$LOGS_DIR"
        LOG_FILE="$LOGS_DIR/pylux.log"
        
        echo "=== Streaming logs (press Ctrl+C to stop) ==="
        echo "Logs also being saved to: $LOG_FILE"
        sleep 2

        _pylux_stream_phys_device_syslog "$SYSLOG_UDID" "$LOG_FILE"
    else
        echo "No physical device found, launching on simulator"
        echo ""
        
        # Get booted simulator
        SIMULATOR_UDID=$(xcrun simctl list devices | grep "(Booted)" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
        
        if [ -z "$SIMULATOR_UDID" ]; then
            echo "No simulator is running. Please boot a simulator first or connect a physical device."
            exit 1
        fi
        
        echo "Launching app on simulator: $SIMULATOR_UDID"
        xcrun simctl launch "$SIMULATOR_UDID" com.pylux.stream
        
        echo ""
        
        # Create logs directory and file
        LOGS_DIR="$SCRIPT_DIR/logs"
        mkdir -p "$LOGS_DIR"
        LOG_FILE="$LOGS_DIR/pylux.log"
        
        echo "=== Streaming logs (press Ctrl+C to stop) ==="
        echo "Logs also being saved to: $LOG_FILE"
        sleep 1
        
        # Simulator: use native predicate filter to capture all app logs
        exec xcrun simctl spawn "$SIMULATOR_UDID" log stream --predicate 'processImagePath CONTAINS "Pylux"' --level debug | tee "$LOG_FILE"
    fi
}

# --- Clean ---
clean_and_rebuild() {
    echo "=== Cleaning all build directories ==="
    
    if [ -d "$SCRIPT_DIR/build-iphoneos" ]; then
        echo "Removing build-iphoneos..."
        rm -rf "$SCRIPT_DIR/build-iphoneos"
    fi
    
    if [ -d "$SCRIPT_DIR/build-iphonesimulator" ]; then
        echo "Removing build-iphonesimulator..."
        rm -rf "$SCRIPT_DIR/build-iphonesimulator"
    fi
    
    # Clean Xcode DerivedData cache to force fresh build
    echo "Cleaning Xcode DerivedData cache..."
    rm -rf ~/Library/Developer/Xcode/DerivedData/*Pylux* 2>/dev/null || true
    
    # Also clean Xcode build products
    echo "Cleaning Xcode build products..."
    xcodebuild clean -project "$SCRIPT_DIR/Pylux.xcodeproj" -scheme "$SCHEME" -configuration "$PYLUX_XCODE_CONFIGURATION" 2>&1 | grep -E "^(Clean|note:|error:)" || true
    
    echo ""
    echo "=== Clean complete, starting rebuild ==="
    echo ""
    
    # Now run the dev build
    run_dev
}

# --- Resolve physical device IDs (xcodebuild vs devicectl) ---
resolve_physical_device() {
    DEVICE_UDID=""
    DEVICE_NAME=""
    DEVICECTL_UDID=""
    DESTINATIONS=$(xcodebuild -project "$SCRIPT_DIR/Pylux.xcodeproj" -scheme "$SCHEME" -showdestinations 2>/dev/null | grep "platform:iOS," | grep -v "Simulator" | grep "name:" | _filter_real_ios_device_destinations)
    if [ -n "$DESTINATIONS" ]; then
        DEVICE_LINE=$(echo "$DESTINATIONS" | head -1)
        DEVICE_UDID=$(echo "$DEVICE_LINE" | grep -oE 'id:[^,}]+' | head -1 | cut -d: -f2)
        DEVICE_NAME=$(echo "$DEVICE_LINE" | grep -oE 'name:[^,}]+' | head -1 | cut -d: -f2- | sed 's/^ *//')
        DEVICECTL_INFO=$(xcrun devicectl list devices 2>/dev/null | grep -E "iPhone|iPad" | grep -v "unavailable" | grep -v "disconnected" | head -1)
        DEVICECTL_UDID=$(echo "$DEVICECTL_INFO" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
    fi
}

# --- Iterate: fast rebuild + install + launch + background logs (terminal returns immediately) ---
run_iterate() {
    LOGS_DIR="$SCRIPT_DIR/logs"
    mkdir -p "$LOGS_DIR"
    LOG_FILE="$LOGS_DIR/pylux.log"
    CAPTURE_PID_FILE="$LOGS_DIR/pylux-capture.pid"

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  PYLUX ITERATE"
    echo "══════════════════════════════════════════════════════════════"
    stop_logs
    rm -f "$CAPTURE_PID_FILE"

    if [ "${PYLUX_FULL_BUILD:-0}" = "1" ]; then
        echo "=== PYLUX_FULL_BUILD=1: rebuilding chiaki-lib ==="
        build_lib
    fi

    resolve_physical_device
    if [ -z "$DEVICE_UDID" ]; then
        echo "ERROR: No physical iOS device for xcodebuild. Connect iPhone/iPad and trust this Mac."
        exit 1
    fi
    INSTALL_UDID="${DEVICECTL_UDID:-$DEVICE_UDID}"
    echo "=== Device: $DEVICE_NAME (xcodebuild id=$DEVICE_UDID) ==="

    echo "=== Touching static libs (force relink if lib changed) ==="
    touch "$SCRIPT_DIR/build-iphoneos/libchiaki_complete.a" 2>/dev/null || true
    touch "$SCRIPT_DIR/build-iphonesimulator/libchiaki_complete.a" 2>/dev/null || true

    echo "=== Xcode build (incremental, no clean) ==="
    (cd "$SCRIPT_DIR" && xcodebuild -project Pylux.xcodeproj -scheme "$SCHEME" -sdk iphoneos -configuration "$PYLUX_XCODE_CONFIGURATION" build \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$SCRIPT_DIR/build-derived" \
        -allowProvisioningUpdates \
        "${_PYLUX_XCODE_EXTRA[@]}") || {
        echo "ERROR: xcodebuild failed. Fix errors or run: PYLUX_FULL_BUILD=1 $0 iterate"
        exit 1
    }

    APP_PATH="$SCRIPT_DIR/build-derived/Build/Products/${PYLUX_XCODE_CONFIGURATION}-iphoneos/Pylux.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "ERROR: App not found at $APP_PATH"
        exit 1
    fi

    echo "=== Install + launch ==="
    xcrun devicectl device install app --device "$INSTALL_UDID" "$APP_PATH"
    xcrun devicectl device process kill --device "$INSTALL_UDID" "$BUNDLE_ID" 2>/dev/null || true
    sleep 1
    xcrun devicectl device process launch --device "$INSTALL_UDID" "$BUNDLE_ID" || true

    STOP_MIN="${PYLUX_LOG_MINUTES:-20}"
    SESSION_TAG="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n\n########## PYLUX STREAM SESSION %s ##########\n' "$SESSION_TAG" >> "$LOG_FILE"

    SYSLOG_CAPTURE_UDID="$(_pylux_resolve_syslog_udid "$DEVICE_UDID")"
    _pylux_start_phys_device_syslog_bg "$SYSLOG_CAPTURE_UDID" "$LOG_FILE"
    CAPTURE_PID=$PYLUX_SYSLOG_BG_PID
    echo "$CAPTURE_PID" > "$CAPTURE_PID_FILE"

    (
        sleep $((STOP_MIN * 60))
        if kill -0 "$CAPTURE_PID" 2>/dev/null; then
            kill "$CAPTURE_PID" 2>/dev/null || true
        fi
        rm -f "$CAPTURE_PID_FILE"
        printf '\n########## SESSION END (auto %s min) %s ##########\n' "$STOP_MIN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_FILE"
    ) &

    echo ""
    echo "  App launched. Log capture PID $CAPTURE_PID → $LOG_FILE"
    echo "  Auto-stops in ${STOP_MIN} min (set PYLUX_LOG_MINUTES to change)."
    echo ""
    echo "  → Open Pylux and press Stream."
    echo "  → Stop early: ./build.sh stop-logs"
    echo "  → Live:  tail -f $LOG_FILE"
    echo "  → Grep:  grep 'Pylux VideoDecoder\\|displayed:' $LOG_FILE | tail -40"
    echo ""
    echo "══════════════════════════════════════════════════════════════"
}

# --- Stop log streaming (kill orphan processes) ---
stop_logs() {
    local killed=0
    CAPTURE_PID_FILE="$SCRIPT_DIR/logs/pylux-capture.pid"
    if [ -f "$CAPTURE_PID_FILE" ]; then
        CAPTURE_PID=$(head -1 "$CAPTURE_PID_FILE" 2>/dev/null || true)
        if [ -n "$CAPTURE_PID" ] && kill -0 "$CAPTURE_PID" 2>/dev/null; then
            kill "$CAPTURE_PID" 2>/dev/null && { echo "Stopped capture PID $CAPTURE_PID"; killed=1; }
        fi
        rm -f "$CAPTURE_PID_FILE"
    fi
    for proc in idevicesyslog pymobiledevice3; do
        if pgrep -f "$proc" >/dev/null 2>&1; then
            pkill -f "$proc" 2>/dev/null && { echo "Stopped $proc"; killed=1; }
        fi
    done
    pkill -f "tee.*pylux.log" 2>/dev/null && { echo "Stopped tee"; killed=1; }
    [ $killed -eq 1 ] && echo "Log streaming stopped." || echo "No log streaming processes found."
}

# --- Main ---
case "$MODE" in
    dev)
        run_dev
        ;;
    launch|run)
        run_launch
        ;;
    release)
        run_release "$@"
        ;;
    ship)
        run_ship
        ;;
    clean)
        clean_and_rebuild
        ;;
    stop-logs)
        stop_logs
        ;;
    iterate)
        run_iterate
        ;;
    *)
        echo "Usage: $0 [dev|launch|iterate|release|ship|clean|stop-logs]"
        echo "  dev       - Build and run on device (if connected) or simulator"
        echo "  launch    - Launch app and stream logs (skip rebuild)"
        echo "  iterate   - Fast xcodebuild + install + launch + background logs (auto-stop, see header in script)"
        echo "  release   - Build archive for App Store upload"
        echo "  release xcframework - Also create XCFramework"
        echo "  ship      - Build + export IPA + upload to App Store Connect (needs fastlane + API key env vars)"
        echo "  clean     - Remove all build directories"
        echo "  stop-logs - Stop log capture"
        exit 1
        ;;
esac
