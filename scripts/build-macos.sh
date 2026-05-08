#!/bin/bash
# macOS build script for Pylux following chiaki-ng GitHub Actions workflow
# Based on: https://github.com/streetpea/chiaki-ng/.github/workflows/build-macos.yml
#
# Usage:
#   ./build-macos.sh [arm64|x86_64|universal] [options...]
#
# Options (any order):
#   arm64|x86_64|universal - Target architecture (default: this machine)
#   --skip-deps            - Skip dependency installation (faster for development)
#   --notarize             - Force notarization (requires Developer ID signing)
#   --no-notarize          - Skip notarization (even if credentials.env sets MACOS_SIGN_ID)
#   --ad-hoc               - Ad-hoc codesign only; ignores MACOS_SIGN_ID from credentials.env
#   --skip-notary-keychain - Do not run notarytool store-credentials (faster local iteration)
#   --no-credentials-file  - Do not load secrets/macos/credentials.env (ad-hoc unless MACOS_SIGN_ID in env)
#   --steamworks           - Build with Steamworks SDK integration (default: OFF)
#   --no-steamworks        - Build without Steamworks SDK integration
#   --appstore             - Build with CHIAKI_IS_MAC_APPSTORE=ON (enables StoreKit IAP, disables Stripe)
#   --skip-dmg-notarize    - After signing .app, skip DMG creation and notarization (e.g. Mac App Store)
#   --iterate              - Fast rebuild: skip cmake configure, incremental ninja, copy binary into
#                            existing .app bundle, re-sign, skip DMG. Requires a prior full build.
#
# Optional environment:
#   PYLUX_ENTITLEMENTS     - Path to entitlements plist (default: gui/entitlements.xml)
#   PYLUX_EXTRA_CMAKE_ARGS  - Extra cmake args (e.g. -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_GUI_WEBENGINE=OFF)
#
# If secrets/macos/credentials.env exists, it is loaded by default and MACOS_SIGN_ID is
# required unless you pass --ad-hoc or --no-credentials-file. Use --ad-hoc for local
# builds without changing that file; use --no-notarize / --skip-notary-keychain to avoid
# notarization and keychain setup while still using Developer ID if desired.
#
# Optional: notarytool store-credentials runs when APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD,
# and APPLE_TEAM_ID are set after loading credentials, unless --skip-notary-keychain or
# --ad-hoc (profile AC_PASSWORD or NOTARIZE_KEYCHAIN_PROFILE).
#
# FIXED FOR macOS 26 Tahoe: Added UIDesignRequiresCompatibility to Info.plist

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS_PLIST="${PYLUX_ENTITLEMENTS:-$REPO_ROOT/gui/entitlements.xml}"
NOTARY_PROFILE="${NOTARIZE_KEYCHAIN_PROFILE:-AC_PASSWORD}"
SECRETS_FILE="$REPO_ROOT/secrets/macos/credentials.env"

BUILD_OUTPUT_DIR="$REPO_ROOT/build-output"
SKIP_DEPS="false"
NOTARIZE=""  # empty = auto from SIGN_ID; true/false if --notarize/--no-notarize
AD_HOC="false"
SKIP_NOTARY_KEYCHAIN="false"
NO_CREDENTIALS_FILE="false"
ARCH=""
MOLTENVK_VERSION="v1.2.9"
STEAMWORKS="OFF"
SKIP_DMG_NOTARIZE="false"
MAC_APPSTORE="OFF"
ITERATE="false"

# Parse arguments first so flags work regardless of order (e.g. --no-notarize universal)
for arg in "$@"; do
    case "$arg" in
        arm64|x86_64|universal) ARCH="$arg" ;;
        --skip-deps) SKIP_DEPS="true" ;;
        --notarize) NOTARIZE="true" ;;
        --no-notarize) NOTARIZE="false" ;;
        --ad-hoc) AD_HOC="true" ;;
        --skip-notary-keychain) SKIP_NOTARY_KEYCHAIN="true" ;;
        --no-credentials-file) NO_CREDENTIALS_FILE="true" ;;
        --steamworks) STEAMWORKS="ON" ;;
        --no-steamworks) STEAMWORKS="OFF" ;;
        --appstore) MAC_APPSTORE="ON" ;;
        --skip-dmg-notarize) SKIP_DMG_NOTARIZE="true" ;;
        --iterate) ITERATE="true" ;;
        *)
            if [[ "$arg" == -* ]]; then
                echo "Unknown option: $arg"
                echo "Usage: $0 [arm64|x86_64|universal] [--skip-deps] [--notarize|--no-notarize] [--ad-hoc] [--skip-notary-keychain] [--no-credentials-file] [--steamworks|--no-steamworks] [--appstore] [--skip-dmg-notarize] [--iterate]"
                exit 1
            fi
            echo "Unknown argument: $arg"
            echo "Usage: $0 [arm64|x86_64|universal] [--skip-deps] [--notarize|--no-notarize] [--ad-hoc] [--skip-notary-keychain] [--no-credentials-file] [--steamworks|--no-steamworks] [--appstore] [--skip-dmg-notarize] [--iterate]"
            exit 1
            ;;
    esac
done

ARCH="${ARCH:-$(uname -m)}"

# Optional secrets/macos/credentials.env — loads MACOS_SIGN_ID, Apple IDs, etc.
if [ "$NO_CREDENTIALS_FILE" = "false" ] && [ -f "$SECRETS_FILE" ]; then
    echo "Loading credentials from secrets/macos/credentials.env..."
    set -a
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    set +a
    if [ "$AD_HOC" = "false" ] && [ -z "${MACOS_SIGN_ID:-}" ]; then
        echo "ERROR: MACOS_SIGN_ID not set in $SECRETS_FILE (use --ad-hoc for ad-hoc signing)"
        exit 1
    fi
fi

# One-time / refresh: Keychain profile for notarytool submit --keychain-profile
if [ "$SKIP_NOTARY_KEYCHAIN" = "false" ] && [ "$AD_HOC" = "false" ]; then
    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        echo "Configuring notarytool credentials (profile: $NOTARY_PROFILE)..."
        if xcrun notarytool store-credentials "$NOTARY_PROFILE" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD"; then
            echo "NotaryTool credentials stored."
        else
            echo "Note: NotaryTool credentials may already be configured (or update failed)."
        fi
    fi
fi

if [ "$AD_HOC" = "true" ]; then
    SIGN_ID="-"
else
    SIGN_ID="${MACOS_SIGN_ID:--}"
fi

# --options runtime enables library validation; with ad-hoc ("-") every loadable has no real
# Team ID and dyld rejects mixing them (Qt frameworks vs main). Use hardened runtime only
# for Developer ID builds that go through notarization.
if [ "$SIGN_ID" = "-" ]; then
    CODE_SIGN_EXTRA=()
else
    CODE_SIGN_EXTRA=(--timestamp --options runtime)
fi

# Default: notarize when doing a distribution build (Developer ID signing)
if [ -z "$NOTARIZE" ]; then
    if [ "$SIGN_ID" != "-" ]; then
        NOTARIZE="true"
    else
        NOTARIZE="false"
    fi
fi

if [ "$SKIP_DMG_NOTARIZE" = "true" ]; then
    NOTARIZE="false"
fi

# Detect build mode from architecture
if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "x86_64" ]; then
    BUILD_MODE="single"
elif [ "$ARCH" = "universal" ]; then
    BUILD_MODE="universal"
else
    echo "Unknown architecture: $ARCH"
    echo "Usage: $0 [arm64|x86_64|universal] [--skip-deps] [--notarize|--no-notarize] [--ad-hoc] [--skip-notary-keychain] [--no-credentials-file] [--steamworks|--no-steamworks] [--skip-dmg-notarize] [--iterate]"
    exit 1
fi

if [ "$ITERATE" = "true" ]; then
    SKIP_DEPS="true"
    SKIP_DMG_NOTARIZE="true"
    NOTARIZE="false"
fi

echo "Building for: $ARCH"
echo "Steamworks: $STEAMWORKS"
echo "Mac App Store: $MAC_APPSTORE"
if [ "$ITERATE" = "true" ]; then
    echo "Mode: ITERATE (fast incremental rebuild)"
fi
echo ""

# Create build output directory
mkdir -p "$BUILD_OUTPUT_DIR"

# Check for Homebrew
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew not found. Install from https://brew.sh"
    exit 1
fi

# ========== Install Dependencies ==========
if [ "$SKIP_DEPS" = "false" ]; then
    echo "=== Installing dependencies ==="

    # Python protobuf for nanopb generator
    if ! python3 -c "import google.protobuf" 2>/dev/null; then
        echo "Installing Python protobuf..."
        pip3 install --user 'protobuf>=5,<6' --break-system-packages 2>/dev/null || pip3 install 'protobuf>=5,<6'
    fi

    # Homebrew dependencies
    echo "Installing Homebrew dependencies..."
    # Unlink old chiaki-ng-qt if present (conflicts with qt@6)
    brew unlink chiaki-ng-qt 2>/dev/null || true
    brew install qt@6 ffmpeg pkgconfig opus openssl cmake ninja nasm sdl2 protobuf@29 speexdsp libplacebo wget python-setuptools json-c miniupnpc
    # Ensure qt@6 is linked
    brew link qt@6 --overwrite 2>/dev/null || true

    echo ""
else
    echo "=== Skipping dependency installation (--skip-deps flag set) ==="
    echo ""
fi

if [ "$ITERATE" = "false" ]; then
    # Ensure submodules are initialized
    echo "=== Initializing submodules ==="
    git submodule update --init --recursive

    # Purge leftover proto files
    rm -f "$REPO_ROOT/third-party/nanopb/generator/proto/nanopb_pb2.py"
fi

echo ""

# ========== Build Function ==========
build_for_arch() {
    local build_arch=$1
    local build_dir="build-$build_arch"
    
    echo "=== Building for $build_arch ==="
    
    # Set architecture-specific flags
    if [ "$build_arch" = "arm64" ]; then
        CMAKE_ARCH_FLAGS="-DCMAKE_OSX_ARCHITECTURES=arm64"
    else
        CMAKE_ARCH_FLAGS="-DCMAKE_OSX_ARCHITECTURES=x86_64"
    fi
    
    # Configure (matching GitHub Actions exactly)
    # PYLUX_EXTRA_CMAKE_ARGS: e.g. macos/build-appstore.sh sets -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF
    cmake -S "$REPO_ROOT" -B "$REPO_ROOT/$build_dir" -G "Ninja" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCHIAKI_ENABLE_CLI=OFF \
        -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
        -DCHIAKI_ENABLE_STEAMWORKS="$STEAMWORKS" \
        -DCHIAKI_IS_MAC_APPSTORE="$MAC_APPSTORE" \
        $CMAKE_ARCH_FLAGS \
        -DCMAKE_PREFIX_PATH="$(brew --prefix)/opt/openssl@3;$(brew --prefix)/opt/qt@6;$(brew --prefix)/opt/protobuf@29" \
        ${PYLUX_EXTRA_CMAKE_ARGS:-}
    
    # Build (matching GitHub Actions exactly)
    export CPATH="$(brew --prefix)/opt/ffmpeg/include"
    cmake --build "$REPO_ROOT/$build_dir" --config Release --clean-first --target chiaki
    
    echo ""
}

# ========== Deploy Function (following GitHub Actions exactly) ==========
deploy_app() {
    local build_dir=$1
    local output_name="${2:-Pylux.app}"
    local output_path="$BUILD_OUTPUT_DIR/$output_name"
    
    echo "=== Deploying from $build_dir ==="
    
    # Copy app bundle
    rm -rf "$output_path"
    cp -a "$REPO_ROOT/$build_dir/gui/chiaki.app" "$output_path"
    
    # macdeployqt qmldir scan: stub only if chiaki links WebEngine (matches CHIAKI_ENABLE_GUI_WEBENGINE / Linux off)
    local _chiaki_bin="$REPO_ROOT/$build_dir/gui/chiaki.app/Contents/MacOS/chiaki"
    if otool -L "$_chiaki_bin" 2>/dev/null | grep -q 'QtWebEngineQuick'; then
        if [ "$(uname -m)" = "arm64" ]; then
            echo "import QtWebEngine; WebEngineView {}" > "$REPO_ROOT/gui/src/qml/qtwebengine_import.qml"
        else
            cp "$REPO_ROOT/scripts/qtwebengine_import.qml" "$REPO_ROOT/gui/src/qml/" 2>/dev/null || \
                echo "import QtWebEngine; WebEngineView {}" > "$REPO_ROOT/gui/src/qml/qtwebengine_import.qml"
        fi
    else
        rm -f "$REPO_ROOT/gui/src/qml/qtwebengine_import.qml"
    fi
    
    # Run macdeployqt (first pass)
    echo "Running macdeployqt (first pass)..."
    "$(brew --prefix)/opt/qt@6/bin/macdeployqt" "$output_path" \
        -qmldir="$REPO_ROOT/gui/src/qml" \
        -libpath="$(brew --prefix)/lib"
    
    # Download and install MoltenVK (use v1.2.9 to match working GitHub Actions)
    echo "Installing MoltenVK v1.2.9..."
    mkdir -p "$output_path/Contents/Resources/vulkan/icd.d"
    
    MOLTENVK_TAR="$BUILD_OUTPUT_DIR/MoltenVK-macos.tar"
    MOLTENVK_DIR="$BUILD_OUTPUT_DIR/MoltenVK"
    
    if [ ! -f "$MOLTENVK_TAR" ]; then
        rm -f "$BUILD_OUTPUT_DIR"/MoltenVK-macos*.tar
        wget -q "https://github.com/KhronosGroup/MoltenVK/releases/download/${MOLTENVK_VERSION}/MoltenVK-macos.tar" -O "$MOLTENVK_TAR"
        tar xf "$MOLTENVK_TAR" -C "$BUILD_OUTPUT_DIR"
    elif [ ! -d "$MOLTENVK_DIR" ]; then
        tar xf "$MOLTENVK_TAR" -C "$BUILD_OUTPUT_DIR"
    fi
    
    cp "$MOLTENVK_DIR"/MoltenVK/dylib/macOS/* "$output_path/Contents/Resources/vulkan/icd.d/"
    
    # Run macdeployqt (second pass)
    echo "Running macdeployqt (second pass)..."
    "$(brew --prefix)/opt/qt@6/bin/macdeployqt" "$output_path" \
        -qmldir="$REPO_ROOT/gui/src/qml" \
        -libpath="$(brew --prefix)/lib"
    
    # Fix QtWebEngineCore framework symlink if present
    if [[ -d "$output_path/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app" ]]; then
        echo "Fixing QtWebEngineCore symlinks..."
        ln -sf ../../../../../../../Frameworks \
            "$output_path/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app/Contents/Frameworks" \
            2>/dev/null || true
    fi
    
    # Create vulkan symlink
    ln -sf libvulkan.1.dylib "$output_path/Contents/Frameworks/vulkan" 2>/dev/null || true
    
    if [ "$STEAMWORKS" = "ON" ]; then
        # Copy Steamworks library
        echo "Adding Steamworks library..."
        mkdir -p "$output_path/Contents/Frameworks"
        cp "$REPO_ROOT/third-party/steamworks/steamworks_sdk/redistributable_bin/osx/libsteam_api.dylib" "$output_path/Contents/Frameworks/"
        install_name_tool -id "@rpath/libsteam_api.dylib" "$output_path/Contents/Frameworks/libsteam_api.dylib"
        
        # Fix Steam API library reference in main executable
        install_name_tool -change "@loader_path/libsteam_api.dylib" "@rpath/libsteam_api.dylib" "$output_path/Contents/MacOS/chiaki"
        
        # Create steam_appid.txt for Steamworks (in Resources to avoid codesign failure:
        # a .txt file in MacOS/ triggers "code object is not signed" with hardened runtime)
        echo "Adding steam_appid.txt..."
        echo "2805730" > "$output_path/Contents/Resources/steam_appid.txt"
    fi
    
    # Code sign (Developer ID if MACOS_SIGN_ID set, else ad-hoc)
    # Inside-out order; hardened runtime only when CODE_SIGN_EXTRA is set (not ad-hoc)
    echo "Code signing app bundle with ${SIGN_ID:-ad-hoc}..."
    sign_app_bundle "$output_path"
    
    echo ""
}

# Sign app bundle: inside-out order; hardened runtime only for Developer ID (notarization path)
sign_app_bundle() {
    local app_path="$1"
    if [ ! -f "$ENTITLEMENTS_PLIST" ]; then
        echo "ERROR: Entitlements plist not found: $ENTITLEMENTS_PLIST"
        exit 1
    fi
    echo "  Using entitlements: $ENTITLEMENTS_PLIST"
    echo "  Signing MoltenVK dylibs..."
    for dylib in "$app_path/Contents/Resources/vulkan/icd.d"/*.dylib; do
        [ -f "$dylib" ] && codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" "$dylib"
    done
    
    if [[ -d "$app_path/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app" ]]; then
        echo "  Signing QtWebEngineProcess..."
        codesign --force "${CODE_SIGN_EXTRA[@]}" --deep --sign "$SIGN_ID" \
            "$app_path/Contents/Frameworks/QtWebEngineCore.framework/Versions/A/Helpers/QtWebEngineProcess.app"
    fi
    
    echo "  Signing framework executables..."
    for fwk in "$app_path/Contents/Frameworks/"*.framework; do
        [ -d "$fwk" ] || continue
        fwk_name=$(basename "$fwk" .framework)
        [ -f "$fwk/Versions/A/$fwk_name" ] && \
            codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" "$fwk/Versions/A/$fwk_name"
    done
    
    echo "  Signing framework bundles..."
    for fwk in "$app_path/Contents/Frameworks/"*.framework; do
        [ -d "$fwk" ] && codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" "$fwk"
    done
    
    echo "  Signing plugins..."
    [ -d "$app_path/Contents/PlugIns" ] && \
        find "$app_path/Contents/PlugIns" -name "*.dylib" -type f -exec \
            codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" {} \;
    
    echo "  Signing standalone dylibs..."
    find "$app_path/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -type f -exec \
        codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" {} \;
    
    echo "  Signing main executable..."
    codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" "$app_path/Contents/MacOS/chiaki"
    
    echo "  Signing app bundle..."
    codesign --force "${CODE_SIGN_EXTRA[@]}" --entitlements "$ENTITLEMENTS_PLIST" \
        --sign "$SIGN_ID" "$app_path"
}

# ========== Main Build Logic ==========

if [ "$ITERATE" = "true" ]; then
    # ---- Fast iterate mode: incremental ninja + copy binary + fix paths + re-sign + launch ----
    build_dir="build-$ARCH"
    output_path="$BUILD_OUTPUT_DIR/Pylux.app"

    if [ ! -d "$output_path" ]; then
        echo "ERROR: --iterate requires a prior full build ($output_path not found)"
        echo "Run a full build first, then use --iterate for fast iteration."
        exit 1
    fi

    if [ ! -d "$REPO_ROOT/$build_dir" ]; then
        echo "ERROR: Build directory $build_dir not found. Run a full build first."
        exit 1
    fi

    echo "=== Iterate: incremental build for $ARCH ==="
    # Sync the App Store flag with the CMake cache so --iterate respects --appstore / no --appstore
    cmake -B "$REPO_ROOT/$build_dir" -DCHIAKI_IS_MAC_APPSTORE="$MAC_APPSTORE"
    export CPATH="$(brew --prefix)/opt/ffmpeg/include"
    cmake --build "$REPO_ROOT/$build_dir" --config Release --target chiaki

    echo "=== Iterate: updating app bundle ==="
    cp "$REPO_ROOT/$build_dir/gui/chiaki.app/Contents/MacOS/chiaki" "$output_path/Contents/MacOS/chiaki"

    if [ -d "$REPO_ROOT/$build_dir/gui/chiaki.app/Contents/Resources" ]; then
        rsync -a "$REPO_ROOT/$build_dir/gui/chiaki.app/Contents/Resources/" "$output_path/Contents/Resources/" 2>/dev/null || true
    fi

    # Rewrite Homebrew library paths to @executable_path/../Frameworks/ (replicates macdeployqt)
    echo "=== Iterate: fixing library paths ==="
    _bin="$output_path/Contents/MacOS/chiaki"
    _fw="@executable_path/../Frameworks"
    otool -L "$_bin" | awk '{print $1}' | while read -r _lib; do
        case "$_lib" in
            /opt/homebrew/*)
                _base=$(basename "$_lib")
                # Frameworks: preserve the .framework/Versions/A/<name> structure
                if [[ "$_lib" == *".framework/"* ]]; then
                    _fwname=$(echo "$_lib" | sed 's|.*/\([^/]*\.framework/.*\)|\1|')
                    install_name_tool -change "$_lib" "$_fw/$_fwname" "$_bin" 2>/dev/null
                else
                    install_name_tool -change "$_lib" "$_fw/$_base" "$_bin" 2>/dev/null
                fi
                ;;
        esac
    done
    # Replace Homebrew rpaths with @executable_path/../Frameworks
    _has_exec_rpath=false
    otool -l "$_bin" | grep -A2 LC_RPATH | grep "path " | awk '{print $2}' | while read -r _rp; do
        case "$_rp" in
            /opt/homebrew/*)
                install_name_tool -delete_rpath "$_rp" "$_bin" 2>/dev/null || true
                ;;
            @executable_path/../Frameworks)
                _has_exec_rpath=true
                ;;
        esac
    done
    # Ensure the Frameworks rpath exists
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$_bin" 2>/dev/null || true

    echo "=== Iterate: re-signing ==="
    sign_app_bundle "$output_path"

    echo ""
    echo "=== Iterate: launching app ==="
    open "$output_path"

elif [ "$BUILD_MODE" = "universal" ]; then
    echo "=== Building Universal Binary ==="
    echo ""
    
    # Build both architectures
    build_for_arch "arm64"
    build_for_arch "x86_64"
    
    # Create universal app by deploying arm64 first
    deploy_app "build-arm64" "Pylux.app"
    
    # Create universal binary by combining both architectures
    echo "=== Creating universal binary ==="
    
    # Find the main executable
    MAIN_BINARY="$BUILD_OUTPUT_DIR/Pylux.app/Contents/MacOS/chiaki"
    ARM64_BINARY="$REPO_ROOT/build-arm64/gui/chiaki.app/Contents/MacOS/chiaki"
    X86_64_BINARY="$REPO_ROOT/build-x86_64/gui/chiaki.app/Contents/MacOS/chiaki"
    
    # Use lipo to create universal binary
    lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$MAIN_BINARY"
    
    # Re-sign after lipo (full inside-out sequence)
    sign_app_bundle "$BUILD_OUTPUT_DIR/Pylux.app"
    
else
    # Single architecture build
    build_for_arch "$ARCH"
    deploy_app "build-$ARCH" "Pylux.app"
fi

# ========== Create DMG ==========
if [ "$SKIP_DMG_NOTARIZE" = "true" ]; then
    echo ""
    echo "=== Skipping DMG and notarization (--skip-dmg-notarize) ==="
else
    echo "=== Creating DMG ==="
    rm -f "$BUILD_OUTPUT_DIR/Pylux.dmg"
    hdiutil create -srcfolder "$BUILD_OUTPUT_DIR/Pylux.app" "$BUILD_OUTPUT_DIR/Pylux.dmg"
    codesign --force "${CODE_SIGN_EXTRA[@]}" --sign "$SIGN_ID" "$BUILD_OUTPUT_DIR/Pylux.dmg"

    # ========== Notarize ==========
    if [ "$NOTARIZE" = "true" ]; then
        if [ "$SIGN_ID" = "-" ]; then
            echo "ERROR: Notarization requires MACOS_SIGN_ID (Developer ID). Use --no-notarize to skip."
            exit 1
        fi
        echo ""
        echo "=== Notarizing ==="
        echo "Submitting to Apple (this may take a few minutes)..."
        xcrun notarytool submit "$BUILD_OUTPUT_DIR/Pylux.dmg" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
        echo "Stapling notarization ticket..."
        xcrun stapler staple "$BUILD_OUTPUT_DIR/Pylux.dmg"
        xcrun stapler staple "$BUILD_OUTPUT_DIR/Pylux.app"
        echo "Notarization complete."
    fi
fi

echo ""
echo "=== Build Complete! ==="
echo ""
echo "App bundle: $BUILD_OUTPUT_DIR/Pylux.app"
if [ "$SKIP_DMG_NOTARIZE" = "true" ]; then
	echo "DMG file:   (skipped)"
else
	echo "DMG file:   $BUILD_OUTPUT_DIR/Pylux.dmg"
fi
echo ""
echo "To run:"
echo "  open $BUILD_OUTPUT_DIR/Pylux.app"
echo ""
echo "Distribution (credentials.env + default notarize):"
echo "  ./scripts/build-macos.sh [universal]"
echo "Local without notary / ad-hoc (credentials.env still present):"
echo "  ./scripts/build-macos.sh --ad-hoc --no-notarize --skip-notary-keychain"
echo "Mac App Store PKG (see macos/build-appstore.sh):"
echo "  ./macos/build-appstore.sh"
echo ""
