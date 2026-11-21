#!/bin/bash
# The phone integration tests under flutter drive on one device, with their
# screenshots saved to build/screenshots:
#
#   bash tool/ci/phone_screenshots.sh <device id>
#
# Every test file runs even when one fails, and the script exits 1 if any did.
# A test that hangs is stopped after 10 minutes, with a screenshot of where.
set -u

device=$1
status=0
for test in phone_v2 phone_format_bar phone_home kapy_ai_page; do
  flutter drive --no-pub -d "$device" \
    --driver test_driver/integration_test.dart \
    --target "integration_test/${test}_test.dart" \
    --dart-define=KAPYNOTES_SYNC=false \
    --timeout=600 --screenshot=build/screenshots || status=1
done
exit "$status"
