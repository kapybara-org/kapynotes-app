#!/bin/bash
# The phone integration tests under flutter drive on one device, with their
# screenshots saved to build/screenshots:
#
#   bash tool/ci/phone_screenshots.sh <device id>
#
# With --check in place of a device id, it only checks PHONE_TESTS's names and
# that integration_test/phones.dart has an entry for every test below.
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
# first file, which pays for the cold build, PHONE_FIRST_FILE_MINUTES, 35) is
# stopped with everything it started, counts as failed, and the next file runs.
# A file that hangs is stopped sooner, with a screenshot of where, and runs
# once more:
# - its app hasn't connected PHONE_LAUNCH_SECONDS (150) after its launch, which
#   is when flutter drive starts on a PHONE_APP build, or when it installs the
#   app it built: the slowest healthy launch took 96 on an iPhone and 13 on an
#   emulator. A flutter drive that gives up on the app ("Error waiting for a
#   debug connection") counts too;
# - or its app connected and then nothing new reached the log for
#   PHONE_STALL_SECONDS (240), since phone_recording_away's locked recording
#   is quiet for up to 163.
# A file that hangs on both runs fails the run with a FAIL line saying which
# way it hung. A build that hangs is stopped only at the file's limit.
#
# Each file's runs, with when each started, connected and ended and how, go
# to build/screenshots/phone-progress.txt as they happen, so a job stopped
# mid-run still shows which file it was on.
# PHONE_TESTS, when set, names the only tests to run, such as
# `phone_recording_away`, for a run that checks one test. A name that isn't
# one of the phone tests below fails the run, so a typo, or a desktop test
# this script never drives, can't run nothing and pass.
# Every file run again is listed in the job summary; a test that ran and
# failed is never run again.
# PHONE_APP, when set, names an app already built from
# integration_test/phones.dart, as Phones' iOS job builds it: each file then
# runs on that build instead of building one of its own, after the script
# writes its name to PHONE_TEST_FILE, the file that build reads.
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
progress=build/screenshots/phone-progress.txt
limit=$(( ${PHONE_FIRST_FILE_MINUTES:-35} * 60 ))
launch=${PHONE_LAUNCH_SECONDS:-150}
stall=${PHONE_STALL_SECONDS:-240}

wanted() {
  [[ -z ${PHONE_TESTS:-} || " $PHONE_TESTS " == *" $1 "* ]]
}

tests=(phone_v2 phone_format_bar phone_sharing phone_home kapy_ai_page kapy_ai_sheet kapy_ai_notice phone_keyboard phone_tasks phone_note_page phone_about phone_note_swipe phone_voice_chip phone_voice_window phone_time_line phone_video phone_camera phone_page_turn phone_recap_story)
phone_tests=" ${tests[*]} phone_remove_noise phone_recording_away phone_bar_android "
picked=
set -f
for name in ${PHONE_TESTS:-}; do
  if [[ $phone_tests != *" $name "* ]]; then
    echo "::error::PHONE_TESTS names $name, which isn't a phone test:$phone_tests"
    exit 1
  fi
  picked+=" $name"
done
set +f
if [[ -n ${PHONE_TESTS:-} && -z $picked ]]; then
  echo "::error::PHONE_TESTS names no test"
  exit 1
fi
PHONE_TESTS=$picked
if [[ $device == --check ]]; then
  map=$(dirname "$0")/../../integration_test/phones.dart
  for name in $phone_tests; do
    if ! grep -q "'$name':" "$map"; then
      echo "::error::$map has no entry for $name, which this script drives"
      exit 1
    fi
  done
  exit 0
fi
mkdir -p build/screenshots
: > "$progress"

# flutter drive's output reaches the job's log and $log through one tee in the
# script's own process group. On Linux, a tee in each run's group would die
# with a run that's stopped, taking with it what flutter drive says on the way
# out, such as "Error waiting for a debug connection".
exec 3> >(tee -a "$log")

# Adds a line to the progress file, after the time.
note() {
  echo "$(date -u +%H:%M:%S) $*" >> "$progress"
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
  local waited
  for (( waited = 0; waited < 15; waited++ )); do
    kill -0 -- "-$2" 2>/dev/null || kill -0 -- "-$shot" 2>/dev/null || break
    sleep 1
  done
  kill -KILL -- "-$2" "-$shot" 2>/dev/null
}

# What a hang of kind $1 was, for the warning and FAIL lines.
hang_said() {
  case $1 in
    launch) echo "the app never connected" ;;
    stall) echo "the app connected, then stalled with nothing new in the log for $stall seconds" ;;
  esac
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
  local tries=0 code target=integration_test/$1_test.dart built=() first_hang=
  if [[ -n ${PHONE_APP:-} ]]; then
    target=integration_test/phones.dart
    built=(--use-application-binary "$PHONE_APP")
  fi
  while :; do
    if $android && [[ $(adb -s "$device" get-state 2>/dev/null) != device ]]; then
      echo "::warning::the emulator was offline before $1_test.dart; restarting adb"
      reconnect "$1"
    fi
    local args=(drive --no-pub -d "$device"
      --driver test_driver/integration_test.dart
      --target "$target" ${built[@]+"${built[@]}"}
      --dart-define=KAPYNOTES_SYNC=false
      --dart-define=KAPYNOTES_DEVICE_SHOTS="$device"
      --timeout=600 --screenshot=build/screenshots)
    : > "$log"
    if [[ -n ${PHONE_APP:-} ]]; then echo "$1" > "$PHONE_TEST_FILE"; fi
    local stopped=false hang= connected=false size=0 now launched=
    note "$1_test.dart run $(( tries + 1 )) started"
    set -m
    flutter "${args[@]}" >&3 2>&1 &
    local pid=$! started=$SECONDS quiet=$SECONDS
    set +m
    if [[ -n ${PHONE_APP:-} ]]; then launched=$started; fi
    while kill -0 "$pid" 2>/dev/null; do
      if (( launch || stall )); then
        now=$(wc -c < "$log")
        if (( now != size )); then size=$now quiet=$SECONDS; fi
        if [[ -z $launched ]] && grep -qE 'Installing build/.*\.apk' "$log"; then
          launched=$SECONDS
          note "$1_test.dart built and installed"
        fi
        if ! $connected && grep -qE 'Connected to Flutter application|[0-9]{2}:[0-9]{2} \+[0-9]+' "$log"; then
          connected=true
          note "$1_test.dart connected"
        fi
      fi
      if ! $connected && [[ -n $launched ]] && (( launch && SECONDS - launched >= launch )); then
        echo "$1_test.dart's app hadn't connected $launch seconds after its launch, so it was stopped"
        hang=launch
      elif $connected && (( stall && SECONDS - quiet >= stall )); then
        echo "$1_test.dart's app connected, then nothing new reached the log for $stall seconds, so it was stopped"
        hang=stall
      elif (( SECONDS - started >= limit )); then
        echo "::error::$1_test.dart was still running after $(( limit / 60 )) minutes and was stopped"
      elif $android && { grep -q 'Exception attempting to connect to the VM Service' "$log" ||
        (( $(grep -c 'unusually long time to connect' "$log") >= 30 )); }; then
        echo "::warning::$1_test.dart could not reach the app's VM Service and was stopped"
        stop "$1" "$pid"
        break
      else
        sleep 5
        continue
      fi
      stop "$1" "$pid"
      stopped=true
      break
    done
    wait "$pid"
    code=$?
    if $stopped && (( code == 0 )); then code=1; fi
    limit=$(( ${PHONE_FILE_MINUTES:-20} * 60 ))
    if (( code == 0 )); then
      note "$1_test.dart passed after $(( SECONDS - started )) s"
      return 0
    fi
    sleep 1
    if [[ -z $hang ]] && grep -q 'Error waiting for a debug connection' "$log" &&
      ! grep -qE '[0-9]{2}:[0-9]{2} \+[0-9]+' "$log"; then
      hang=launch
    fi
    note "$1_test.dart failed after $(( SECONDS - started )) s${hang:+: $(hang_said "$hang")}$($stopped && echo ", stopped")"
    if [[ -n $hang ]]; then
      if (( tries == 0 )) && { ! $android || (( SECONDS < retry_until )); }; then
        tries=1 first_hang=$hang
        echo "::warning::$1_test.dart hung: $(hang_said "$hang"). Running it again"
        echo "- $1_test.dart hung: $(hang_said "$hang"). It ran again" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
        continue
      fi
      if [[ -n $first_hang ]]; then
        echo "::error::FAIL $1_test.dart hung twice. First run: $(hang_said "$first_hang"). Second run: $(hang_said "$hang")"
      else
        echo "::error::FAIL $1_test.dart hung: $(hang_said "$hang")"
      fi
      status=1
      return
    fi
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

for test in "${tests[@]}"; do
  drive "$test"
done

# The tests that record come last, phone_recording_away the very last: it
# records, locks the phone and opens Settings over the app, none of which the
# others expect. An iPhone ends an app whose permissions change while it runs,
# so a simulator's microphone is granted before each of them starts: flutter
# drive uninstalls the app when a file ends, and its permissions go with it.
# An emulator's is granted by the test's host.
for test in phone_remove_noise phone_recording_away; do
  if ! adb -s "$device" get-state >/dev/null 2>&1; then
    xcrun simctl privacy "$device" grant microphone com.kapybara.kapynotes || status=1
  fi
  drive "$test"
done

if adb -s "$device" get-state >/dev/null 2>&1 && wanted phone_bar_android; then
  mode=$(adb -s "$device" shell settings get secure navigation_mode | tr -d '\r')
  navbar threebutton
  drive phone_bar_android
  case "$mode" in
    1) navbar twobutton ;;
    2) navbar gestural ;;
  esac
fi
note "done, exit $status"
exit "$status"
