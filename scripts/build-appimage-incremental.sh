#!/usr/bin/env bash
set -euo pipefail

# Incremental in-container build/packaging (reuses outputs).
# Usage (inside container): scripts/build-appimage-incremental.sh [/build/appdir]

if [ "$(uname -m)" = "aarch64" ]; then GCC_STRING="gcc_arm64"; else GCC_STRING="gcc_64"; fi
QT_DIR="$(find "${QT_PATH}" -maxdepth 1 -type d -name "${QT_VERSION}")"
export PATH="${QT_DIR}/${GCC_STRING}/bin:$PATH"

appdir="${1:-"$(pwd)/appimage/appdir"}"
mkdir -p "appimage" "${appdir}"

# Ensure protoc once
if [ ! -x "appimage/protoc/bin/protoc" ]; then
  scripts/fetch-protoc.sh appimage
fi
export PATH="$(pwd)/appimage/protoc/bin:$PATH"

# Build heavy deps only if missing
[ -d "appimage/ffmpeg" ] || scripts/build-ffmpeg.sh appimage

if ! ls -d appimage/SDL2-* >/dev/null 2>&1; then
  scripts/build-sdl2.sh appimage
fi

[ -d "appimage/libplacebo" ] || scripts/build-libplacebo.sh appimage
[ -d "appimage/hidapi" ] || scripts/build-hidapi.sh appimage

# Configure only if needed
if [ ! -f build_appimage/CMakeCache.txt ]; then
  mkdir -p build_appimage
  (
    cd build_appimage
    qt-cmake -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCHIAKI_ENABLE_TESTS=ON \
      -DCHIAKI_ENABLE_GUI=ON \
      -DCHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER=ON \
      -DCMAKE_INSTALL_PREFIX=/usr \
      ..
  )
fi

# Avoid stale nanopb proto
rm -f third-party/nanopb/generator/proto/nanopb_pb2.py || true

# Rebuild changed code + tests
ninja -C build_appimage
build_appimage/test/chiaki-unit

# Stage into AppDir
DESTDIR="${appdir}" ninja -C build_appimage install

# Package with linuxdeploy (download once)
ARCH="$(uname -m)"
pushd appimage >/dev/null
export LD_LIBRARY_PATH="${QT_DIR}/${GCC_STRING}/lib:$(pwd)/../build_appimage/third-party/cpp-steam-tools:${LD_LIBRARY_PATH-}"
export QML_SOURCES_PATHS="$(pwd)/../gui/src/qml"
export EXTRA_QT_MODULES="waylandclient;waylandcompositor"
export EXTRA_PLATFORM_PLUGINS="libqwayland-egl.so;libqwayland-generic.so;libqeglfs.so;libqminimal.so;libqminimalegl.so;libqvkkhrdisplay.so;libqvnc.so;libqoffscreen.so;libqlinuxfb.so"
# Avoid failing on optional Qt SQL driver with proprietary dependency
export LINUXDEPLOY_PLUGIN_QT_BLACKLIST=".*libqsqlmimer.so"
# Proactively remove the plugin so the qt plugin doesn't try to deploy it
rm -f "${QT_DIR}/${GCC_STRING}/plugins/sqldrivers/libqsqlmimer.so" || true

[ -x "linuxdeploy-${ARCH}.AppImage" ] || curl -L -O "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage"
chmod +x "linuxdeploy-${ARCH}.AppImage"
[ -x "linuxdeploy-plugin-qt-${ARCH}.AppImage" ] || curl -L -O "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${ARCH}.AppImage"
chmod +x "linuxdeploy-plugin-qt-${ARCH}.AppImage"

# Cache AppImage runtime to avoid repeated downloads by appimagetool
export APPIMAGETOOL_RUNTIME="$(pwd)/runtime-${ARCH}"
if [ ! -f "${APPIMAGETOOL_RUNTIME}" ]; then
  curl -L -o "${APPIMAGETOOL_RUNTIME}" "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-${ARCH}" || true
fi

./linuxdeploy-${ARCH}.AppImage \
  --appdir="${appdir}" \
  -e "${appdir}/usr/bin/chiaki" \
  -d "${appdir}/usr/share/applications/chiaking.desktop" \
  --plugin qt \
  --exclude-library='libva*' \
  --exclude-library='libvulkan*'

# Optionally skip creating the AppImage and leave a runnable AppDir
if [ "${SKIP_APPIMAGE:-0}" != "1" ]; then
  # Build AppImage ourselves with cached appimagetool/runtime
  APPIMAGETOOL="appimagetool-${ARCH}.AppImage"
  if [ ! -x "${APPIMAGETOOL}" ]; then
    curl -L -o "${APPIMAGETOOL}" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
    chmod +x "${APPIMAGETOOL}"
  fi

  APPIMAGE_OUT="chiaki-ng-${ARCH}.AppImage"
  env APPIMAGE_EXTRACT_AND_RUN=1 \
    ./${APPIMAGETOOL} --no-appstream --runtime-file "${APPIMAGETOOL_RUNTIME}" "${appdir}" "${APPIMAGE_OUT}"

  mv -f "${APPIMAGE_OUT}" "chiaki-ng.AppImage"
else
  echo "SKIP_APPIMAGE=1 set; leaving AppDir at: ${appdir}"
fi
popd >/dev/null

