#!/bin/bash
# Checks phone_screenshots.sh's hang handling on any Linux or macOS machine,
# with no device, no Flutter and no Xcode: fake flutter, xcrun and adb commands
# stand in for them. Each case drives one test file, whose fake flutter drive
# does one thing per run:
#   never      prints nothing, as an app that never connects
#   never-term the same, but says "Error waiting for a debug connection" when
#              it's stopped, as flutter drive does
#   giveup     prints nothing for 2 seconds, then gives up as flutter drive
#              does when the app never connects
#   build-hang starts a build that never ends
#   stall      connects, prints a test line, then nothing more
#   chatty     connects, then prints a line every second and never finishes
#   slow       takes a second to connect and goes quiet for one, then passes
#   pass       connects and passes
#   fail       connects and fails a test
# On the fake emulator, where flutter drive builds the app, each run first
# prints a build and an install. The case checks the script's exit code, how
# many runs it made, how long it took, what it said and what it wrote to the
# progress file. The launch and stall limits are 3 seconds here.
#
#   bash tool/ci/phone_screenshots_test.sh
set -u

script=$(cd "$(dirname "$0")" && pwd)/phone_screenshots.sh
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

mkdir "$root/bin"
cat > "$root/bin/flutter" <<'EOF'
#!/bin/bash
run=$(( $(cat "$FAKE_DIR/runs" 2>/dev/null || echo 0) + 1 ))
echo "$run" > "$FAKE_DIR/runs"
read -ra plan <<< "$FAKE_PLAN"
connect() { echo "VMServiceFlutterDriver: Connected to Flutter application."; }
mode=${plan[run - 1]:-pass}
if [[ $* != *--use-application-binary* ]]; then
  echo "Running Gradle task 'assembleDebug'..."
  if [[ $mode == build-hang ]]; then sleep 1000; fi
  sleep 1
  echo "Installing build/app/outputs/flutter-apk/app-debug.apk..."
fi
case $mode in
  never) sleep 1000 ;;
  never-term)
    trap 'echo "Error waiting for a debug connection: The log reader failed unexpectedly"; exit 1' TERM
    sleep 1000 &
    wait ;;
  giveup) sleep 2; echo "Error waiting for a debug connection: The log reader failed unexpectedly"; exit 1 ;;
  stall) connect; echo "flutter: 00:00 +0: a test"; sleep 1000 ;;
  chatty) connect; while :; do echo "flutter: 00:00 +0: still going"; sleep 1; done ;;
  slow) sleep 1; connect; sleep 1; echo "flutter: 00:02 +1: All tests passed!" ;;
  pass) connect; echo "flutter: 00:01 +1: All tests passed!" ;;
  fail) connect; echo "flutter: 00:01 +0 -1: Some tests failed."; exit 1 ;;
esac
EOF
cat > "$root/bin/xcrun" <<'EOF'
#!/bin/bash
if [[ $* == *screenshot* ]]; then : > "${@: -1}"; fi
EOF
cat > "$root/bin/adb" <<'EOF'
#!/bin/bash
if [[ $FAKE_DEVICE != emulator-* ]]; then exit 1; fi
case $* in
  *get-state*) echo device ;;
  *boot_completed*) echo 1 ;;
esac
EOF
chmod +x "$root/bin/"*

# check <name> <device> <plan> <exit code> <runs> <most seconds> <text>...:
# runs phone_about_test.dart under plan, and checks the result. Each text must
# be in the script's output, or in the progress file after progress:; one
# that starts with ! must not be in the output. LAUNCH, when set, replaces the
# launch limit.
check() {
  local name=$1 device=$2 plan=$3 want=$4 runs=$5 most=$6
  shift 6
  local dir=$root/$name app=
  mkdir "$dir"
  if [[ $device != emulator-* ]]; then app=build/ios/Runner.app; fi
  local began=$SECONDS
  (
    cd "$dir" &&
      PATH=$root/bin:$PATH FAKE_DIR=$dir FAKE_PLAN=$plan FAKE_DEVICE=$device \
        PHONE_TESTS=phone_about PHONE_APP=$app PHONE_TEST_FILE=$dir/test-file \
        PHONE_LAUNCH_SECONDS=${LAUNCH:-3} PHONE_STALL_SECONDS=3 PHONE_RETRY_MINUTES=5 \
        PHONE_FIRST_FILE_MINUTES=1 GITHUB_STEP_SUMMARY=$dir/summary \
        bash "$script" "$device" > "$dir/out" 2>&1
  )
  local code=$? took=$(( SECONDS - began )) problems=()
  if (( code != want )); then problems+=("exited $code, not $want"); fi
  if [[ $(cat "$dir/runs" 2>/dev/null) != "$runs" ]]; then
    problems+=("ran $(cat "$dir/runs" 2>/dev/null || echo 0) times, not $runs")
  fi
  if (( took > most )); then problems+=("took $took seconds, more than $most"); fi
  local text
  for text in "$@"; do
    if [[ $text == progress:* ]]; then
      if ! grep -qF -- "${text#progress:}" "$dir/build/screenshots/phone-progress.txt"; then
        problems+=("didn't write \"${text#progress:}\" to the progress file")
      fi
    elif [[ $text == '!'* ]]; then
      if grep -qF -- "${text#!}" "$dir/out"; then problems+=("said \"${text#!}\""); fi
    elif ! grep -qF -- "$text" "$dir/out"; then
      problems+=("didn't say \"$text\"")
    fi
  done
  if (( ${#problems[@]} )); then
    echo "FAIL $name: $(IFS=';'; echo "${problems[*]}")"
    sed 's/^/    /' "$dir/out"
  else
    echo "ok   $name (${took}s)"
  fi
}

ios=FAKE-UDID
{
  # Rule 1: an app that never connects is stopped within the launch limit
  # and runs once more.
  check launch-hang-then-pass $ios 'never pass' 0 2 20 \
    "hadn't connected 3 seconds after" \
    '::warning::phone_about_test.dart hung: the app never connected. Running it again' '!FAIL' \
    'progress:phone_about_test.dart run 1 started' \
    'progress:phone_about_test.dart failed after' 'progress:the app never connected, stopped' \
    'progress:phone_about_test.dart run 2 started' 'progress:phone_about_test.dart connected' \
    'progress:phone_about_test.dart passed after' 'progress:done, exit 0' &
  # Rule 2: an app that connects and then goes quiet is stopped after the
  # stall limit and runs once more.
  check stall-then-pass $ios 'stall pass' 0 2 25 \
    'nothing new reached the log for 3 seconds' \
    '::warning::phone_about_test.dart hung: the app connected, then stalled' '!FAIL' &
  # Rule 3: a second hang fails the run with a FAIL line naming the file and
  # each run's kind of hang.
  check launch-hang-twice $ios 'never never' 1 2 35 \
    '::error::FAIL phone_about_test.dart hung twice. First run: the app never connected. Second run: the app never connected' &
  check stall-twice $ios 'stall stall' 1 2 45 \
    '::error::FAIL phone_about_test.dart hung twice. First run: the app connected, then stalled with nothing new in the log for 3 seconds. Second run: the app connected, then stalled' &
  check launch-hang-then-stall $ios 'never stall' 1 2 40 \
    '::error::FAIL phone_about_test.dart hung twice. First run: the app never connected. Second run: the app connected, then stalled' &
  # A test that fails is never run again, and a slow launch or a quiet stretch
  # within the limits is left alone.
  check test-fails $ios 'fail' 1 1 10 '!hung' '!Running it again' &
  check slow-but-healthy $ios 'slow' 0 1 10 '!stopped' '!hung' &
  check pass $ios 'pass' 0 1 10 '!stopped' &
  # A file that keeps printing still stops at its wall-clock limit, and fails
  # without a second run, as before.
  check wall-clock-limit $ios 'chatty' 1 1 80 \
    '::error::phone_about_test.dart was still running after 1 minutes and was stopped' '!Running it again' &
  # When flutter drive itself gives up on an app that never connects, the
  # file runs once more, as before.
  check gives-up-then-pass $ios 'giveup pass' 0 2 20 \
    '::warning::phone_about_test.dart hung: the app never connected. Running it again' &
  # On an emulator, the launch is counted from the app's install, so a build
  # never counts towards it, and a build that hangs is stopped only at the
  # file's limit.
  check android-launch-hang-then-pass emulator-5554 'never pass' 0 2 25 \
    "hadn't connected 3 seconds after its launch" \
    '::warning::phone_about_test.dart hung: the app never connected. Running it again' \
    'progress:phone_about_test.dart built and installed' &
  check android-stall-then-pass emulator-5554 'stall pass' 0 2 30 \
    '::warning::phone_about_test.dart hung: the app connected, then stalled' &
  check android-build-hang-waits-for-limit emulator-5554 'build-hang' 1 1 80 \
    '::error::phone_about_test.dart was still running after 1 minutes and was stopped' '!hung' \
    'progress:phone_about_test.dart failed after' '!built and installed' &
  check android-gives-up-then-pass emulator-5554 'giveup pass' 0 2 25 \
    '::warning::phone_about_test.dart hung: the app never connected. Running it again' &
  # What flutter drive says as it's stopped reaches the log on Linux too, so a
  # file stopped at its limit before connecting runs once more.
  LAUNCH=0 check android-stopped-before-connecting-then-pass emulator-5554 'never-term pass' 0 2 80 \
    '::error::phone_about_test.dart was still running after 1 minutes and was stopped' \
    '::warning::phone_about_test.dart hung: the app never connected. Running it again' &
  wait
} > "$root/results"
cat "$root/results"
if grep -q '^FAIL' "$root/results"; then
  echo "phone_screenshots.sh's hang handling fails some cases"
  exit 1
fi
echo "phone_screenshots.sh's hang handling passes every case"
