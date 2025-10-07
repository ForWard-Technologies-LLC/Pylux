#!/usr/bin/env bash
set -euo pipefail

# Host wrapper: uses a persistent container + incremental build, then launches the AppImage.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Ensure Podman
if ! command -v podman >/dev/null 2>&1; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman
fi

# Ensure builder image
podman image exists docker.io/streetpea/chiaki-ng-builder:qt6.9 || podman pull docker.io/streetpea/chiaki-ng-builder:qt6.9

# Pre-copy QML import like CI
mkdir -p gui/src/qml
cp -f scripts/qtwebengine_import.qml gui/src/qml/ || true

# Persistent container (run with sudo like CI to handle volume permissions)
container_name="chiaki-ng-dev"
if ! sudo podman container exists "$container_name"; then
  sudo podman create --name "$container_name" \
    -v "$(pwd):/build/chiaki:Z" \
    -w /build/chiaki \
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    -e APPIMAGE_EXTRACT_AND_RUN=1 \
    -t docker.io/streetpea/chiaki-ng-builder:qt6.9 \
    sleep infinity
fi

sudo podman start "$container_name" >/dev/null

# Ensure incremental script exists/executable
chmod +x scripts/build-appimage-incremental.sh

# Pre-create directories with correct permissions to avoid container permission issues
mkdir -p appimage/appdir build_appimage

# Run incremental build in container
SKIP_VAL="${SKIP_APPIMAGE:-0}"

# Use trap to ensure ownership is always fixed, even on failure
cleanup_ownership() {
    echo "Fixing ownership of build artifacts..."
    sudo chown -R "$(id -un)":"$(id -gn)" appimage build_appimage 2>/dev/null || true
}
trap cleanup_ownership EXIT

sudo podman exec --env SKIP_APPIMAGE="$SKIP_VAL" "$container_name" /bin/bash -lc 'set -xe; \
  sudo -E scripts/build-appimage-incremental.sh /build/chiaki/appimage/appdir' | tee /tmp/appimage_fast.log

# Launch either the unpackaged binary (from AppDir) or the AppImage
if [ "${SKIP_APPIMAGE:-0}" = "1" ]; then
  if [ -x appimage/appdir/usr/bin/chiaki ]; then
    echo "Starting application in foreground with verbose logging enabled..."
    echo "Note: All PSN HTTP requests and responses will be logged to the terminal."
    env LD_LIBRARY_PATH=appimage/appdir/usr/lib:${LD_LIBRARY_PATH-} \
      QT_PLUGIN_PATH=appimage/appdir/usr/plugins \
      QML2_IMPORT_PATH=appimage/appdir/usr/qml \
      QT_QPA_PLATFORM_PLUGIN_PATH=appimage/appdir/usr/plugins/platforms \
      QTWEBENGINEPROCESS_PATH=appimage/appdir/usr/libexec/QtWebEngineProcess \
      QT_LOGGING_RULES="chiaki.gui.debug=true" \
      appimage/appdir/usr/bin/chiaki
    exit 0
  else
    echo "ERROR: AppDir launcher not found: appimage/appdir/usr/bin/chiaki" >&2
    exit 1
  fi
else
  if [ -f appimage/chiaki-ng.AppImage ]; then
    nohup env APPIMAGE_EXTRACT_AND_RUN=1 ./appimage/chiaki-ng.AppImage > /tmp/chiaki_run.log 2>&1 &
    echo $! > /tmp/chiaki_app.pid
    echo "Launched (AppImage). PID $(cat /tmp/chiaki_app.pid)"
    echo "Build log: /tmp/appimage_fast.log"
    echo "Run log:   /tmp/chiaki_run.log"
  else
    echo "ERROR: appimage/chiaki-ng.AppImage not found" >&2
    exit 1
  fi
fi


