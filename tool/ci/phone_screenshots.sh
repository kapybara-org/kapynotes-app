#!/bin/bash
# kapy70/try-header only: the voice-chip header diagnostic, nothing else.
set -u

device=$1
status=0
export KAPYNOTES_DEVICE_SHOTS=$device

flutter drive --no-pub -d "$device" \
  --driver test_driver/integration_test.dart \
  --target integration_test/phone_voice_chip_test.dart \
  --dart-define=KAPYNOTES_SYNC=false \
  --dart-define=KAPYNOTES_DEVICE_SHOTS="$device" \
  --timeout=600 --screenshot=build/screenshots || status=1
exit "$status"
