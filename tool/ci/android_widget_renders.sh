#!/bin/bash
# The Android widgets, every size in light and dark, rendered on an emulator
# to build/widget-renders/android for a reviewer to hold against the
# Widgets · v2 boards, and every tap on them followed into the app, by the
# instrumented tests in android/app/src/androidTest:
#
#   bash tool/ci/android_widget_renders.sh <device serial>
#
# Installs the debug app and its test APK, which .github/workflows/widgets.yml
# builds first. The renders are pulled even when a test fails, and the script
# then exits 1.
set -euo pipefail

device=$1
out=build/widget-renders/android
log=build/widget-renders/android-tests.txt
rm -rf build/widget-renders
mkdir -p "$out"

adb -s "$device" install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb -s "$device" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s "$device" shell am instrument -w \
  com.kapybara.kapynotes.test/androidx.test.runner.AndroidJUnitRunner | tee "$log"
adb -s "$device" pull /sdcard/Android/data/com.kapybara.kapynotes/files/widget-renders/. "$out"
grep -q "^OK (2 tests)" "$log"
