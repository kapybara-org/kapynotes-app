#!/bin/bash
# The Mac's integration tests under flutter drive on a CI runner, with their
# screenshots saved to build/screenshots:
#
#   bash tool/ci/mac_tests.sh [integration_test/<name>_test.dart ...]
#
# It builds and launches the app under its real bundle id, so it refuses to
# run anywhere but CI. On your own Mac, run one test with flutter test, as
# that test's header says.
#
# With no files it runs every integration_test/*_test.dart except these:
# - phone_* and kapy_ai_page, which test the phones' screens;
# - apple_transcribe and voice_recording, which need speech recognition or
#   the microphone, permissions a runner can't grant;
# - gemma_summary and parakeet_transcribe, which skip themselves without
#   their models, 2.6 GB and 670 MB;
# - menu_bar_panel, until KAP-264 finds out why one of its 21 openings in a
#   row came back as not shown on the runner (run 44932436367). It runs only
#   when named.
#
# Every file runs even when one fails, and the script exits 1 if any did. A
# test that hangs is stopped after 10 minutes.
set -u

if [[ ${CI:-} != true ]]; then
  echo 'mac_tests.sh is for CI runners: it uses the real bundle id.' >&2
  exit 2
fi

if (($#)); then
  tests=("$@")
else
  tests=()
  for test in integration_test/*_test.dart; do
    case ${test#integration_test/} in
      phone_* | kapy_ai_page_test.dart) ;;
      apple_transcribe_test.dart | voice_recording_test.dart) ;;
      gemma_summary_test.dart | parakeet_transcribe_test.dart) ;;
      menu_bar_panel_test.dart) ;;
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
