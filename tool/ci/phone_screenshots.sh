#!/bin/bash
# The phone integration tests under flutter drive on one device, with their
# screenshots saved to build/screenshots:
#
#   bash tool/ci/phone_screenshots.sh <device id>
#
# A shot a test takes with device: true is also read off the device's own
# screen, keyboard included, as build/screenshots/<name>-device.png.
#
# On an Android device, phone_bar_android runs last, with the system's
# navigation switched to three buttons for it and back afterwards, so the bar
# is seen clear of those buttons too.
#
# Every test file runs even when one fails, and the script exits 1 if any did.
# A test that hangs is stopped after 10 minutes, with a screenshot of where.
set -u

device=$1
status=0
export KAPYNOTES_DEVICE_SHOTS=$device

drive() {
  flutter drive --no-pub -d "$device" \
    --driver test_driver/integration_test.dart \
    --target "integration_test/$1_test.dart" \
    --dart-define=KAPYNOTES_SYNC=false \
    --dart-define=KAPYNOTES_DEVICE_SHOTS="$device" \
    --timeout=600 --screenshot=build/screenshots || status=1
}

navbar() {
  adb -s "$device" shell cmd overlay enable-exclusive --category \
    "com.android.internal.systemui.navbar.$1"
  sleep 3
}

for test in phone_v2 phone_format_bar phone_home kapy_ai_page phone_tasks; do
  drive "$test"
done

if adb -s "$device" get-state >/dev/null 2>&1; then
  mode=$(adb -s "$device" shell settings get secure navigation_mode | tr -d '\r')
  navbar threebutton
  drive phone_bar_android
  case "$mode" in
    1) navbar twobutton ;;
    2) navbar gestural ;;
  esac
fi
exit "$status"
