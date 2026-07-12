#!/usr/bin/env bash
# Local Android build script — mirrors .github/workflows/deploy-android.yml.
# Builds/installs the app locally and views logs without the CI signing/publish secrets.
#
# ============================ HOW TO RUN + READ LOGS (Android) ============================
# Normal loop:   ./android/build-local.sh --quick --install   # build arm64 debug APK + install + launch
# View logs:     ./android/build-local.sh --logs-dump         # one-shot dump of app logcat + exit (NEVER hangs)
# Filter:        ./android/build-local.sh --logs-dump | grep 'Catalog cache invalidated'
#
# --logs-dump reads the device's logcat ring buffer directly, so it works any time after an action --
# no capture process to start or stop. For a LONG stream session (where the ring buffer rotates) add
# --logs to also tee a continuous file, then `tail -n 200` it; stop it with --stop-logs.
# ==========================================================================================
#
# Build modes:
#   ./android/build-local.sh              # release AAB (CI parity, all ABIs)
#   ./android/build-local.sh --quick      # debug APK, arm64-v8a only (fast)
#   ./android/build-local.sh --full       # clean + rebuild all native ABIs (after lib/ changes)
#   ./android/build-local.sh --install    # install + launch APK on connected device after build
#   ./android/build-local.sh --skip-deps  # skip SDK/JDK dependency installs
# Logs:
#   ./android/build-local.sh --logs-dump  # ONE-SHOT dump of app-tagged logcat to stdout + exit (use this)
#   ./android/build-local.sh --logs       # also start a continuous background capture (pair with --install)
#   ./android/build-local.sh --stop-logs  # stop the background capture started by --logs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$REPO_ROOT/android"
SECRETS_DIR="$REPO_ROOT/secrets/android"

NDK_VERSION="28.2.13676358"
CMAKE_VERSION="3.30.4"
BUILD_TOOLS_VERSION="35.0.0"
PLATFORM="android-35"

QUICK=false
FULL_REBUILD=false
INSTALL_APK=false
SKIP_DEPS=false
CAPTURE_LOGS=false
STOP_LOGS=false
LOGS_DUMP=false
LOG_DIR="$REPO_ROOT/tmp/android-debug"
LOG_MINUTES=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --full) FULL_REBUILD=true; QUICK=false; shift ;;
    --install) INSTALL_APK=true; shift ;;
    --skip-deps) SKIP_DEPS=true; shift ;;
    --logs) CAPTURE_LOGS=true; shift ;;
    --stop-logs) STOP_LOGS=true; shift ;;
    --logs-dump) LOGS_DUMP=true; shift ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --log-minutes)
      LOG_MINUTES="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# Logcat tags captured by --logs and dumped by --logs-dump. Shared by both so they never drift.
# NOTE: keep the app-side Kotlin tags (CloudGameRepository / SecureTokenManager / Preferences /
# CloudPlayViewModel) here or catalog cache + login/logout events won't appear.
PYLUX_LOG_TAGS=(
  PSGaikaiStreaming:I
  PSGaikaiStreaming:D
  PSKamajiSession:I
  DatacenterPing:I
  StreamInput:I
  StreamInput:D
  Chiaki:I
  Chiaki:W
  Chiaki:E
  Chiaki:V
  CloudPlayFragment:I
  CloudPlayViewModel:I
  CloudGameRepository:I
  CloudGameRepository:W
  SecureTokenManager:I
  Preferences:I
  StreamActivity:I
  StreamSession:I
  AndroidRuntime:E
)

# One-shot logcat dump (adb logcat -d): prints the current ring buffer for the tags above and
# EXITS. This never streams/hangs — use it to verify events after performing an action in the app.
dump_logs() {
  local adb_bin="$1"
  "$adb_bin" wait-for-device
  "$adb_bin" logcat -d -v threadtime -s "${PYLUX_LOG_TAGS[@]}"
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

find_java_home() {
  local candidate
  for candidate in \
    "${JAVA_HOME:-}" \
    "/opt/homebrew/opt/temurin@21/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
    "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home" \
    "/Library/Java/JavaVirtualMachines/temurin-21.jre/Contents/Home" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  do
    [[ -n "$candidate" && -x "$candidate/bin/java" ]] || continue
    if "$candidate/bin/java" -version 2>&1 | grep -Eq 'version "21'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_java_21() {
  if JAVA_HOME="$(find_java_home)"; then
    export JAVA_HOME
    log "Using JDK 21 at $JAVA_HOME"
    return 0
  fi

  if ! command -v brew >/dev/null 2>&1; then
    die "JDK 21 required. Install openjdk@21 (brew install openjdk@21) or set JAVA_HOME."
  fi

  log "JDK 21 not found — installing openjdk@21 via Homebrew (no sudo)"
  brew install openjdk@21
  JAVA_HOME="$(find_java_home)" || die "JDK 21 install did not produce a usable JAVA_HOME"
  export JAVA_HOME
  log "Using JDK 21 at $JAVA_HOME"
}

find_android_sdk() {
  local candidate
  for candidate in \
    "${ANDROID_SDK_ROOT:-}" \
    "${ANDROID_HOME:-}" \
    "$HOME/Library/Android/sdk" \
    "$HOME/Android/Sdk"
  do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

find_sdkmanager() {
  local sdk_root="$1"
  local candidate
  for candidate in \
    "$sdk_root/cmdline-tools/latest/bin/sdkmanager" \
    "$sdk_root/cmdline-tools/bin/sdkmanager" \
    "$(command -v sdkmanager 2>/dev/null || true)" \
    "/opt/homebrew/bin/sdkmanager" \
    "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"
  do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done < <(find "$sdk_root/cmdline-tools" -name sdkmanager -type f 2>/dev/null | sort -r)
  return 1
}

ensure_cmdline_tools() {
  local sdk_root="$1"
  if find_sdkmanager "$sdk_root" >/dev/null; then
    return 0
  fi

  log "Android cmdline-tools not found — installing via Homebrew"
  if command -v brew >/dev/null 2>&1; then
    brew install --cask android-commandlinetools
  else
    die "Install Android cmdline-tools (brew install --cask android-commandlinetools)"
  fi

  find_sdkmanager "$sdk_root" >/dev/null || die "sdkmanager still not found after cmdline-tools install"
}

ensure_sdk_packages() {
  local sdk_root="$1"
  local sdkmanager
  sdkmanager="$(find_sdkmanager "$sdk_root")"

  log "Accepting Android SDK licenses (if needed)"
  yes | "$sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null 2>&1 || true

  local need_install=()
  [[ -d "$sdk_root/ndk/$NDK_VERSION" ]] || need_install+=("ndk;$NDK_VERSION")
  [[ -d "$sdk_root/cmake/$CMAKE_VERSION" ]] || need_install+=("cmake;$CMAKE_VERSION")
  [[ -d "$sdk_root/build-tools/$BUILD_TOOLS_VERSION" ]] || need_install+=("build-tools;$BUILD_TOOLS_VERSION")
  [[ -d "$sdk_root/platforms/$PLATFORM" ]] || need_install+=("platforms;$PLATFORM")

  if ((${#need_install[@]} == 0)); then
    log "Android SDK packages already present"
    return 0
  fi

  log "Installing missing SDK packages: ${need_install[*]}"
  yes | "$sdkmanager" --sdk_root="$sdk_root" "${need_install[@]}"
}

ensure_protobuf_tools() {
  if command -v protoc >/dev/null 2>&1; then
    log "protoc found: $(command -v protoc)"
  elif python3 -c "import grpc_tools.protoc" >/dev/null 2>&1; then
    log "Python grpc_tools.protoc available"
  else
    log "Installing protobuf compiler and Python grpc tools"
    if command -v brew >/dev/null 2>&1; then
      brew install protobuf
    fi
    python3 -m pip install --user 'protobuf>=5,<6' 'grpcio-tools>=1.60'
  fi
}

write_local_properties() {
  local sdk_root="$1"
  local props_file="$ANDROID_DIR/local.properties"

  {
    printf 'sdk.dir=%s\n' "$sdk_root"
  } > "$props_file"

  local keystore=""
  local store_pw=""
  local key_alias=""
  local key_pw=""

  if [[ -f "$SECRETS_DIR/credentials.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "$SECRETS_DIR/credentials.env"
    set +a
    store_pw="${ANDROID_KEYSTORE_PASSWORD:-}"
    key_alias="${ANDROID_KEY_ALIAS:-}"
    key_pw="${ANDROID_KEY_PASSWORD:-}"
  fi

  for candidate in \
    "$SECRETS_DIR/chiaki-release.keystore" \
    "$SECRETS_DIR/release.jks"
  do
    [[ -f "$candidate" ]] && { keystore="$candidate"; break; }
  done

  if [[ -n "$keystore" && -n "$store_pw" && -n "$key_alias" && -n "$key_pw" ]]; then
    cat >> "$props_file" <<EOF
chiakiKeystore=$keystore
chiakiKeystorePW=$store_pw
chiakiKeyAlias=$key_alias
chiakiKeyPW=$key_pw
EOF
    log "Signing configured from secrets/android/"
  else
    warn "Signing not configured — build will be unsigned (need secrets/android/credentials.env + keystore)"
  fi
}

ensure_submodules() {
  if git -C "$REPO_ROOT" submodule status --recursive | grep -q '^[-+]'; then
    log "Updating git submodules"
    git -C "$REPO_ROOT" submodule update --init --recursive
  fi
}

find_apk() {
  local kind="$1" # debug | release
  # IMPORTANT: pick the NEWEST apk by mtime, not the first directory that happens to
  # contain one. --quick (-Pandroid.injected.build.abi=...) writes the fresh APK to
  # build/intermediates/apk/<kind>/, while a stale universal APK can linger in
  # build/outputs/apk/<kind>/. Always installing the most recently built APK prevents
  # silently flashing an old binary (which previously masked code fixes during testing).
  find "$ANDROID_DIR/app/build" -name '*.apk' -path "*${kind}*" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1
}

find_aab() {
  find "$ANDROID_DIR/app/build/outputs/bundle/release" -name '*.aab' -print -quit 2>/dev/null \
    || find "$ANDROID_DIR/app/build" -name '*.aab' -print -quit 2>/dev/null
}

run_gradle() {
  local gradle_task="$1"
  shift
  (
    cd "$ANDROID_DIR"
    ./gradlew "$gradle_task" \
      --parallel \
      --no-build-cache \
      -Dorg.gradle.java.home="$JAVA_HOME" \
      "$@"
  )
}

stop_log_capture() {
  local pid_file="$LOG_DIR/capture.pid"
  [[ -f "$pid_file" ]] || { warn "No log capture pid file at $pid_file"; return 0; }
  local pid
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    log "Stopped log capture (pid $pid)"
  else
    warn "Log capture pid $pid is not running"
  fi
  rm -f "$pid_file"
}

start_log_capture() {
  local adb_bin="$1"
  mkdir -p "$LOG_DIR"
  stop_log_capture

  local ts log_file latest_file pid_file meta_file
  ts="$(date +%Y%m%d-%H%M%S)"
  log_file="$LOG_DIR/pylux-$ts.log"
  latest_file="$LOG_DIR/pylux-latest.log"
  pid_file="$LOG_DIR/capture.pid"
  meta_file="$LOG_DIR/capture.meta"

  "$adb_bin" wait-for-device
  "$adb_bin" logcat -c

  local log_tags=("${PYLUX_LOG_TAGS[@]}")

  log "Capturing logcat for ${LOG_MINUTES}m -> $log_file"
  log "  tags: ${log_tags[*]}"
  log "  grep hints: bwKbpsSent|target_bitrate|Step 13|service_type|video_profile"

  (
    "$adb_bin" logcat -v threadtime -s "${log_tags[@]}"
  ) > "$log_file" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$pid_file"
  cat > "$meta_file" <<EOF
started_at=$ts
log_file=$log_file
pid=$pid
log_minutes=$LOG_MINUTES
device=$("$adb_bin" get-serialno 2>/dev/null || echo unknown)
grep_bitrate=rg -i 'bwKbps|target_bitrate|Step 13|measured bitrate|video_profile|cloudBitrate' "$log_file"
EOF
  ln -sf "$(basename "$log_file")" "$latest_file"

  # Detach the watchdog from the terminal's stdout/stderr/stdin, otherwise a `... | tail`/`| grep`
  # on the build command would block until this subshell exits (i.e. the whole --log-minutes window).
  (
    sleep $((LOG_MINUTES * 60))
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true

  cat <<EOF

Log capture running in background (pid $pid).
  Latest:  $latest_file
  Full:    $log_file
  Meta:    $meta_file

Lib/input verification (after stream connects):
  grep -E 'STREAM_TUNING|VIDEO_RECV|FRAME_PROC|MEDIACODEC|INPUT_SETTINGS|INPUT_SELECT_MAP|DPAD_TOUCH' "$latest_file" | tail -30

Bitrate / cloud connect:
  grep -iE 'bwKbps|target_bitrate|Step 13' "$latest_file" | tail -20

Stop early:
  ./android/build-local.sh --stop-logs

EOF
}

main() {
  if [[ "$STOP_LOGS" == true ]]; then
    stop_log_capture
    exit 0
  fi
  if [[ "$LOGS_DUMP" == true ]]; then
    ANDROID_SDK_ROOT="$(find_android_sdk)" || die "Android SDK not found"
    adb_bin="$ANDROID_SDK_ROOT/platform-tools/adb"
    [[ -x "$adb_bin" ]] || die "adb not found at $adb_bin"
    dump_logs "$adb_bin"
    exit 0
  fi
  log "Pylux local Android build (CI parity)"
  log "Repo: $REPO_ROOT"

  if [[ "$SKIP_DEPS" == false ]]; then
    ensure_java_21
    ANDROID_SDK_ROOT="$(find_android_sdk)" || die "Android SDK not found. Install Android Studio or set ANDROID_SDK_ROOT."
    export ANDROID_SDK_ROOT ANDROID_HOME="$ANDROID_SDK_ROOT"
    log "Android SDK: $ANDROID_SDK_ROOT"
    ensure_cmdline_tools "$ANDROID_SDK_ROOT"
    ensure_sdk_packages "$ANDROID_SDK_ROOT"
    ensure_protobuf_tools
  else
    JAVA_HOME="$(find_java_home)" || die "JDK 21 not found (remove --skip-deps to auto-install)"
    export JAVA_HOME
    ANDROID_SDK_ROOT="$(find_android_sdk)" || die "Android SDK not found"
    export ANDROID_SDK_ROOT ANDROID_HOME="$ANDROID_SDK_ROOT"
  fi

  ensure_submodules
  write_local_properties "$ANDROID_SDK_ROOT"

  if [[ "$FULL_REBUILD" == true ]]; then
    log "Full rebuild: clean + assembleDebug (all ABIs — required after lib/ changes)"
    run_gradle clean
    run_gradle assembleDebug
    apk="$(find_apk debug || true)"
    [[ -n "$apk" ]] || die "Debug APK not found after full rebuild"
    log "Built: $apk ($(du -h "$apk" | awk '{print $1}'))"
  elif [[ "$QUICK" == true ]]; then
    log "Quick build: assembleDebug (arm64-v8a only)"
    run_gradle assembleDebug -Pandroid.injected.build.abi=arm64-v8a
    apk="$(find_apk debug || true)"
    [[ -n "$apk" ]] || die "Debug APK not found after build"
    log "Built: $apk ($(du -h "$apk" | awk '{print $1}'))"
  else
    log "Release build: bundleRelease (all ABIs — matches CI)"
    run_gradle bundleRelease
    aab="$(find_aab || true)"
    [[ -n "$aab" ]] || die "Release AAB not found after build"
    log "Built: $aab ($(du -h "$aab" | awk '{print $1}'))"
  fi

  if [[ "$INSTALL_APK" == true ]]; then
    adb_bin="$ANDROID_SDK_ROOT/platform-tools/adb"
    [[ -x "$adb_bin" ]] || die "adb not found at $adb_bin"
    apk="$(find_apk debug || find_apk release || true)"
    [[ -n "$apk" ]] || die "--install requires an APK; use --quick or assembleDebug"
    log "Installing $apk"
    "$adb_bin" install -r -t "$apk"
    "$adb_bin" shell am start -n com.pylux.stream/com.metallic.chiaki.main.MainActivity
    if [[ "$CAPTURE_LOGS" == true ]]; then
      start_log_capture "$adb_bin"
    fi
  elif [[ "$CAPTURE_LOGS" == true ]]; then
    adb_bin="$ANDROID_SDK_ROOT/platform-tools/adb"
    [[ -x "$adb_bin" ]] || die "adb not found at $adb_bin"
    start_log_capture "$adb_bin"
  fi

  echo ""
  echo "=== Android logs ==="
  echo "  VIEW LOGS (one-shot, never hangs):"
  echo "    ./android/build-local.sh --logs-dump                 # dump app-tagged ring buffer + exit"
  echo "    ./android/build-local.sh --logs-dump | grep 'Catalog cache invalidated'"
  echo "  Background capture file (--logs):  $LOG_DIR/pylux-latest.log   (read with: tail -n 200 <file>)"
  echo "  Stop background capture:           ./android/build-local.sh --stop-logs"
  echo "  Session file (device): files/session_logs/chiaki_session_*.log"
  echo "  Pull session log:    adb shell run-as com.pylux.stream cat files/session_logs/\$(adb shell run-as com.pylux.stream ls -t files/session_logs/ | head -1)"
  if [[ -f "$LOG_DIR/capture.pid" ]]; then
    echo "  Capturing:  pid $(cat "$LOG_DIR/capture.pid") -> $(readlink "$LOG_DIR/pylux-latest.log" 2>/dev/null || echo pylux-latest.log)"
  fi

  log "Done"
}

main "$@"
