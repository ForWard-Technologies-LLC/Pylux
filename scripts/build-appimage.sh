#!/bin/bash

set -xe

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
    --exclude-library='libssl*' \
    --exclude-library='libcrypto*' \
    --output appimage
# Exclude OpenSSL libraries: Qt 6.9 expects OpenSSL 3.x at runtime, but the build container
# (Ubuntu 20.04) only has OpenSSL 1.1.1f. By excluding these, the AppImage uses the system's
# OpenSSL (3.x on modern distros like Steam Deck), avoiding Qt TLS backend version mismatch.

# Standard AppImage creation (unchanged)
mv chiaki-ng-${ARCH}.AppImage chiaki-ng.AppImage

# === STEAM BUILD CREATION (ADDED) ===
# This runs AFTER AppImage is complete to avoid any interference
echo "Creating Steam-compatible portable Linux build..."
PORTABLE_DIR="PSStream"

# Copy the complete appdir that was used for AppImage
cp -r "${appdir}" "${PORTABLE_DIR}"

# Flatten directory structure for easier Steam deployment
cd "${PORTABLE_DIR}"
mv usr/* .
rmdir usr

# Ensure cpp-steam-tools library is included
cp ../build_appimage/third-party/cpp-steam-tools/libcpp-steam-tools.so lib/ 2>/dev/null || true

# Ensure Steamworks library is included (handle both x64 and arm64)
if [ "$(uname -m)" = "aarch64" ]; then
    # For ARM64, we still use linux64 as Steamworks doesn't provide ARM64 specific binaries
    # The linux64 x86_64 binary should work under x86_64 emulation on most ARM64 systems
    cp ../third-party/steamworks/steamworks_sdk/redistributable_bin/linux64/libsteam_api.so lib/ 2>/dev/null || true
else
    cp ../third-party/steamworks/steamworks_sdk/redistributable_bin/linux64/libsteam_api.so lib/ 2>/dev/null || true
fi
if [ ! -f lib/libsteam_api.so ]; then
    echo "Warning: libsteam_api.so not found for Steam build"
fi

# Create minimal launch script
cat > launch.sh << 'EOF'
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${DIR}/lib:${LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="${DIR}/plugins"
exec "${DIR}/bin/chiaki" "$@"
EOF

chmod +x launch.sh

cd ..

# Don't package here - will be done outside container where zip is available
# === END STEAM BUILD CREATION ===