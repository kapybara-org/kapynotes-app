#!/usr/bin/env bash
#
# Captures the real Android app at exact source aspect ratios for the Play
# Store phone, 7-inch tablet, and 10-inch tablet screenshot sets.
#
# Usage: packaging/android_screenshots.sh [phone|tablet-7|tablet-10|all]
#
# A running Android emulator is required. Build the debug APK first with:
#   flutter build apk --debug

set -euo pipefail

cd "$(dirname "$0")/.."
APP_ROOT="$PWD"
ADB="${ADB:-/Users/sanjay/Library/Android/sdk/platform-tools/adb}"
APP_ID="com.kapybara.kapynotes"
ACTIVITY="$APP_ID/.MainActivity"
APK="$APP_ROOT/build/app/outputs/flutter-apk/app-debug.apk"
OUT="$APP_ROOT/build/screenshots"
CAPTURE_TMP="$(mktemp -d)"
TARGET="${1:-all}"

trap 'rm -r -- "$CAPTURE_TMP"' EXIT

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

if [[ ! -x "$ADB" ]]; then
  printf 'adb not found: %s\n' "$ADB" >&2
  exit 1
fi

if [[ ! -f "$APK" ]]; then
  printf 'debug APK not found: %s\n' "$APK" >&2
  exit 1
fi

if ! "$ADB" get-state >/dev/null 2>&1; then
  printf 'no running Android emulator or device found\n' >&2
  exit 1
fi

seed() {
  local selected="$1" layout="$2"
  local local_seed="$CAPTURE_TMP/kapy-notes.json"

  SEED_SELECTED="$selected" SEED_LAYOUT="$layout" \
    python3 "$APP_ROOT/packaging/screenshot_seed.py" > "$local_seed"
  "$ADB" push "$local_seed" /data/local/tmp/kapy-notes.json >/dev/null
  "$ADB" shell run-as "$APP_ID" \
    cp /data/local/tmp/kapy-notes.json files/kapy-notes.json
}

set_appearance() {
  local appearance="$1"
  if [[ "$appearance" == "dark" ]]; then
    "$ADB" shell cmd uimode night yes >/dev/null
  else
    "$ADB" shell cmd uimode night no >/dev/null
  fi
}

clean_status_bar() {
  # Android 15's emulator demo-mode controller is unstable across repeated
  # size/density changes. This supported shell flag only hides notification
  # icons and leaves the normal clock, network, and battery state intact.
  "$ADB" shell cmd statusbar send-disable-flag notification-icons >/dev/null
}

ime_is_visible() {
  "$ADB" shell dumpsys input_method | grep -q 'mInputShown=true'
}

hide_startup_keyboard() {
  local name="$1"
  local attempt poll
  # NoteEditor retries its first IME request while FlutterView becomes the
  # served input view. Wait through that window, then dismiss only when the
  # system confirms the keyboard is actually visible.
  sleep 8
  for attempt in 1 2 3 4 5 6 7 8; do
    if ime_is_visible; then
      "$ADB" shell input keyevent 4 >/dev/null
      for poll in 1 2 3 4 5 6 7 8; do
        ime_is_visible || break
        sleep 0.25
      done
      sleep 1
      ime_is_visible || return 0
    else
      sleep 0.5
    fi
  done

  if ime_is_visible; then
    printf 'software keyboard would be visible in %s\n' "$name" >&2
    return 1
  fi
}

assert_capture_ready() {
  local name="$1"
  if "$ADB" shell dumpsys activity activities | grep -q \
    'mCurrentFocus=.*Application Not Responding'; then
    printf 'system ANR dialog would be visible in %s\n' "$name" >&2
    return 1
  fi
  if ime_is_visible; then
    printf 'software keyboard would be visible in %s\n' "$name" >&2
    return 1
  fi
}

shoot() {
  local dir="$1" name="$2" selected="$3" appearance="$4" layout="$5" scroll_x="$6"

  "$ADB" shell am force-stop "$APP_ID"
  set_appearance "$appearance"
  seed "$selected" "$layout"
  "$ADB" shell am start -W -n "$ACTIVITY" >/dev/null
  clean_status_bar
  hide_startup_keyboard "$name"
  # The focused editor opens at the end of the note. Return it to the top so
  # the title and the complete note story are both visible.
  for _ in 1 2 3 4 5; do
    "$ADB" shell input swipe "$scroll_x" 500 "$scroll_x" 1500 180 >/dev/null
  done
  clean_status_bar
  sleep 1
  assert_capture_ready "$name"
  "$ADB" exec-out screencap -p > "$dir/$name.png"
  printf '    %s.png  ' "$name"
  python3 - "$dir/$name.png" <<'PY'
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
with path.open('rb') as source:
    signature = source.read(24)
width, height = struct.unpack('>II', signature[16:24])
print(f'{width} x {height}')
PY
}

capture_profile() {
  local label="$1" folder="$2" size="$3" density="$4" layout="$5" scroll_x="$6"
  local dir="$OUT/$folder"

  info "$label -> $dir"
  mkdir -p "$dir"
  "$ADB" shell wm size "$size" >/dev/null
  "$ADB" shell wm density "$density" >/dev/null

  shoot "$dir" "1-live-calculator" math light "$layout" "$scroll_x"
  shoot "$dir" "2-notes" notes light "$layout" "$scroll_x"
  shoot "$dir" "3-checklist" checklist light "$layout" "$scroll_x"
  shoot "$dir" "4-journal" journal dark "$layout" "$scroll_x"
  shoot "$dir" "5-recipe" recipe light "$layout" "$scroll_x"
}

info "Installing current debug APK"
"$ADB" install -r "$APK" >/dev/null
"$ADB" shell am start -W -n "$ACTIVITY" >/dev/null
sleep 1
"$ADB" shell am force-stop "$APP_ID"

# Keep ordinary emulator notifications out of the status bar without entering
# the Android 15 demo mode that becomes unstable after display-size changes.
clean_status_bar

case "$TARGET" in
  phone)
    capture_profile "Play phone" "android-phone" "1080x1920" 360 phone 300
    ;;
  tablet-7)
    capture_profile "Play 7-inch tablet" "android-tablet-7" "1200x1920" 280 android-tablet 700
    ;;
  tablet-10)
    capture_profile "Play 10-inch tablet" "android-tablet-10" "1600x2560" 320 android-tablet 800
    ;;
  all)
    capture_profile "Play phone" "android-phone" "1080x1920" 360 phone 300
    capture_profile "Play 7-inch tablet" "android-tablet-7" "1200x1920" 280 android-tablet 700
    capture_profile "Play 10-inch tablet" "android-tablet-10" "1600x2560" 320 android-tablet 800
    ;;
  *)
    printf 'usage: packaging/android_screenshots.sh [phone|tablet-7|tablet-10|all]\n' >&2
    exit 2
    ;;
esac

"$ADB" shell cmd uimode night no >/dev/null
"$ADB" shell wm size reset >/dev/null
"$ADB" shell wm density reset >/dev/null
"$ADB" shell cmd statusbar send-disable-flag none >/dev/null

info "Android screenshots in $OUT"
