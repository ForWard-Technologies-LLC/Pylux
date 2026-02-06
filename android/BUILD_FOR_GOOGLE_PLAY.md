# Building Pylux for Google Play Store

This guide explains how to build an Android App Bundle (AAB) for uploading to Google Play Console.

## Prerequisites

### 1. Create a Release Keystore (One-time setup)

If you don't already have a keystore, create one:

```powershell
cd c:\Users\User\repos\chiaki-ng\android
keytool -genkey -v -keystore chiaki-release.keystore -alias chiaki -keyalg RSA -keysize 2048 -validity 10000
```

**IMPORTANT**: Save the passwords you create! You'll need them for every release.

### 2. Configure Signing (One-time setup)

Edit `android/local.properties` and add your keystore details:

```properties
chiakiKeystore=chiaki-release.keystore
chiakiKeystorePW=YOUR_KEYSTORE_PASSWORD
chiakiKeyAlias=chiaki
chiakiKeyPW=YOUR_KEY_PASSWORD
```

Replace `YOUR_KEYSTORE_PASSWORD` and `YOUR_KEY_PASSWORD` with your actual passwords.

## Building for Production

### Quick Command

To build a signed AAB for Google Play:

```powershell
cd c:\Users\User\repos\chiaki-ng\android
.\build.ps1 release -bundle
```

This will:
- Build a **release** version
- Create an **AAB** (Android App Bundle) instead of APK
- Sign it with your release keystore
- Build for **all ABIs** (arm64-v8a, armeabi-v7a, x86, x86_64)

### Output Location

The signed AAB will be located at:
```
android\app\build\outputs\bundle\release\app-release.aab
```

This file is ready to upload to Google Play Console!

## Build Options

- `.\build.ps1 release -bundle` - Full production build with all ABIs (recommended for Google Play)
- `.\build.ps1 release -bundle -clean` - Clean build (removes all cached artifacts first)
- `.\build.ps1 debug -bundle` - Debug AAB (for testing Play Store features locally)

## For Local Development

For faster local development builds (APK only, single ABI):

```powershell
.\build.ps1 debug -quick
```

This builds only arm64-v8a and skips tests/linting.

## Uploading to Google Play

1. Build the release AAB: `.\build.ps1 release -bundle`
2. Go to [Google Play Console](https://play.google.com/console)
3. Select your app
4. Go to "Release" → "Production" (or "Internal testing" for testing)
5. Click "Create new release"
6. Upload `app-release.aab`
7. Fill in release notes and submit for review

## Incrementing Version

Before each release, update the version in:
- `CMakeLists.txt` (root) - Update `CHIAKI_VERSION_MAJOR/MINOR/PATCH`
- `android/app/build.gradle` - Increment `versionCode`

The version name is automatically read from CMakeLists.txt.

## Troubleshooting

### "Signing not enabled" message
- Check that `local.properties` has all four signing properties configured
- Verify the keystore file path is correct

### Build fails with signing error
- Verify passwords in `local.properties` are correct
- Ensure keystore file exists at the specified path

### AAB file not found
- Check `android\app\build\outputs\bundle\release\` directory
- Review build output in `build-output.txt` for errors

## Security Notes

- **NEVER** commit `local.properties` to git (it's already in .gitignore)
- **NEVER** commit your keystore file to git
- Keep backups of your keystore in a secure location
- If you lose your keystore, you cannot update your app on Google Play!
