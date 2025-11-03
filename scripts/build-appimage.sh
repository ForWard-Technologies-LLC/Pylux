#!/bin/bash

set -xe

# ============================================================================
# UPSTREAM APPIMAGE BUILD SCRIPT
# ============================================================================
# This section is from upstream chiaki-ng and builds the standard AppImage.
# User additions are clearly marked below.
# ============================================================================

if [ "$(uname -m)" = "aarch64" ]
then
    export GCC_STRING="gcc_arm64"
else
    export GCC_STRING="gcc_64"
fi

export QT_DIR="$(find ${QT_PATH} -maxdepth 1 -type d -name "${QT_VERSION}")"
export PATH="${QT_DIR}/${GCC_STRING}/bin:$PATH"
if [ -f "${HOME}/chiaki-venv/bin/activate" ]
then
   source "${HOME}/chiaki-venv/bin/activate"
fi

# sometimes there are errors in linuxdeploy in docker/podman when the appdir is on a mount
appdir=${1:-`pwd`/appimage/appdir}

rm -rf appimage && mkdir -p appimage

scripts/fetch-protoc.sh appimage
export PATH="`pwd`/appimage/protoc/bin:$PATH"
scripts/build-ffmpeg.sh appimage
scripts/build-sdl2.sh appimage
scripts/build-libplacebo.sh appimage
scripts/build-hidapi.sh appimage

rm -rf build_appimage && mkdir -p build_appimage
cd build_appimage 
qt-cmake \
	-GNinja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCHIAKI_ENABLE_TESTS=ON \
	-DCHIAKI_ENABLE_GUI=ON \
	-DCHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER=ON \
	-DCHIAKI_ENABLE_STEAMWORKS=ON \
	-DCMAKE_INSTALL_PREFIX=/usr \
	..
cd ..

# purge leftover proto/nanopb_pb2.py which may have been created with another protobuf version
rm -fv third-party/nanopb/generator/proto/nanopb_pb2.py

ninja -C build_appimage
build_appimage/test/chiaki-unit

DESTDIR="${appdir}" ninja -C build_appimage install
cd appimage

export ARCH="$(uname -m)"
curl -L -O https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage
chmod +x linuxdeploy-${ARCH}.AppImage

export LD_LIBRARY_PATH="${QT_DIR}/${GCC_STRING}/lib:$(pwd)/../build_appimage/third-party/cpp-steam-tools:$(pwd)/../third-party/steamworks/steamworks_sdk/redistributable_bin/linux64:$LD_LIBRARY_PATH"
export QML_SOURCES_PATHS="$(pwd)/../gui/src/qml"
export EXTRA_QT_MODULES="waylandclient;waylandcompositor"
export EXTRA_PLATFORM_PLUGINS="libqwayland-egl.so;libqwayland-generic.so;libqeglfs.so;libqminimal.so;libqminimalegl.so;libqvkkhrdisplay.so;libqvnc.so;libqoffscreen.so;libqlinuxfb.so"
curl -L -O https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${ARCH}.AppImage
chmod +x linuxdeploy-plugin-qt-${ARCH}.AppImage
./linuxdeploy-${ARCH}.AppImage \
    --appdir="${appdir}" \
    -e "${appdir}/usr/bin/chiaki" \
    -d "${appdir}/usr/share/applications/chiaking.desktop" \
    --plugin qt \
    --exclude-library='libva*' \
    --exclude-library='libvulkan*' \
    --output appimage

mv chiaki-ng-${ARCH}.AppImage chiaki-ng.AppImage

# ============================================================================
# END OF UPSTREAM CODE
# ============================================================================


# ============================================================================
# USER ADDITIONS: STEAM BUILD CREATION
# ============================================================================
# The following code creates a Steam-compatible portable Linux build.
# It extracts the AppImage, adds Steam integration libraries, handles
# OpenSSL version conflicts, and creates a smart launch script.
#
# Key additions:
#   - PSStream directory extraction from AppImage
#   - Steam libraries (libsteam_api.so, libcpp-steam-tools.so)
#   - NSS crypto modules for QtWebEngine in Steam runtime
#   - OpenSSL fallback directory for version compatibility
#   - Smart launch.sh script with runtime detection
# ============================================================================
# This runs AFTER AppImage is complete to avoid any interference
echo "Creating Steam-compatible portable Linux build from extracted AppImage..."
PORTABLE_DIR="PSStream"

# Extract the AppImage to get all bundled libraries
chmod +x chiaki-ng.AppImage
./chiaki-ng.AppImage --appimage-extract

# Rename extracted directory to PSStream
mv squashfs-root "${PORTABLE_DIR}"

# ============================================================================
# AGPL COMPLIANCE: Add license and source code information
# ============================================================================
# Use the reusable helper script to add AGPL compliance files
cd ..
source scripts/add-agpl-compliance.sh
add_agpl_compliance "appimage/${PORTABLE_DIR}"
cd appimage
# ============================================================================

# Ensure cpp-steam-tools library is included
cp ../build_appimage/third-party/cpp-steam-tools/libcpp-steam-tools.so "${PORTABLE_DIR}/usr/lib/" 2>/dev/null || true

# Ensure Steamworks library is included (handle both x64 and arm64)
if [ "$(uname -m)" = "aarch64" ]; then
    # For ARM64, we still use linux64 as Steamworks doesn't provide ARM64 specific binaries
    # The linux64 x86_64 binary should work under x86_64 emulation on most ARM64 systems
    cp ../third-party/steamworks/steamworks_sdk/redistributable_bin/linux64/libsteam_api.so "${PORTABLE_DIR}/usr/lib/" 2>/dev/null || true
else
    cp ../third-party/steamworks/steamworks_sdk/redistributable_bin/linux64/libsteam_api.so "${PORTABLE_DIR}/usr/lib/" 2>/dev/null || true
fi
if [ ! -f "${PORTABLE_DIR}/usr/lib/libsteam_api.so" ]; then
    echo "Warning: libsteam_api.so not found for Steam build"
fi

# Copy complete NSS installation for Steam runtime compatibility
# NSS dynamically loads these crypto modules, so linuxdeploy doesn't detect them
echo "Adding NSS crypto libraries for Steam runtime..."
for nsslib in libsoftokn3.so libfreebl3.so libfreeblpriv3.so libplc4.so libplds4.so libsmime3.so; do
    # Try both standard locations (use -L to follow symlinks)
    if [ -f "/usr/lib/x86_64-linux-gnu/${nsslib}" ]; then
        echo "  Copying ${nsslib} from /usr/lib/x86_64-linux-gnu/"
        cp -L "/usr/lib/x86_64-linux-gnu/${nsslib}" "${PORTABLE_DIR}/usr/lib/" 2>/dev/null || echo "  Warning: Failed to copy ${nsslib}"
    elif [ -f "/usr/lib/x86_64-linux-gnu/nss/${nsslib}" ]; then
        echo "  Copying ${nsslib} from /usr/lib/x86_64-linux-gnu/nss/"
        cp -L "/usr/lib/x86_64-linux-gnu/nss/${nsslib}" "${PORTABLE_DIR}/usr/lib/" 2>/dev/null || echo "  Warning: Failed to copy ${nsslib}"
    else
        echo "  Warning: ${nsslib} not found in container"
    fi
done

# Move OpenSSL to separate fallback directory for conditional loading
# This allows us to use system/Steam OpenSSL when available (for Qt compatibility)
# but still have it as fallback for manual launches
echo "Setting up OpenSSL fallback directory..."
mkdir -p "${PORTABLE_DIR}/usr/lib/openssl-fallback"
if [ -f "${PORTABLE_DIR}/usr/lib/libssl.so.1.1" ]; then
    mv "${PORTABLE_DIR}/usr/lib/libssl.so.1.1" "${PORTABLE_DIR}/usr/lib/openssl-fallback/"
    echo "  Moved libssl.so.1.1 to openssl-fallback/"
fi
if [ -f "${PORTABLE_DIR}/usr/lib/libcrypto.so.1.1" ]; then
    mv "${PORTABLE_DIR}/usr/lib/libcrypto.so.1.1" "${PORTABLE_DIR}/usr/lib/openssl-fallback/"
    echo "  Moved libcrypto.so.1.1 to openssl-fallback/"
fi

# Create launch script for Steam
cat > "${PORTABLE_DIR}/launch.sh" << 'EOF'
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Always prioritize our bundled libs (NSS, Steam libs, Qt, etc.)
LIBS="${DIR}/usr/lib"

# Check if OpenSSL 1.1 is available in system/Steam runtime
# If not (manual launch), add our OpenSSL fallback directory
if ! ldconfig -p 2>/dev/null | grep -q "libssl.so.1.1"; then
    LIBS="${LIBS}:${DIR}/usr/lib/openssl-fallback"
fi

export LD_LIBRARY_PATH="${LIBS}:${LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="${DIR}/usr/plugins"
exec "${DIR}/usr/bin/chiaki" "$@"
EOF

chmod +x "${PORTABLE_DIR}/launch.sh"

# Don't package here - will be done outside container where zip is available

# ============================================================================
# END OF USER ADDITIONS
# ============================================================================