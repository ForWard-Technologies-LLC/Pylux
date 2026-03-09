#!/bin/bash
# macOS build script for Pylux following chiaki-ng GitHub Actions workflow
# Based on: https://github.com/streetpea/chiaki-ng/.github/workflows/build-macos.yml
#
# Usage:
#   ./build-macos.sh [arm64|x86_64|universal] [--skip-deps]
#
# Options:
#   arm64      - Build for Apple Silicon only (default on M-series Macs)
#   x86_64     - Build for Intel only (default on Intel Macs)
#   universal  - Build universal binary (both architectures)
#   --skip-deps - Skip dependency installation (faster for development)
#
# FIXED FOR macOS 26 Tahoe: Added UIDesignRequiresCompatibility to Info.plist

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_OUTPUT_DIR="$SCRIPT_DIR/build-output"
ARCH="${1:-$(uname -m)}"
SKIP_DEPS="false"
MOLTENVK_VERSION="v1.2.9"

# Parse arguments
for arg in "$@"; do
    if [ "$arg" = "--skip-deps" ]; then
        SKIP_DEPS="true"
    fi
done

# Detect current architecture if not specified
if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "x86_64" ]; then
    BUILD_MODE="single"
elif [ "$ARCH" = "universal" ]; then
    BUILD_MODE="universal"
elif [ "$ARCH" = "--skip-deps" ]; then
    ARCH="$(uname -m)"
    BUILD_MODE="single"
else
    echo "Unknown architecture: $ARCH"
    echo "Usage: $0 [arm64|x86_64|universal] [--skip-deps]"
    exit 1
fi

echo "Building for: $ARCH"
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

# Ensure submodules are initialized
echo "=== Initializing submodules ==="
git submodule update --init --recursive

# Purge leftover proto files
rm -f "$SCRIPT_DIR/third-party/nanopb/generator/proto/nanopb_pb2.py"

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
    cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/$build_dir" -G "Ninja" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCHIAKI_ENABLE_CLI=OFF \
        -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
        -DCHIAKI_ENABLE_STEAMWORKS=ON \
        $CMAKE_ARCH_FLAGS \
        -DCMAKE_PREFIX_PATH="$(brew --prefix)/opt/openssl@3;$(brew --prefix)/opt/qt@6;$(brew --prefix)/opt/protobuf@29"
    
    # Build (matching GitHub Actions exactly)
    export CPATH="$(brew --prefix)/opt/ffmpeg/include"
    cmake --build "$SCRIPT_DIR/$build_dir" --config Release --clean-first --target chiaki
    
    echo ""
}

# ========== Deploy Function (following GitHub Actions exactly) ==========
deploy_app() {
    local build_dir=$1
    local output_name="${2:-Pylux.app}"
    
    echo "=== Deploying from $build_dir ==="
    
    # Copy app bundle
    rm -rf "$SCRIPT_DIR/$output_name"
    cp -a "$SCRIPT_DIR/$build_dir/gui/chiaki.app" "$SCRIPT_DIR/$output_name"
    
    # Copy qtwebengine import file (for arm64 the echo approach, for x86_64 copy from scripts)
    if [ "$(uname -m)" = "arm64" ]; then
        echo "import QtWebEngine; WebEngineView {}" > "$SCRIPT_DIR/gui/src/qml/qtwebengine_import.qml"
    else
        cp "$SCRIPT_DIR/scripts/qtwebengine_import.qml" "$SCRIPT_DIR/gui/src/qml/" 2>/dev/null || \
            echo "import QtWebEngine; WebEngineView {}" > "$SCRIPT_DIR/gui/src/qml/qtwebengine_import.qml"
    fi
    
    # Run macdeployqt (first pass)
    echo "Running macdeployqt (first pass)..."
    "$(brew --prefix)/opt/qt@6/bin/macdeployqt" "$SCRIPT_DIR/$output_name" \
        -qmldir="$SCRIPT_DIR/gui/src/qml" \
        -libpath="$(brew --prefix)/lib"
    
    # Download and install MoltenVK (use v1.2.9 to match working GitHub Actions)
    echo "Installing MoltenVK v1.2.9..."
    mkdir -p "$SCRIPT_DIR/$output_name/Contents/Resources/vulkan/icd.d"
    
    MOLTENVK_TAR="$BUILD_OUTPUT_DIR/MoltenVK-macos.tar"
    MOLTENVK_DIR="$BUILD_OUTPUT_DIR/MoltenVK"
    
    if [ ! -f "$MOLTENVK_TAR" ]; then
        rm -f "$BUILD_OUTPUT_DIR"/MoltenVK-macos*.tar
        wget -q "https://github.com/KhronosGroup/MoltenVK/releases/download/${MOLTENVK_VERSION}/MoltenVK-macos.tar" -O "$MOLTENVK_TAR"
        tar xf "$MOLTENVK_TAR" -C "$BUILD_OUTPUT_DIR"
    elif [ ! -d "$MOLTENVK_DIR" ]; then
        tar xf "$MOLTENVK_TAR" -C "$BUILD_OUTPUT_DIR"
    fi
    
    cp "$MOLTENVK_DIR"/MoltenVK/dylib/macOS/* "$SCRIPT_DIR/$output_name/Contents/Resources/vulkan/icd.d/"
    
    # Run macdeployqt (second pass)
    echo "Running macdeployqt (second pass)..."
    "$(brew --prefix)/opt/qt@6/bin/macdeployqt" "$SCRIPT_DIR/$output_name" \
        -qmldir="$SCRIPT_DIR/gui/src/qml" \
        -libpath="$(brew --prefix)/lib"
    
    # Fix QtWebEngineCore framework symlink if present
    if [[ -d "$SCRIPT_DIR/$output_name/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app" ]]; then
        echo "Fixing QtWebEngineCore symlinks..."
        ln -sf ../../../../../../../Frameworks \
            "$SCRIPT_DIR/$output_name/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app/Contents/Frameworks" \
            2>/dev/null || true
    fi
    
    # Create vulkan symlink
    ln -sf libvulkan.1.dylib "$SCRIPT_DIR/$output_name/Contents/Frameworks/vulkan" 2>/dev/null || true
    
    # Copy Steamworks library
    echo "Adding Steamworks library..."
    mkdir -p "$SCRIPT_DIR/$output_name/Contents/Frameworks"
    cp "$SCRIPT_DIR/third-party/steamworks/steamworks_sdk/redistributable_bin/osx/libsteam_api.dylib" "$SCRIPT_DIR/$output_name/Contents/Frameworks/"
    install_name_tool -id "@rpath/libsteam_api.dylib" "$SCRIPT_DIR/$output_name/Contents/Frameworks/libsteam_api.dylib"
    
    # Fix Steam API library reference in main executable
    install_name_tool -change "@loader_path/libsteam_api.dylib" "@rpath/libsteam_api.dylib" "$SCRIPT_DIR/$output_name/Contents/MacOS/chiaki"
    
    # Code sign
    echo "Code signing app bundle..."
    codesign --force --entitlements "$SCRIPT_DIR/gui/entitlements.xml" --deep --sign - "$SCRIPT_DIR/$output_name"
    
    echo ""
}

# ========== Main Build Logic ==========

if [ "$BUILD_MODE" = "universal" ]; then
    echo "=== Building Universal Binary ==="
    echo ""
    
    # Build both architectures
    build_for_arch "arm64"
    build_for_arch "x86_64"
    
    # Create universal app by deploying arm64 first
    deploy_app "build-arm64" "$BUILD_OUTPUT_DIR/Pylux.app"
    
    # Create universal binary by combining both architectures
    echo "=== Creating universal binary ==="
    
    # Find the main executable
    MAIN_BINARY="$BUILD_OUTPUT_DIR/Pylux.app/Contents/MacOS/chiaki"
    ARM64_BINARY="$SCRIPT_DIR/build-arm64/gui/chiaki.app/Contents/MacOS/chiaki"
    X86_64_BINARY="$SCRIPT_DIR/build-x86_64/gui/chiaki.app/Contents/MacOS/chiaki"
    
    # Use lipo to create universal binary
    lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$MAIN_BINARY"
    
    # Re-sign after lipo
    codesign --force --entitlements "$SCRIPT_DIR/gui/entitlements.xml" --deep --sign - "$BUILD_OUTPUT_DIR/Pylux.app"
    
else
    # Single architecture build
    build_for_arch "$ARCH"
    deploy_app "build-$ARCH" "$BUILD_OUTPUT_DIR/Pylux.app"
fi

# ========== Create DMG ==========
echo "=== Creating DMG ==="
rm -f "$BUILD_OUTPUT_DIR/Pylux.dmg"
hdiutil create -srcfolder "$BUILD_OUTPUT_DIR/Pylux.app" "$BUILD_OUTPUT_DIR/Pylux.dmg"
codesign --force --entitlements gui/entitlements.xml --deep --sign - "$BUILD_OUTPUT_DIR/Pylux.dmg"

echo ""
echo "=== Build Complete! ==="
echo ""
echo "App bundle: $BUILD_OUTPUT_DIR/Pylux.app"
echo "DMG file:   $BUILD_OUTPUT_DIR/Pylux.dmg"
echo ""
echo "To run:"
echo "  open $BUILD_OUTPUT_DIR/Pylux.app"
echo ""
echo "To distribute:"
echo "  Upload $BUILD_OUTPUT_DIR/Pylux.dmg"
echo ""
