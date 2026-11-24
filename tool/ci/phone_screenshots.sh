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
# A file that is still running after PHONE_FILE_MINUTES (20 by default; the
# first file, which pays for the cold build, PHONE_FIRST_FILE_MINUTES, 35), such
# as an app that hangs at launch, where that 10 minutes never starts, is
# stopped with everything it started, counts as failed, and the next file runs.
# PHONE_TESTS, when set, names the only tests to run, such as
# `phone_recording_away`, for a run that checks one test. A name with no
# integration_test/<name>_test.dart fails the run, so a typo that would run
# nothing can't pass.
set -u

device=$1
status=0
export KAPYNOTES_DEVICE_SHOTS=$device

limit=$(( ${PHONE_FIRST_FILE_MINUTES:-35} * 60 ))
mkdir -p build/screenshots

wanted() {
  [[ -z ${PHONE_TESTS:-} || " $PHONE_TESTS " == *" $1 "* ]]
}

for name in ${PHONE_TESTS:-}; do
  if [[ ! -f integration_test/${name}_test.dart ]]; then
    echo "::error::PHONE_TESTS names $name, which has no integration_test/${name}_test.dart"
    exit 1
  fi
done

drive() {
  wanted "$1" || return 0
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
      # The shot is put off to one side, in a group of its own: a simulator
      # stuck enough to hang the app can hang the shot too.
      set -m
      if adb -s "$device" get-state >/dev/null 2>&1; then
        adb -s "$device" exec-out screencap -p > "build/screenshots/$1-stopped.png" &
      else
        xcrun simctl io "$device" screenshot "build/screenshots/$1-stopped.png" >/dev/null &
      fi
      local shot=$!
      set +m
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 15
      kill -KILL -- "-$pid" "-$shot" 2>/dev/null
      break
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  wait "$pid" || status=1
  limit=$(( ${PHONE_FILE_MINUTES:-20} * 60 ))
}

navbar() {
  adb -s "$device" shell cmd overlay enable-exclusive --category \
    "com.android.internal.systemui.navbar.$1"
  sleep 3
}

for test in phone_v2 phone_format_bar phone_sharing phone_home kapy_ai_page kapy_ai_sheet phone_keyboard phone_tasks phone_note_page phone_about phone_note_swipe phone_voice_chip; do
  drive "$test"
done

# phone_recording_away is last: it records, locks the phone and opens
# Settings over the app, none of which the others expect. An iPhone ends an
# app whose permissions change while it runs, so a simulator's microphone is
# granted before the app starts; an emulator's is granted by the test's host.
if ! adb -s "$device" get-state >/dev/null 2>&1; then
  xcrun simctl privacy "$device" grant microphone com.kapybara.kapynotes || status=1
fi
drive phone_recording_away

if adb -s "$device" get-state >/dev/null 2>&1 && wanted phone_bar_android; then
  mode=$(adb -s "$device" shell settings get secure navigation_mode | tr -d '\r')
  navbar threebutton
  drive phone_bar_android
  case "$mode" in
    1) navbar twobutton ;;
    2) navbar gestural ;;
  esac
fi
exit "$status"
