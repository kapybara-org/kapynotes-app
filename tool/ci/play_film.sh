#!/bin/bash
# Scratch, never merged: films integration_test/play_film_test.dart on one
# Android emulator for the Play Console's foreground-service declaration.
set -u
device=$1
export KAPYNOTES_DEVICE_SHOTS=$device
flutter drive --no-pub -d "$device" \
  --driver test_driver/integration_test.dart \
  --target integration_test/play_film_test.dart \
  --dart-define=KAPYNOTES_SYNC=false \
  --dart-define=KAPYNOTES_DEVICE_SHOTS="$device" \
  --timeout=600 --screenshot=build/screenshots
