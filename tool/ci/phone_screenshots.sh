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
# `phone_recording_away`, for a run that checks one test.
#
# On an Android emulator, a file whose run the emulator spoiled before its
# tests finished (the app's VM Service refused or never answered, or the
# emulator went offline mid-test) gets adb restarted and runs once more, as
# long as fewer than PHONE_RETRY_MINUTES (0 by default) have gone by. A VM
# Service that isn't answering is given up on within about a minute and a half
# instead of after the file's whole limit. A file whose app logged "All tests
# passed!" and then lost only the results, with the emulator gone, counts as
# passed, with a warning that its Flutter screenshots are missing. A file with
# a failing test is never run again. An emulator still offline 4 minutes after
# adb restarts ends the run there, since no file after it can run.
set -u

device=$1
status=0
export KAPYNOTES_DEVICE_SHOTS=$device

android=false
if [[ $device == emulator-* ]]; then android=true; fi
retry_until=$(( SECONDS + ${PHONE_RETRY_MINUTES:-0} * 60 ))
log=$(mktemp)
limit=$(( ${PHONE_FIRST_FILE_MINUTES:-35} * 60 ))
mkdir -p build/screenshots

wanted() {
  [[ -z ${PHONE_TESTS:-} || " $PHONE_TESTS " == *" $1 "* ]]
}

# Stops file $1's run, process group $2, with a screenshot of where it got to.
# The shot is put off to one side, in a group of its own: a device stuck
# enough to hang the app can hang the shot too.
stop() {
  set -m
  if $android || adb -s "$device" get-state >/dev/null 2>&1; then
    adb -s "$device" exec-out screencap -p > "build/screenshots/$1-stopped.png" &
  else
    xcrun simctl io "$device" screenshot "build/screenshots/$1-stopped.png" >/dev/null &
  fi
  local shot=$!
  set +m
  kill -TERM -- "-$2" 2>/dev/null
  sleep 15
  kill -KILL -- "-$2" "-$shot" 2>/dev/null
}

# Restarts adb and waits up to 4 minutes for the emulator to be booted again,
# or ends the run.
reconnect() {
  adb kill-server >/dev/null 2>&1
  adb start-server >/dev/null 2>&1
  local waited=0
  until [[ $(adb -s "$device" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; do
    if (( waited >= 240 )); then
      echo "::error::the emulator was still offline 4 minutes after adb restarted at $1_test.dart, so the run stops there"
      exit 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
}

# Whether the run in $log was spoiled by the emulator rather than by a test.
spoiled() {
  ! grep -qE '\[E\]|Some tests failed' "$log" &&
    grep -qE 'Exception attempting to connect to the VM Service|unusually long time to connect|Service has disappeared|device offline' "$log"
}

drive() {
  wanted "$1" || return 0
  local tries=0 code
  while :; do
    if $android && [[ $(adb -s "$device" get-state 2>/dev/null) != device ]]; then
      echo "::warning::the emulator was offline before $1_test.dart; restarting adb"
      reconnect "$1"
    fi
    local args=(drive --no-pub -d "$device"
      --driver test_driver/integration_test.dart
      --target "integration_test/$1_test.dart"
      --dart-define=KAPYNOTES_SYNC=false
      --dart-define=KAPYNOTES_DEVICE_SHOTS="$device"
      --timeout=600 --screenshot=build/screenshots)
    : > "$log"
    set -m
    if $android; then
      flutter "${args[@]}" > >(tee "$log") 2>&1 &
    else
      flutter "${args[@]}" &
    fi
    local pid=$! waited=0
    set +m
    while kill -0 "$pid" 2>/dev/null; do
      if (( waited >= limit )); then
        echo "::error::$1_test.dart was still running after $(( limit / 60 )) minutes and was stopped"
        stop "$1" "$pid"
        break
      fi
      if $android && { grep -q 'Exception attempting to connect to the VM Service' "$log" ||
        (( $(grep -c 'unusually long time to connect' "$log") >= 30 )); }; then
        echo "::warning::$1_test.dart could not reach the app's VM Service and was stopped"
        stop "$1" "$pid"
        break
      fi
      sleep 5
      waited=$(( waited + 5 ))
    done
    wait "$pid"
    code=$?
    limit=$(( ${PHONE_FILE_MINUTES:-20} * 60 ))
    if (( code == 0 )); then return 0; fi
    sleep 1
    if $android && spoiled && grep -q 'All tests passed!' "$log"; then
      echo "::warning::$1_test.dart passed, but the emulator dropped before its results came back, so its Flutter screenshots are missing; restarting adb"
      reconnect "$1"
      return 0
    fi
    if ! $android || (( tries > 0 || SECONDS >= retry_until )) || ! spoiled; then
      status=1
      return
    fi
    tries=1
    echo "::warning::the emulator spoiled $1_test.dart's run, not a test; restarting adb and running it again"
    reconnect "$1"
  done
}

navbar() {
  adb -s "$device" shell cmd overlay enable-exclusive --category \
    "com.android.internal.systemui.navbar.$1"
  sleep 3
}

for test in phone_v2 phone_format_bar phone_sharing phone_home kapy_ai_page kapy_ai_sheet kapy_ai_notice phone_keyboard phone_tasks phone_note_page phone_about phone_note_swipe phone_voice_chip phone_voice_window phone_time_line phone_video phone_camera; do
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
