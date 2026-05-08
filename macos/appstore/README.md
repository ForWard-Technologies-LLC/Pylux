# Mac App Store packaging (Pylux)

This folder holds **Mac App Store–only** assets. The usual **Developer ID + DMG + notarization** flow is unchanged; see [scripts/build-macos.sh](../../scripts/build-macos.sh).

## Quick start

1. In [Apple Developer](https://developer.apple.com), create or select a **macOS App ID** with **App Sandbox** and capabilities that match [entitlements.plist](entitlements.plist) (and any extras you add).
2. Create and install **Mac App Store** certificates (not Developer ID):
   - **Certificates, Identifiers & Profiles → Certificates → +**  
   - Create **Apple Distribution** (or **Mac App Distribution**, depending on what Apple shows for your account) for signing the `.app`.  
   - Create **Mac Installer Distribution** (or **3rd Party Mac Developer Installer**) for signing the `.pkg`.  
   - Download each `.cer`, double-click to add to **Keychain Access** (login keychain is fine).
3. **Identity strings** for `credentials.env` (see below): run on your Mac:

   ```bash
   security find-identity -v -p codesigning
   ```

   Copy the full line in quotes for:
   - **Application:** must look like `Apple Distribution: …` or `3rd Party Mac Developer Application: …` — **not** `Developer ID Application: …`.
   - **Installer:** `3rd Party Mac Developer Installer: …` (wording may vary slightly by account age).

4. **Credentials (one file)** — put everything in **`secrets/macos/credentials.env`** (same as `scripts/build-macos.sh`; not committed). Copy from the tracked template **[secrets/macos/credentials.env.example](../../secrets/macos/credentials.env.example)**.

   For **Mac App Store** builds, [macos/build-appstore.sh](../build-appstore.sh) requires:
   - **`MACOS_APPSTORE_APPLICATION_SIGN_ID`** — signs the `.app` (Apple Distribution / Mac App Developer Application; **not** Developer ID).
   - **`MACOS_APPSTORE_INSTALLER_SIGN_ID`** — signs the `.pkg` for Transporter (Mac App Installer identity).
   - **`MACOS_APPSTORE_PROVISIONING_PROFILE`** — absolute path to a **Mac App Store** provisioning profile (`.provisionprofile`). The script copies it to `Pylux.app/Contents/embedded.provisionprofile` and re-signs the bundle. **Without this, App Store Connect / TestFlight may fail with missing provisioning profile (e.g. 90889).** The script also reads **`com.apple.application-identifier`** and **`com.apple.developer.team-identifier`** from that profile and merges them into the entitlements used for **every** App Store `codesign` step so the signature matches the profile (fixes **90886**).

   Create the profile in the developer portal (**Certificates, Identifiers & Profiles → Profiles → + → Mac** → type **Mac App Store**), select your app’s **macOS App ID**, download the profile, and either double-click it (installs under `~/Library/MobileDevice/Provisioning Profiles/`) or point the variable at the downloaded file.

   **Standalone** DMG/notarization still uses **`MACOS_SIGN_ID`** (Developer ID Application) and the `APPLE_*` variables; those are ignored by the App Store script except that they live in the same file.

5. From the **repository root**:

   ```bash
   ./macos/build-appstore.sh
   ```

   On **Apple Silicon**, the script defaults to an **arm64-only** app (same as a typical `/opt/homebrew` setup). For a **universal** binary (`arm64` + `x86_64`), run `PYLUX_MAC_APPSTORE_UNIVERSAL=1 ./macos/build-appstore.sh` — that only works locally if you have a full **x86_64** Homebrew dependency stack (see CI: [`.github/workflows/build-macos-universal.yml`](../../.github/workflows/build-macos-universal.yml) uses separate Intel and ARM runners).

   - **Clean + rebuild from scratch** (removes `build-arm64` / `build-x86_64` / `build-universal` and `Pylux.app` / `Pylux-appstore.pkg` / `Pylux.dmg`; keeps `build-output/MoltenVK*` cache):

     ```bash
     ./macos/build-appstore.sh --clean
     ```

   - **Clean only** (no build):

     ```bash
     ./macos/build-appstore.sh clean
     ```

   The script appends **`PYLUX_EXTRA_CMAKE_ARGS`**: **`CHIAKI_ENABLE_STEAM_SHORTCUT=OFF`** and **`CHIAKI_ENABLE_GUI_WEBENGINE=OFF`**. That reuses the same **root** CMake option as Linux (where WebEngine is forced off): no **QtWebEngineProcess** in the bundle (App Store sandbox). PSN sign-in stays **external browser** only. Normal **`./scripts/build-macos.sh`** leaves **`CHIAKI_ENABLE_GUI_WEBENGINE=ON`** unless you pass **`-DCHIAKI_ENABLE_GUI_WEBENGINE=OFF`**.

6. Upload `build-output/Pylux-appstore.pkg` with **Transporter**, then attach the build in **App Store Connect**.

## Entitlements in this repo (audit)

| Capability | Entitlement (baseline plist) | Driven by (code) |
|------------|------------------------------|------------------|
| App Sandbox | `com.apple.security.app-sandbox` | Mac App Store requirement |
| Outbound network | `com.apple.security.network.client` | HTTP/PSN/cloud APIs, streaming (`QNetworkAccessManager`, lib remote) |
| Inbound/listen | `com.apple.security.network.server` | Discovery / UDP behavior may require listening; validate under sandbox |
| Microphone | `com.apple.security.device.audio-input` | `NSMicrophoneUsageDescription` in `gui/MacOSXBundleInfo.plist.in`, `macMicPermission.m`, stream session |
| User-picked files | `com.apple.security.files.user-selected.read-write` | Profile import/export and similar `QFileDialog` flows in `gui/src/qmlsettings.cpp` |

**Often needed later (not in baseline plist):** multicast / local-network–related capabilities for UPnP/SSDP (`lib/src/remote/holepunch.c`) or Bonjour-style discovery. Add only after testing a sandbox-signed build; enable matching capabilities on the App ID in the developer portal.

**WebEngine:** App Store sets `CHIAKI_ENABLE_GUI_WEBENGINE=OFF` (same variable Linux uses via `CMAKE_SYSTEM_NAME`). DMG builds default to ON on macOS/Windows.

## How to add or change entitlements

1. Edit [entitlements.plist](entitlements.plist) in this directory.
2. In **Identifiers →** your Mac app ID → **Capabilities**, enable the same capabilities Apple associates with those entitlements.
3. Regenerate or refresh **provisioning** if you use profiles; signing must allow the entitlements blob.
4. Re-run `./macos/build-appstore.sh` and re-upload the PKG.

## App Review (summary)

1. **App Store Connect**: macOS app record, new version, metadata, screenshots, support URL, privacy policy, **Privacy Nutrition Labels**, export compliance, sign-in notes if users authenticate to third-party services.
2. **Upload** the signed PKG; wait for processing.
3. **Attach** the build to the version and **submit for review**.
4. Apple may request demo accounts, videos, or clarification on remote streaming and network use.

Rejections are often sandbox violations, missing usage strings, or metadata that does not match behavior—iterate and resubmit.

## Files

| File | Purpose |
|------|---------|
| [entitlements.plist](entitlements.plist) | Sandbox entitlements for MAS builds |
| [secrets/macos/credentials.env.example](../../secrets/macos/credentials.env.example) | Tracked template → copy to `secrets/macos/credentials.env` |
| [../build-appstore.sh](../build-appstore.sh) | Entry script: build signed app + signed `.pkg` |
