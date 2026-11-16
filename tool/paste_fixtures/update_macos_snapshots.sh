#!/bin/sh
# Regenerates test/fixtures/paste/*/*/macos-snapshot.json from what the macOS
# rich clipboard's read returns for each fixture (RichClipboardFixtureTests).
#
# The hosted test runs inside the sandboxed app under its own bundle id, so
# it can only write to that id's container; this copies the snapshots back.
# It writes a private named pasteboard only, and checks that the system
# clipboard's change count did not move. Run from anywhere; needs the macOS
# build configured (flutter build macos --debug --config-only). Set
# DERIVED_DATA to build somewhere other than Xcode's default.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUNDLE_ID=com.kapybara.kapynotes.clipboardtest
OUTPUT="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/paste-fixture-snapshots"
change_count() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSPasteboard.generalPasteboard.changeCount'
}

before=$(change_count)
cd "$ROOT/macos"
TEST_RUNNER_PASTE_FIXTURES_UPDATE=1 xcodebuild test \
  -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  ${DERIVED_DATA:+-derivedDataPath "$DERIVED_DATA"} \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -only-testing:RunnerTests/RichClipboardFixtureTests
after=$(change_count)
if [ "$before" != "$after" ]; then
  echo "The system clipboard's change count moved from $before to $after during the run." >&2
fi

find "$ROOT/test/fixtures/paste" -name macos-snapshot.json -delete
(cd "$OUTPUT" && find . -name macos-snapshot.json) | while read -r snapshot; do
  cp "$OUTPUT/$snapshot" "$ROOT/test/fixtures/paste/$snapshot"
  echo "test/fixtures/paste/${snapshot#./}"
done
