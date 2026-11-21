#!/bin/bash
# The Mac's integration tests under flutter drive, with their screenshots
# saved to build/screenshots:
#
#   bash tool/ci/mac_tests.sh [integration_test/<name>_test.dart ...]
#
# With no files it runs every integration_test/*_test.dart except these:
# - phone_* and kapy_ai_page, which test the phones' screens;
# - apple_transcribe, parakeet_transcribe and voice_recording, which need the
#   microphone or speech recognition, permissions a runner can't grant;
# - gemma_summary, which skips itself without its 2.6 GB model.
#
# Every file runs even when one fails, and the script exits 1 if any did. A
# test that hangs is stopped after 10 minutes.
set -u

if (($#)); then
  tests=("$@")
else
  tests=()
  for test in integration_test/*_test.dart; do
    case ${test#integration_test/} in
      phone_* | kapy_ai_page_test.dart) ;;
      apple_transcribe_test.dart | parakeet_transcribe_test.dart) ;;
      voice_recording_test.dart | gemma_summary_test.dart) ;;
      *) tests+=("$test") ;;
    esac
  done
fi

status=0
for test in "${tests[@]}"; do
  flutter drive --no-pub -d macos \
    --driver test_driver/integration_test.dart \
    --target "$test" \
    --dart-define=KAPYNOTES_SYNC=false \
    --timeout=600 || status=1
done
exit "$status"
