iOS signing & App Store Connect

This folder stores local copies of iOS signing assets (all gitignored except this README).
GitHub Actions secrets mirror these files — see the table below.

================================================================================
Files to place in this folder
================================================================================

1. Apple Distribution certificate (.p12)
   Filename: AppleDistribution.p12  (or whatever you named it)
   Source:   Keychain Access → search "Apple Distribution" → right-click → Export Items
             Set a password when exporting.
   Note:     "Apple Distribution" certs work for BOTH iOS and macOS App Store.
             The same .p12 in secrets/macos/github-actions/ may already be this cert.

2. iOS App Store provisioning profile (.mobileprovision)
   Filename: Pylux_iOS_AppStore.mobileprovision
   Source:   https://developer.apple.com/account/resources/profiles/list
             → Create/download an "App Store Connect" profile for com.pylux.stream (iOS)
             If Xcode manages signing automatically, you can also find it at:
               ~/Library/MobileDevice/Provisioning Profiles/

3. App Store Connect API key (.p8)
   Filename: AuthKey_<your-key-id>.p8
   Source:   App Store Connect → Users and Access → Integrations → Keys
             (You can only download this once — keep a backup here)

================================================================================
GitHub Actions secrets (Settings → Secrets and variables → Actions)
================================================================================

Secret name                              How to generate
─────────────────────────────────────    ────────────────────────────────────────
IOS_CERTIFICATE_P12_BASE64              base64 -i secrets/ios/AppleDistribution.p12 | pbcopy
IOS_CERTIFICATE_PASSWORD                Password you set when exporting the .p12
IOS_PROVISIONING_PROFILE_BASE64         base64 -i secrets/ios/Pylux_iOS_AppStore.mobileprovision | pbcopy
APP_STORE_CONNECT_API_KEY_KEY_ID        <your-key-id> (from App Store Connect)
APP_STORE_CONNECT_API_KEY_ISSUER_ID     <your-issuer-id> (from App Store Connect)
APP_STORE_CONNECT_API_KEY_KEY_BASE64    base64 -i secrets/ios/AuthKey_<your-key-id>.p8 | pbcopy

================================================================================
Local build (ios/build.sh ship)
================================================================================

The local build script uses env vars, not these files directly:

  export APP_STORE_CONNECT_API_KEY_KEY_ID=<your-key-id>
  export APP_STORE_CONNECT_API_KEY_ISSUER_ID=<your-issuer-id>
  export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH=secrets/ios/AuthKey_<your-key-id>.p8

Code signing for local builds is handled by Xcode automatically (Keychain + managed profiles).

================================================================================
Notes
================================================================================

- The "Apple Distribution" cert is shared between iOS and macOS App Store builds.
  If secrets/macos/github-actions/ already has this cert as a .p12, you can
  reuse the same file and GitHub secret (IOS_CERTIFICATE_P12_BASE64 =
  MACOS_CERTIFICATE_P12_BASE64 if they are the same "Apple Distribution" identity).

- The APP_STORE_CONNECT_API_KEY_* secrets are also shared between iOS and macOS
  workflows — the same API key uploads to TestFlight for both platforms.

- Workflow file: .github/workflows/build-ios.yml
