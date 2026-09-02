#!/usr/bin/env bash
#
# Captures App Store screenshots from the iOS simulators, at the exact pixel
# sizes App Store Connect wants for a Universal app.
#
#   iphone → build/screenshots/iphone-6.9/*.png   1320 × 2868
#   ipad   → build/screenshots/ipad-13/*.png      2064 × 2752
#
# Usage:  packaging/screenshots.sh [iphone|ipad|all]
#
# The app has no server and no screenshot mode: each scene is produced by
# writing a seeded store into the simulator's app container and relaunching.
# That keeps the shipped binary free of demo-only code.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLUTTER="${FLUTTER:-$HOME/development/flutter/bin/flutter}"
OUT="$ROOT/build/screenshots"
APP_ID="com.kapybara.kapynotes"
BUNDLE="$ROOT/build/ios/iphonesimulator/Runner.app"

IPHONE_NAME="${IPHONE_NAME:-iPhone 16 Pro Max}"
IPAD_NAME="${IPAD_NAME:-iPad Pro 13-inch (M4)}"

TARGET="${1:-all}"

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

# Newest available simulator with this exact name.
udid_for() {
  xcrun simctl list devices available --json \
    | python3 -c "
import json,sys
name = sys.argv[1]
data = json.load(sys.stdin)['devices']
for runtime in sorted(data, reverse=True):
    for device in data[runtime]:
        if device['name'] == name:
            print(device['udid'])
            raise SystemExit
raise SystemExit('no available simulator named ' + name)
" "$1"
}

build_app() {
  info "Building the simulator app"
  "$FLUTTER" build ios --simulator --debug
}

# Writes the seeded note store straight into the app's container.
seed() {
  local udid="$1" selected="$2" layout="$3"
  local container
  container="$(xcrun simctl get_app_container "$udid" "$APP_ID" data)"
  mkdir -p "$container/Library/Application Support"
  SEED_SELECTED="$selected" SEED_LAYOUT="$layout" \
    python3 "$ROOT/packaging/screenshot_seed.py" \
    > "$container/Library/Application Support/kapy-notes.json"
}

shoot() {
  local udid="$1" dir="$2" name="$3" selected="$4" appearance="$5" layout="$6"

  xcrun simctl terminate "$udid" "$APP_ID" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance "$appearance" >/dev/null
  seed "$udid" "$selected" "$layout"
  xcrun simctl launch "$udid" "$APP_ID" >/dev/null
  # The editor evaluates every line on its first frame; give it room to land.
  sleep 5
  xcrun simctl io "$udid" screenshot --type=png "$dir/$name.png" >/dev/null 2>&1
  printf '    %s.png  %s\n' "$name" \
    "$(sips -g pixelWidth -g pixelHeight "$dir/$name.png" \
       | awk '/pixel/ {printf "%s ", $2}')"
}

capture_device() {
  local name="$1" dir="$2" layout="$3"
  local udid
  udid="$(udid_for "$name")"

  info "$name → $dir"
  mkdir -p "$dir"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$BUNDLE"
  # A believable, unchanging status bar. Without this the shots carry whatever
  # time and battery the host happened to have.
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 \
    --wifiMode active --wifiBars 3 \
    --dataNetwork wifi >/dev/null

  shoot "$udid" "$dir" "1-live-calculator" math light "$layout"
  shoot "$udid" "$dir" "2-notes" notes light "$layout"
  shoot "$udid" "$dir" "3-checklist" checklist light "$layout"
  shoot "$udid" "$dir" "4-journal" journal dark "$layout"
  shoot "$udid" "$dir" "5-recipe" recipe light "$layout"

  xcrun simctl ui "$udid" appearance light >/dev/null

  # simctl writes an alpha channel; App Store Connect rejects one.
  xcrun swift "$ROOT/tool/flatten_png.swift" "$dir"/*.png
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  build_app
fi

case "$TARGET" in
  iphone) capture_device "$IPHONE_NAME" "$OUT/iphone-6.9" phone ;;
  ipad)   capture_device "$IPAD_NAME"   "$OUT/ipad-13" tablet ;;
  all)
    capture_device "$IPHONE_NAME" "$OUT/iphone-6.9" phone
    capture_device "$IPAD_NAME"   "$OUT/ipad-13" tablet
    ;;
  *) echo "usage: packaging/screenshots.sh [iphone|ipad|all]" >&2; exit 2 ;;
esac

info "Screenshots in $OUT"
