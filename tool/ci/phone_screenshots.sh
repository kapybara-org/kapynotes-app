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
# A file that is still running after PHONE_FILE_MINUTES (20 by default), such
# as an app that hangs at launch, where that 10 minutes never starts, is
# stopped with everything it started, counts as failed, and the next file runs.
set -u

device=$1
status=0
export KAPYNOTES_DEVICE_SHOTS=$device

limit=$(( ${PHONE_FILE_MINUTES:-20} * 60 ))

drive() {
  set -m
  flutter drive --no-pub -d "$device" \
    --driver test_driver/integration_test.dart \
    --target "integration_test/$1_test.dart" \
    --dart-define=KAPYNOTES_SYNC=false \
    --dart-define=KAPYNOTES_DEVICE_SHOTS="$device" \
    --timeout=600 --screenshot=build/screenshots &
  local pid=$! waited=0
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      echo "::error::$1_test.dart was still running after $(( limit / 60 )) minutes and was stopped"
      if adb -s "$device" get-state >/dev/null 2>&1; then
        adb -s "$device" exec-out screencap -p > "build/screenshots/$1-stopped.png"
      else
        xcrun simctl io "$device" screenshot "build/screenshots/$1-stopped.png" >/dev/null
      fi
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 15
      kill -KILL -- "-$pid" 2>/dev/null
      break
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  wait "$pid" || status=1
}

navbar() {
  adb -s "$device" shell cmd overlay enable-exclusive --category \
    "com.android.internal.systemui.navbar.$1"
  sleep 3
}

for test in phone_v2 phone_format_bar phone_sharing phone_home kapy_ai_page kapy_ai_sheet phone_tasks phone_note_page phone_about phone_note_swipe; do
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
