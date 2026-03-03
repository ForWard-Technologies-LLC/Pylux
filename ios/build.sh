#!/bin/bash
# iOS build script for Pylux (Chiaki)
# Similar to android/build.ps1: dev = simulator + run, release = production archive
#
# Usage:
#   ./build.sh [dev|release]     - dev (default): build and run on device/simulator
#                                  release: build archive for App Store upload
#   ./build.sh release xcframework - Also create XCFramework after release build
#
# Prerequisites: Xcode, Homebrew (cmake, ninja, protobuf, python)
# For release: Set DEVELOPMENT_TEAM in Xcode for code signing

set -e

MODE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_URL="https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake"
TOOLCHAIN_FILE="$SCRIPT_DIR/ios.toolchain.cmake"
SCHEME="Pylux"
BUNDLE_ID="com.pylux.stream"

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

# --- Build chiaki-lib (device + simulator) ---
build_lib() {
    echo "=== Building chiaki-lib for iOS device ==="
    cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/build-iphoneos" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DPLATFORM=OS64 \
        -DCMAKE_BUILD_TYPE=Release \
        $CMAKE_EXTRA
    cmake --build "$SCRIPT_DIR/build-iphoneos" --config Release --target chiaki-lib

    echo ""
    echo "=== Building chiaki-lib for iOS simulator ($SIMULATOR_PLATFORM) ==="
    cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/build-iphonesimulator" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DPLATFORM="$SIMULATOR_PLATFORM" \
        -DCMAKE_BUILD_TYPE=Release \
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

# --- Dev: build app for device (if connected) or simulator (fallback) ---
run_dev() {
    build_lib

    # Check for connected physical devices
    echo ""
    echo "=== Checking for connected devices ==="
    DEVICE_UDID=""
    DEVICE_NAME=""
    
    # Use xcodebuild -showdestinations to get exact device IDs that xcodebuild accepts
    DESTINATIONS=$(xcodebuild -project "$SCRIPT_DIR/Pylux.xcodeproj" -scheme "$SCHEME" -showdestinations 2>/dev/null | grep "platform:iOS," | grep -v "Simulator" | grep "name:")
    
    if [ -n "$DESTINATIONS" ]; then
        # Extract first physical device
        DEVICE_LINE=$(echo "$DESTINATIONS" | head -1)
        DEVICE_UDID=$(echo "$DEVICE_LINE" | grep -oE 'id:[^,}]+' | head -1 | cut -d: -f2)
        DEVICE_NAME=$(echo "$DEVICE_LINE" | grep -oE 'name:[^,}]+' | head -1 | cut -d: -f2- | sed 's/^ *//')
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
        (cd "$SCRIPT_DIR" && xcodebuild -project Pylux.xcodeproj -scheme "$SCHEME" -sdk iphoneos -configuration Debug clean build \
            -destination "id=$DEVICE_UDID" \
            -derivedDataPath "$SCRIPT_DIR/build-derived" \
            -allowProvisioningUpdates)

        APP_PATH="$SCRIPT_DIR/build-derived/Build/Products/Debug-iphoneos/Pylux.app"
        if [ ! -d "$APP_PATH" ]; then
            echo "ERROR: App not found at $APP_PATH"
            exit 1
        fi

        echo ""
        echo "=== Installing app on device ==="
        xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"
        
        # Kill existing instance to ensure fresh start
        xcrun devicectl device process kill --device "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true
        sleep 1
        
        xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" || true
        
        echo ""
        echo "App launched on physical device: $DEVICE_NAME"
        echo ""
        
        # Create logs directory and file
        LOGS_DIR="$SCRIPT_DIR/logs"
        mkdir -p "$LOGS_DIR"
        LOG_FILE="$LOGS_DIR/pylux.log"
        
        echo "=== Streaming logs (press Ctrl+C to stop) ==="
        echo "Logs also being saved to: $LOG_FILE"
        sleep 1
        
        # Capture all device logs - filter after the fact with: grep "Pylux" pylux.log
        exec idevicesyslog 2>&1 | tee "$LOG_FILE"
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
        (cd "$SCRIPT_DIR" && xcodebuild -project Pylux.xcodeproj -scheme "$SCHEME" -sdk iphonesimulator -configuration Debug clean build \
            -destination 'generic/platform=iOS Simulator' \
            "$XC_ARCHS" \
            -derivedDataPath "$SCRIPT_DIR/build-derived" \
            -quiet)

        APP_PATH="$SCRIPT_DIR/build-derived/Build/Products/Debug-iphonesimulator/Pylux.app"
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
        echo "=== Streaming logs (press Ctrl+C to stop) ==="
        sleep 2
        
        xcrun simctl spawn booted log stream \
            --predicate 'subsystem == "com.pylux.stream"' \
            --level info 2>&1
    fi
}

# --- Release: build app for device, create archive ---
run_release() {
    build_lib

    # Create archive for App Store / TestFlight (xcodebuild archive builds + archives)
    ARCHIVE_PATH="$SCRIPT_DIR/build-derived/Pylux.xcarchive"
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
    echo ""
    echo "To upload: Open Xcode > Window > Organizer, select the archive, then Distribute App."

    if [ "${2:-}" = "xcframework" ]; then
        echo ""
        echo "=== Creating XCFramework ==="
        create_xcframework
    fi
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
        
        # Try to get hardware UDID for idevicesyslog
        IDEVICE_UDID=$(idevice_id -l 2>/dev/null | head -1)
        
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
        
        # Capture all device logs (no filtering) to ensure we don't miss anything
        if [ -n "$IDEVICE_UDID" ]; then
            exec idevicesyslog -u "$IDEVICE_UDID" 2>&1 | tee "$LOG_FILE"
        else
            echo "WARNING: Could not detect device with idevicesyslog. Make sure device is unlocked and trusted."
            echo "Attempting to stream logs anyway..."
            exec idevicesyslog 2>&1 | tee "$LOG_FILE"
        fi
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
    xcodebuild clean -project "$SCRIPT_DIR/Pylux.xcodeproj" -scheme "$SCHEME" -configuration Debug 2>&1 | grep -E "^(Clean|note:|error:)" || true
    
    echo ""
    echo "=== Clean complete, starting rebuild ==="
    echo ""
    
    # Now run the dev build
    run_dev
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
    clean)
        clean_and_rebuild
        ;;
    *)
        echo "Usage: $0 [dev|launch|release|clean]"
        echo "  dev     - Build and run on device (if connected) or simulator"
        echo "  launch  - Launch app and stream logs (skip rebuild)"
        echo "  release - Build archive for App Store upload"
        echo "  release xcframework - Also create XCFramework"
        echo "  clean   - Remove all build directories"
        exit 1
        ;;
esac
