# Pylux — agent guide

Pylux is a cross-platform PS4/PS5 Remote Play + Internet/Cloud Play client (fork of
[chiaki-ng](https://github.com/streetpea/chiaki-ng)): shared C library (`lib/`), Qt desktop
(`gui/` — macOS/Windows/Linux/Steam Deck), Android (`android/`), iOS (`ios/`).

## Architecture
- **DO** put protocol, streaming, catalog, and feature logic in the shared C (`lib/`) so every
  platform gets it and stays consistent. Platforms only map inputs/outputs (controllers,
  audio, video, UI).
- **DON'T** patch shared behavior in one platform. If a fix would need repeating per platform,
  it belongs in `lib/`.
- **DO** debug cross-platform discrepancies empirically: capture runtime logs on a working and
  a broken platform and diff them, and diff suspect files against `upstream/main` (remote is
  configured).
- **DON'T** make sweeping edits to upstream-owned Qt files; prefer new files so chiaki-ng
  fixes stay cherry-pickable.

## Workflow
- Feature branches off `master`. PRs target **`release/beta`**, which auto-builds and deploys
  BETA to all stores on merge. `master` deploys to production. **DON'T** push to release
  branches casually.

## Data handling: title IDs, product IDs, entitlements
- **DON'T** infer prefix/regex patterns from the ID samples you happen to see. PSN IDs are
  region- and account-dependent; a pattern that fits one library corrupts matching for others.
- **DO** match structurally: split on `-`/`_` and drop the region-varying tail, via
  `cc_stable_key()` in `lib/src/cloudcatalog_merge.c` (see also `normalize_apollo_game` /
  `normalize_title` there). Extend those helpers; don't add ad-hoc string checks elsewhere.

## Build / run / verify
- **DO** use the build scripts and read their headers first — they are self-documenting:
  - macOS (Qt): `./scripts/build-macos.sh arm64 --iterate --skip-deps --ad-hoc
    --no-credentials-file --skip-notary-keychain --no-steamworks`; run `build-output/Pylux.app`
    only; logs in `tmp/pylux-macos.log` (`logs` subcommand).
  - iOS: `./ios/build.sh dev|iterate|launch|logs|stop-logs` (+`PYLUX_FULL_BUILD=1` when the C
    lib changed). Device logs stream over Wi-Fi into `ios/logs/pylux.log`; app relaunch =
    capture relaunch.
  - Android: `android/build.ps1` / `android/build-local.sh`.
- **DON'T** improvise around the scripts (custom launch paths, alternate log tools, manual
  bundle surgery, `idevicesyslog`, requiring USB for iOS logs, TERM-ing the iOS log capture —
  `stop-logs` handles it).
- **DO** verify changes by running on the real platform and reading its logs; compiling is not
  verification.

## iOS ↔ C library boundary
`ChiakiSession`'s memory layout depends on the lib's CMake config; Xcode compiles ObjC/Swift
without that config, so struct offsets differ between the two sides.
- **DON'T** call `static inline` chiaki functions that touch struct fields from `ios/Pylux/**`
  (e.g. the `chiaki_session_set_*` sink/callback setters) — the write lands at the wrong
  offset and silently no-ops. `ios/build.sh` fails the build on violations
  (`check_forbidden_inline_setters`).
- **DO** use the `CHIAKI_EXPORT` `_ex` wrappers in `lib/src/ios_bridge_helpers.c`, adding a
  wrapper there whenever the lib gains a setter iOS needs, and allocate `ChiakiSession` via
  `chiaki_session_get_sizeof()`, never `sizeof`.

## How the system works (non-obvious facts to respect)
- PS5 Remote Play delivers rumble ONLY as DualSense haptic audio: the client must set
  `enable_dualsense=true` and register a haptics sink (on iOS via
  `chiaki_session_set_haptics_sink_ex`). Cloud rumble uses classic rumble events — cloud
  working says nothing about Remote Play.
- Qt keyboard/controller navigation relies on `Qt::TabFocusAllControls` (gui main.cpp) and
  dialogs overriding `seedFocus()`; don't add competing `forceActiveFocus` calls.
- iOS binds the Create/PS controller buttons to system gestures by default;
  `StreamInput.attachController` claims them with `preferredSystemGestureState = .disabled`.
