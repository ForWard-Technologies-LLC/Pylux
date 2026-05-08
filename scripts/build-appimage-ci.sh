#!/usr/bin/env bash

# Build chiaki-ng AppImage exactly like the GitHub Action, then launch it.
# - Uses the same Podman builder image: docker.io/streetpea/chiaki-ng-builder:qt6.9
# - Mirrors the CI steps (including QML WebEngine import copy)
# - Forces FUSE-less AppImage packaging and runtime via APPIMAGE_EXTRACT_AND_RUN=1
# - Ensures local source changes are used (bind mounts repo into the container)
# - Launches the produced AppImage in the background and logs to /tmp/chiaki_run.log

set -euo pipefail

main() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$repo_root"

  echo "[build-appimage-ci] Repo: $repo_root"

  # 1) Ensure Podman is available (same engine the CI uses)
  if ! command -v podman >/dev/null 2>&1; then
    echo "[build-appimage-ci] Installing podman..."
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman
  fi

  # 2) Copy QML import as in CI (pre-copy on host to avoid container FS perms issues)
  echo "[build-appimage-ci] Copying QML WebEngine import..."
  mkdir -p gui/src/qml
  cp -f scripts/qtwebengine_import.qml gui/src/qml/ || true

  # 3) Pull the exact builder image used by CI
  echo "[build-appimage-ci] Pulling builder image..."
  podman pull docker.io/streetpea/chiaki-ng-builder:qt6.9

  # 4) Clean previous container-created artifacts that might be root-owned
  echo "[build-appimage-ci] Cleaning previous build outputs..."
  sudo rm -rf appimage build_appimage || true

  # 5) Run the CI build inside the container, with FUSE-less AppImage packaging
  echo "[build-appimage-ci] Running containerized build (this may take a while)..."
  sudo podman run --rm \
    -v "$(pwd):/build/chiaki:Z" \
    -w /build/chiaki \
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    -e APPIMAGE_EXTRACT_AND_RUN=1 \
    -t docker.io/streetpea/chiaki-ng-builder:qt6.9 \
    /bin/bash -lc 'set -xe; sudo -E scripts/build-appimage.sh /build/appdir' \
    | tee /tmp/appimage_ci.log

  # 6) Make sure the resulting AppImage is owned by the calling user
  echo "[build-appimage-ci] Fixing ownership of build artifacts..."
  sudo chown -R "$(id -un)":"$(id -gn)" appimage build_appimage || true

  # 7) Launch the AppImage in the background using extract-and-run and log output
  echo "[build-appimage-ci] Launching AppImage in background..."
  if [[ ! -f appimage/pylux.AppImage ]]; then
    echo "[build-appimage-ci] ERROR: appimage/pylux.AppImage not found" >&2
    exit 1
  fi

  # Note: file should already be executable; avoid chmod if not needed to prevent EPERM
  nohup env APPIMAGE_EXTRACT_AND_RUN=1 ./appimage/pylux.AppImage \
    > /tmp/chiaki_run.log 2>&1 &
  echo $! > /tmp/chiaki_app.pid

  echo "[build-appimage-ci] Done. AppImage PID: $(cat /tmp/chiaki_app.pid)"
  echo "[build-appimage-ci] Build log: /tmp/appimage_ci.log"
  echo "[build-appimage-ci] Run log:   /tmp/chiaki_run.log"
  echo "[build-appimage-ci] Tail logs: tail -f /tmp/chiaki_run.log"
  echo "[build-appimage-ci] Stop app:  kill \"$(cat /tmp/chiaki_app.pid)\""
}

main "$@"


