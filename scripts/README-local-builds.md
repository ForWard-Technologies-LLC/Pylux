Local build and run (AppImage and fast dev loop)

This repo includes scripts to mirror CI and to speed up local iteration.

Scripts
- build-appimage-ci.sh
  - One-shot full CI-equivalent AppImage build in a fresh container.
  - Produces `appimage/pylux.AppImage` and launches it.

- build-appimage-fast.sh
  - Fast dev loop using a persistent container and incremental build.
  - Reuses `build_appimage/` and `appimage/` between runs.
  - Launches either the packaged AppImage or the unpackaged binary from the AppDir.
  - Env:
    - `SKIP_APPIMAGE=1` — skip packaging; run `appimage/appdir/usr/bin/chiaki` directly.

- build-appimage-incremental.sh
  - In-container incremental builder/packager.
  - Called by the fast wrapper.

Usage
- Full CI-like build (packaged):
  ```bash
  scripts/build-appimage-ci.sh
  ```

- Fast incremental build and run (packaged AppImage):
  ```bash
  scripts/build-appimage-fast.sh
  ```

- Fast incremental build and run without packaging (runs from AppDir):
  ```bash
  SKIP_APPIMAGE=1 scripts/build-appimage-fast.sh
  ```

Notes
- All builds use the CI Podman image `streetpea/chiaki-ng-builder:qt6.9` and copy `scripts/qtwebengine_import.qml` at build-time.
- When running from AppDir, the script sets required Qt env vars automatically.
- AppImage runtime download lines in logs are avoided when `SKIP_APPIMAGE=1`.

