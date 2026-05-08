#!/bin/bash
# Build Pylux for Mac App Store: signed .app (sandbox entitlements) + signed .pkg for Transporter.
#
# Prerequisites: same as scripts/build-macos.sh (Xcode CLI tools, Homebrew, Qt@6, etc.).
# On Apple Silicon, default is arm64-only. Universal needs x86_64 deps on the same machine
# (e.g. /usr/local Rosetta Homebrew) or build universal on CI — set PYLUX_MAC_APPSTORE_UNIVERSAL=1.
#
# Credentials: secrets/macos/credentials.env only (same file as scripts/build-macos.sh).
#   MACOS_APPSTORE_APPLICATION_SIGN_ID — Apple Distribution / Mac App Developer Application (NOT Developer ID)
#   MACOS_APPSTORE_INSTALLER_SIGN_ID  — Mac App Installer identity (for productbuild)
#   MACOS_APPSTORE_PROVISIONING_PROFILE — path to Mac App Store .provisionprofile (required for TestFlight / ASC)
#
# Usage (from repo root):
#   ./macos/build-appstore.sh              # incremental build + .pkg (arm64 on Apple Silicon)
#   ./macos/build-appstore.sh --ship       # build .pkg then upload via Fastlane to App Store Connect
#   PYLUX_MAC_APPSTORE_UNIVERSAL=1 ./macos/build-appstore.sh   # universal (local needs x86_64 brew stack)
#   ./macos/build-appstore.sh --clean      # clean artifacts first, then build as above
#   ./macos/build-appstore.sh clean        # only remove App Store cmake/products (no build)
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_CREDS="$REPO_ROOT/secrets/macos/credentials.env"
ENTITLEMENTS="$SCRIPT_DIR/appstore/entitlements.plist"
BUILD_OUTPUT_DIR="$REPO_ROOT/build-output"
PKG_OUT="$BUILD_OUTPUT_DIR/Pylux-appstore.pkg"

appstore_clean() {
	echo "=== Cleaning App Store / macOS CMake artifacts ==="
	for d in "$REPO_ROOT/build-arm64" "$REPO_ROOT/build-x86_64" "$REPO_ROOT/build-universal"; do
		if [[ -d "$d" ]]; then
			echo "  rm -rf $d"
			rm -rf "$d"
		fi
	done
	for f in "$BUILD_OUTPUT_DIR/Pylux.app" "$BUILD_OUTPUT_DIR/Pylux-appstore.pkg" "$BUILD_OUTPUT_DIR/Pylux.dmg"; do
		if [[ -e "$f" ]]; then
			echo "  rm -rf $f"
			rm -rf "$f"
		fi
	done
	echo "  (left build-output/MoltenVK* cache if present)"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "This script must run on macOS."
	exit 1
fi

if [[ "${1:-}" == "clean" ]]; then
	if [[ $# -ne 1 ]]; then
		echo "Usage: $0 clean"
		echo "  Removes build-arm64, build-x86_64, build-universal and Pylux.app / Pylux-appstore.pkg / Pylux.dmg"
		exit 1
	fi
	appstore_clean
	exit 0
fi

DO_CLEAN=false
DO_SHIP=false
for arg in "$@"; do
	case "$arg" in
		--clean) DO_CLEAN=true ;;
		--ship) DO_SHIP=true ;;
		*)
			echo "Unknown option: $arg"
			echo "Usage: $0 [--clean] [--ship]   |   $0 clean"
			exit 1
			;;
	esac
done

if [[ "$DO_CLEAN" == true ]]; then
	appstore_clean
	echo ""
fi

if [ ! -f "$ENTITLEMENTS" ]; then
	echo "Missing entitlements: $ENTITLEMENTS"
	exit 1
fi

if [ ! -f "$SECRETS_CREDS" ]; then
	echo "Missing $SECRETS_CREDS"
	echo "  cp secrets/macos/credentials.env.example secrets/macos/credentials.env"
	echo "  Then uncomment and fill in values (standalone + Mac App Store sections as needed)."
	exit 1
fi

# shellcheck disable=SC1090
set -a
source "$SECRETS_CREDS"
set +a

if [ -z "${MACOS_APPSTORE_APPLICATION_SIGN_ID:-}" ]; then
	echo "MACOS_APPSTORE_APPLICATION_SIGN_ID is not set in $SECRETS_CREDS"
	echo "  Add the Mac App Store *application* identity (Apple Distribution / Mac App Developer Application)."
	echo "  security find-identity -v -p codesigning"
	exit 1
fi

if [[ "$MACOS_APPSTORE_APPLICATION_SIGN_ID" == *"Developer ID Application"* ]]; then
	echo "ERROR: MACOS_APPSTORE_APPLICATION_SIGN_ID must not be Developer ID Application."
	echo "Use Apple Distribution (or 3rd Party Mac Developer Application) for App Store uploads."
	exit 1
fi

if [ -z "${MACOS_APPSTORE_INSTALLER_SIGN_ID:-}" ]; then
	echo "MACOS_APPSTORE_INSTALLER_SIGN_ID is not set in $SECRETS_CREDS"
	echo "  Add the Mac App *Installer* identity for signing the .pkg."
	echo "  security find-identity -v -p codesigning"
	exit 1
fi

if [ -z "${MACOS_APPSTORE_PROVISIONING_PROFILE:-}" ]; then
	echo ""
	echo "MACOS_APPSTORE_PROVISIONING_PROFILE is not set in $SECRETS_CREDS"
	echo "  Download a Mac App Store provisioning profile for this app’s bundle ID from the developer portal,"
	echo "  then set MACOS_APPSTORE_PROVISIONING_PROFILE to the .provisionprofile file path."
	exit 1
fi
if [ ! -f "$MACOS_APPSTORE_PROVISIONING_PROFILE" ]; then
	echo "Provisioning profile not found: $MACOS_APPSTORE_PROVISIONING_PROFILE"
	exit 1
fi

# TestFlight (90886): signature entitlements must include the same application-identifier as the profile.
WORKDIR="$(mktemp -d -t pylux-appstore)"
cleanup_workdir() { rm -rf "$WORKDIR"; }
trap cleanup_workdir EXIT

MERGED_ENTITLEMENTS="$WORKDIR/merged-entitlements.plist"
PROFILE_PLIST="$WORKDIR/profile.plist"

security cms -D -i "$MACOS_APPSTORE_PROVISIONING_PROFILE" > "$PROFILE_PLIST" 2>/dev/null || {
	echo "ERROR: Could not decode provisioning profile (security cms -D failed)."
	exit 1
}
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
if [[ -z "$PROFILE_APP_ID" || -z "$PROFILE_TEAM" ]]; then
	echo "ERROR: Provisioning profile is missing Entitlements:com.apple.application-identifier or com.apple.developer.team-identifier."
	echo "  Use a Mac App Store Connect distribution profile for this app."
	exit 1
fi

# application-identifier is TEAM.bundleID; bundle ID may contain dots — strip team prefix (first segment only).
PROFILE_BUNDLE_ID="${PROFILE_APP_ID#"${PROFILE_TEAM}".}"
if [[ "$PROFILE_BUNDLE_ID" == "$PROFILE_APP_ID" ]]; then
	echo "ERROR: application-identifier in profile ($PROFILE_APP_ID) does not start with team id $PROFILE_TEAM."
	exit 1
fi

cp "$ENTITLEMENTS" "$MERGED_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$MERGED_ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$MERGED_ENTITLEMENTS" 2>/dev/null || true
# Quote values for PlistBuddy (bundle IDs and team IDs are alphanumeric + dots only).
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string '${PROFILE_APP_ID}'" "$MERGED_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string '${PROFILE_TEAM}'" "$MERGED_ENTITLEMENTS"
echo "  Merged application-identifier + team-identifier from provisioning profile into entitlements for codesign."

export MACOS_SIGN_ID="$MACOS_APPSTORE_APPLICATION_SIGN_ID"
export PYLUX_ENTITLEMENTS="$MERGED_ENTITLEMENTS"
# Steamworks is already off in build-macos.sh; Steam *shortcut* defaults ON — disable for store builds.
# No Qt WebEngine: same CMake flag as Linux; PSN uses external browser (MAS / no QtWebEngineProcess).
export PYLUX_EXTRA_CMAKE_ARGS="-DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_GUI_WEBENGINE=OFF -DCHIAKI_IS_MAC_APPSTORE=ON"

BUILD_ARCH="universal"
if [[ "$(uname -m)" == "arm64" ]] && [[ "${PYLUX_MAC_APPSTORE_UNIVERSAL:-}" != "1" ]]; then
	BUILD_ARCH="arm64"
	echo "Host is arm64: using BUILD_ARCH=$BUILD_ARCH (set PYLUX_MAC_APPSTORE_UNIVERSAL=1 for universal)."
else
	echo "App Store build architecture: $BUILD_ARCH"
fi

echo "=== Building signed app (no DMG / no notarization) ==="
"$REPO_ROOT/scripts/build-macos.sh" "$BUILD_ARCH" \
	--no-notarize \
	--skip-dmg-notarize \
	--skip-notary-keychain \
	--no-credentials-file

APP="$BUILD_OUTPUT_DIR/Pylux.app"
if [ ! -d "$APP" ]; then
	echo "Expected app bundle not found: $APP"
	exit 1
fi

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$APP_BUNDLE_ID" ]]; then
	echo "ERROR: Could not read CFBundleIdentifier from $APP/Contents/Info.plist"
	exit 1
fi
if [[ "$APP_BUNDLE_ID" != "$PROFILE_BUNDLE_ID" ]]; then
	echo "ERROR: Built app CFBundleIdentifier ($APP_BUNDLE_ID) does not match the Mac App Store profile App ID ($PROFILE_BUNDLE_ID)."
	echo "  Regenerate the profile for this bundle ID, or align gui/CMakeLists.txt MACOSX_BUNDLE_GUI_IDENTIFIER with the portal."
	exit 1
fi

echo ""
echo "=== Embedding Mac App Store provisioning profile ==="
cp "$MACOS_APPSTORE_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
echo "  Re-signing app bundle after embedding profile (same entitlements as build, including application-identifier)..."
codesign --force --timestamp --options runtime \
	--entitlements "$MERGED_ENTITLEMENTS" \
	--sign "$MACOS_APPSTORE_APPLICATION_SIGN_ID" \
	"$APP"
codesign --verify --verbose=2 "$APP" || {
	echo "ERROR: codesign --verify failed after embedding provisioning profile."
	exit 1
}

echo ""
echo "=== Creating signed installer package ==="
rm -f "$PKG_OUT"
productbuild --component "$APP" /Applications --sign "$MACOS_APPSTORE_INSTALLER_SIGN_ID" "$PKG_OUT"

echo ""
echo "=== Done ==="
echo "  PKG: $PKG_OUT"

if [[ "$DO_SHIP" == true ]]; then
	echo ""
	echo "=== Uploading to App Store Connect via Fastlane ==="
	if ! command -v fastlane &>/dev/null; then
		echo "Installing Fastlane..."
		brew install fastlane
	fi

	export PYLUX_PKG_PATH="$PKG_OUT"

	IOS_CREDS="$REPO_ROOT/secrets/ios/credentials.env"
	if [[ -z "${APP_STORE_CONNECT_API_KEY_KEY_ID:-}" && -f "$IOS_CREDS" ]]; then
		echo "  Sourcing App Store Connect API key from $IOS_CREDS"
		set -a; source "$IOS_CREDS"; set +a
	fi

	if [[ -z "${APP_STORE_CONNECT_API_KEY_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_KEY_ISSUER_ID:-}" ]]; then
		echo "ERROR: APP_STORE_CONNECT_API_KEY_KEY_ID / APP_STORE_CONNECT_API_KEY_ISSUER_ID not set."
		echo "  Add them to secrets/ios/credentials.env or secrets/macos/credentials.env."
		exit 1
	fi

	if [[ -z "${APP_STORE_CONNECT_API_KEY_KEY_FILEPATH:-}" ]]; then
		ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_KEY_ID}"

		if [[ -n "${APP_STORE_CONNECT_API_KEY_KEY_BASE64:-}" ]]; then
			SHIP_TMPDIR="$(mktemp -d -t pylux-ship)"
			_cleanup_ship() { rm -rf "$SHIP_TMPDIR"; }
			trap _cleanup_ship EXIT
			DECODED_KEY="$SHIP_TMPDIR/AuthKey_${ASC_KEY_ID}.p8"
			echo "$APP_STORE_CONNECT_API_KEY_KEY_BASE64" > "$SHIP_TMPDIR/key.b64"
			base64 -D -i "$SHIP_TMPDIR/key.b64" -o "$DECODED_KEY"
			rm -f "$SHIP_TMPDIR/key.b64"
			export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH="$DECODED_KEY"
			echo "  Decoded .p8 key from APP_STORE_CONNECT_API_KEY_KEY_BASE64"
		else
			echo "ERROR: APP_STORE_CONNECT_API_KEY_KEY_BASE64 is not set."
			echo "  Add it to secrets/ios/credentials.env or secrets/macos/credentials.env."
			echo ""
			echo "  (File-based fallback is disabled to match CI behavior.)"
			# Uncomment below to fall back to .p8 files on disk:
			# for candidate in \
			#     "$REPO_ROOT/secrets/ios/AuthKey_${ASC_KEY_ID}.p8" \
			#     "$HOME/Downloads/AuthKey_${ASC_KEY_ID}.p8"; do
			#     if [[ -f "$candidate" ]]; then
			#         export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH="$candidate"
			#         echo "  Using .p8 file: $candidate"
			#         break
			#     fi
			# done
			# if [[ -z "${APP_STORE_CONNECT_API_KEY_KEY_FILEPATH:-}" ]]; then
			exit 1
			# fi
		fi
	fi

	cd "$SCRIPT_DIR"
	fastlane upload_pylux_pkg
	cd "$REPO_ROOT"
else
	echo "  Next: ./macos/build-appstore.sh --ship   (uploads via Fastlane)"
	echo "    or: Transporter → upload PKG; App Store Connect → attach build to macOS version."
fi
echo "  See: macos/appstore/README.md"
