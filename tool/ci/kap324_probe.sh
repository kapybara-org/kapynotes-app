#!/bin/bash
# KAP-324 probe (try branch only): phone_format_bar_test, run again and again on
# one emulator, with the IME's own state polled on the device so it can be
# laid next to Flutter's insets in logcat.
set -u
device=$1
export KAPYNOTES_DEVICE_SHOTS=$device
runs=${KAP324_RUNS:-10}
mkdir -p build/screenshots
adb -s "$device" shell 'while true; do echo "$(date +%H:%M:%S.%N | cut -c1-12) $(dumpsys input_method | grep -oE "mInputShown=[a-z]+|mIsInputViewShown=[a-z]+" | tr "\n" " ")"; sleep 0.25; done' > build/screenshots/ime-poll.txt 2>&1 &
poll=$!
adb -s "$device" logcat -c
adb -s "$device" logcat -v threadtime 'flutter:I' 'InsetsController:D' 'ImeTracker:I' 'FlutterJNI:D' '*:S' > build/screenshots/logcat.txt 2>&1 &
cat=$!
failed=0
for i in $(seq 1 "$runs"); do
  echo "=== run $i $(adb -s "$device" shell date +%H:%M:%S.%N | cut -c1-12)"
  if ! flutter drive --no-pub -d "$device" \
      --driver test_driver/integration_test.dart \
      --target integration_test/phone_format_bar_test.dart \
      --dart-define=KAPYNOTES_SYNC=false --dart-define=KAPYNOTES_DEVICE_SHOTS="$device" --timeout=600 --screenshot=build/screenshots; then
    failed=$((failed + 1))
    echo "=== run $i failed"
    adb -s "$device" exec-out screencap -p > "build/screenshots/run$i-fail.png"
    adb -s "$device" shell dumpsys input_method > "build/screenshots/run$i-input_method.txt"
  fi
done
kill $poll $cat 2>/dev/null
echo "=== $failed of $runs runs failed"
exit 0

