# Building the Android App Yourself

!!! Warning "For Advanced Users Only"

    This is for advanced users who are comfortable going through the Android build process themselves. For regular users, please install using the [Installation Section](../setup/installation.md){target="_blank" rel="noopener"}.

## Prerequisites

1. **Java Development Kit (JDK) 8 or higher**
   - If you have Android Studio installed, it includes a bundled JDK
   - Android Studio's JDK is typically located at:
     - **Windows**: `C:\Program Files\Android\Android Studio\jbr` or `%LOCALAPPDATA%\Android\Android Studio\jbr`
     - **macOS**: `/Applications/Android Studio.app/Contents/jbr`
     - **Linux**: `~/android-studio/jbr` or `/opt/android-studio/jbr`
   - You can also use a system-wide JDK if installed
   - Set `JAVA_HOME` environment variable to point to your JDK installation

2. **Android Studio** (recommended)
   - If you already have Android Studio installed, you can use it directly
   - The Android SDK is typically located at:
     - **Windows**: `%LOCALAPPDATA%\Android\Sdk` or `%USERPROFILE%\AppData\Local\Android\Sdk`
     - **macOS**: `~/Library/Android/sdk`
     - **Linux**: `~/Android/Sdk`

3. **Android SDK Components** (verify these are installed)
   - Android SDK Platform 30 (or higher)
   - Android SDK Build-Tools 30.0.2 (or higher)
   - Android NDK (any recent version)
   - CMake 3.10.2 or higher
   - You can check/install these via Android Studio: **Tools → SDK Manager**

4. **Environment Variables** (optional but recommended)
   - `ANDROID_HOME` or `ANDROID_SDK_ROOT` - path to your Android SDK
   - `ANDROID_NDK_HOME` - path to your Android NDK (if not in SDK/ndk-bundle)
   - `JAVA_HOME` - path to your JDK installation

## Setup

### 1. Find Your Existing Android SDK Path

If you have Android Studio installed, find your SDK location:

**Windows:**
```powershell
# Check common locations
$env:LOCALAPPDATA\Android\Sdk
$env:USERPROFILE\AppData\Local\Android\Sdk
```

**macOS/Linux:**
```bash
# Check common locations
echo $HOME/Library/Android/sdk  # macOS
echo $HOME/Android/Sdk          # Linux
```

Or in Android Studio: **Tools → SDK Manager** - the SDK path is shown at the top.

### 2. Verify Android SDK Components

Open Android Studio and go to **Tools → SDK Manager** to verify you have:
- Android SDK Platform 30 (or higher)
- Android SDK Build-Tools 30.0.2 (or higher)
- NDK (Side by side) - any recent version
- CMake 3.10.2 or higher

Install any missing components.

### 3. Configure local.properties

Create `android/local.properties` file with your Android SDK path:

**Windows (PowerShell):**
```powershell
# Find your SDK path
$sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
if (-not (Test-Path $sdkPath)) {
    $sdkPath = "$env:USERPROFILE\AppData\Local\Android\Sdk"
}

# Create local.properties
$content = "sdk.dir=$($sdkPath -replace '\\', '\\')"
$content | Out-File -FilePath "android\local.properties" -Encoding utf8
```

**Windows (Manual):**
Create `android/local.properties` with:
```properties
sdk.dir=C\:\\Users\\YourUsername\\AppData\\Local\\Android\\Sdk
```
(Replace `YourUsername` with your actual username, and escape backslashes)

**macOS/Linux:**
```bash
# Find your SDK path
SDK_PATH="$HOME/Library/Android/sdk"  # macOS
# or
SDK_PATH="$HOME/Android/Sdk"           # Linux

# Create local.properties
echo "sdk.dir=$SDK_PATH" > android/local.properties
```

**Or manually create** `android/local.properties`:
```properties
sdk.dir=/Users/yourusername/Library/Android/sdk
```
(Replace with your actual path)

### 4. Set JAVA_HOME (if needed)

If Gradle can't find Java automatically, set `JAVA_HOME`:

**Windows (PowerShell):**
```powershell
# Use Android Studio's bundled JDK
$env:JAVA_HOME = "$env:LOCALAPPDATA\Android\Android Studio\jbr"
# Or if that doesn't exist:
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"

# Make it permanent (optional)
[System.Environment]::SetEnvironmentVariable('JAVA_HOME', $env:JAVA_HOME, 'User')
```

**macOS/Linux:**
```bash
# Use Android Studio's bundled JDK
export JAVA_HOME="$HOME/Library/Application Support/Google/AndroidStudio*/jbr"  # macOS
# or
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr"  # macOS alternative
# or
export JAVA_HOME="$HOME/android-studio/jbr"  # Linux

# Make it permanent (add to ~/.bashrc or ~/.zshrc)
echo 'export JAVA_HOME="..."' >> ~/.bashrc
```

### 5. Configure Signing (Optional, for Release Builds)

If you want to sign your release builds, create or edit `android/local.properties` and add:

```properties
chiakiKeystore=/path/to/your/keystore.jks
chiakiKeystorePW=your_keystore_password
chiakiKeyAlias=your_key_alias
chiakiKeyPW=your_key_password
```

If signing is not configured, the build will still work but you'll get unsigned APKs.

## Building

### Using Command Line

1. Navigate to the android directory:
```bash
cd android
```

2. **First-time setup**: The Gradle wrapper will download Gradle automatically (no need to install separately)

3. Build a debug APK:
```bash
# On Linux/Mac
./gradlew assembleDebug

# On Windows (PowerShell or CMD)
.\gradlew.bat assembleDebug
```

4. Build a release APK:
```bash
# On Linux/Mac
./gradlew assembleRelease

# On Windows
.\gradlew.bat assembleRelease
```

5. Build an Android App Bundle (AAB) for Google Play:
```bash
# On Linux/Mac
./gradlew bundleRelease

# On Windows
.\gradlew.bat bundleRelease
```

6. Build both APK and AAB:
```bash
# On Linux/Mac
./gradlew assembleRelease bundleRelease

# On Windows
.\gradlew.bat assembleRelease bundleRelease
```

### Output Locations

- **Debug APK**: `android/app/build/outputs/apk/debug/app-debug.apk`
- **Release APK**: `android/app/build/outputs/apk/release/app-release-unsigned.apk` (or signed if configured)
- **Release AAB**: `android/app/build/outputs/bundle/release/app-release.aab`

### Using Android Studio

1. Open Android Studio
2. Select **File → Open**
3. Navigate to the `android` directory in the Pylux repository
4. Click **OK** and wait for Gradle sync to complete
5. Select **Build → Make Project** or **Build → Build Bundle(s) / APK(s) → Build APK(s)**

## Troubleshooting

### Java Not Found

If you get an error about Java not being found:
- **If you have Android Studio**: Use its bundled JDK (see Setup step 4 above)
- Set `JAVA_HOME` environment variable to point to your JDK
- On Windows, you may need to add Java to your PATH, or use Android Studio's bundled JDK:
  ```powershell
  $env:JAVA_HOME = "$env:LOCALAPPDATA\Android\Android Studio\jbr"
  $env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
  ```

### Android SDK Not Found

If Gradle can't find the Android SDK:
- **Find your SDK path** (see Setup step 1 above)
- Create `android/local.properties` with `sdk.dir` pointing to your SDK
- Or set `ANDROID_HOME` or `ANDROID_SDK_ROOT` environment variable:
  ```powershell
  # Windows
  $env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
  ```
  ```bash
  # macOS/Linux
  export ANDROID_HOME="$HOME/Library/Android/sdk"  # macOS
  export ANDROID_HOME="$HOME/Android/Sdk"           # Linux
  ```

### Build Fails with Dependency Errors

If you encounter dependency resolution errors:
- Ensure you have internet connection
- Try running `./gradlew --refresh-dependencies` to refresh cached dependencies
- Check that `mavenCentral()` is accessible (jcenter has been replaced with mavenCentral)

### NDK Not Found

If CMake can't find the NDK:
- Install NDK via Android Studio SDK Manager or `sdkmanager "ndk-bundle"`
- Set `ANDROID_NDK_HOME` environment variable if NDK is in a custom location

### Out of Memory Errors

If you get out of memory errors during build:
- Increase Gradle daemon memory in `android/gradle.properties`:
  ```
  org.gradle.jvmargs=-Xmx2048m
  ```

## Building for Different Architectures

The build automatically includes all supported ABIs:
- armeabi-v7a (32-bit ARM)
- arm64-v8a (64-bit ARM)
- x86 (32-bit x86)
- x86_64 (64-bit x86)

To build for specific architectures only, modify `android/app/build.gradle` and add `abiFilters` to the `cmake` block in `externalNativeBuild`.

