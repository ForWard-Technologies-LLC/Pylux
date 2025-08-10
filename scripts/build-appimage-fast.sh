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

# Persistent container
container_name="chiaki-ng-dev"
if ! podman container exists "$container_name"; then
  podman create --name "$container_name" \
    -v "$(pwd):/build/chiaki:Z" \
    -w /build/chiaki \
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    -e APPIMAGE_EXTRACT_AND_RUN=1 \
    -t docker.io/streetpea/chiaki-ng-builder:qt6.9 \
    sleep infinity
fi

podman start "$container_name" >/dev/null

# Ensure incremental script exists/executable
chmod +x scripts/build-appimage-incremental.sh

# Run incremental build in container (ensure writable dirs and privileged install)
podman exec -it --env SKIP_APPIMAGE=${SKIP_APPIMAGE:-0} "$container_name" /bin/bash -lc 'set -xe; \
  sudo chown -R user:user /build/chiaki/appimage /build/chiaki/build_appimage || true; \
  sudo -E scripts/build-appimage-incremental.sh /build/chiaki/appimage/appdir' | tee /tmp/appimage_fast.log

# Skip host chown to avoid sudo prompts; files are executable as-is

# Launch either the unpackaged binary (from AppDir) or the AppImage
if [ "${SKIP_APPIMAGE:-0}" = "1" ]; then
  if [ -x appimage/appdir/usr/bin/chiaki ]; then
    nohup env LD_LIBRARY_PATH=appimage/appdir/usr/lib:${LD_LIBRARY_PATH-} \
      QT_PLUGIN_PATH=appimage/appdir/usr/plugins \
      QML2_IMPORT_PATH=appimage/appdir/usr/qml \
      QT_QPA_PLATFORM_PLUGIN_PATH=appimage/appdir/usr/plugins/platforms \
      QTWEBENGINEPROCESS_PATH=appimage/appdir/usr/libexec/QtWebEngineProcess \
      appimage/appdir/usr/bin/chiaki > /tmp/chiaki_run.log 2>&1 &
    echo $! > /tmp/chiaki_app.pid
    echo "Launched (AppDir). PID $(cat /tmp/chiaki_app.pid)"
    echo "Build log: /tmp/appimage_fast.log"
    echo "Run log:   /tmp/chiaki_run.log"
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


