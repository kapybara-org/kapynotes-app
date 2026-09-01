#!/usr/bin/env bash
#
# Builds the shippable Kapy artifacts.
#
#   mac-direct  → build/release/Kapy-<version>.dmg   notarised, for kapynotes.com
#   ios         → build/release/kapy-ios.ipa         for App Store Connect
#   mac-store   → build/release/kapy-macos.pkg       Mac App Store (not in use yet)
#
# Usage:  packaging/release.sh [mac-direct|ios|mac-store]
#
# Notarising needs a stored credential. Create it once:
#   xcrun notarytool store-credentials kapynotes-notary \
#     --apple-id <apple-id> --team-id 96V66447C6 --password <app-specific-password>
#
# Set SKIP_NOTARIZE=1 to build an unnotarised DMG for local testing. Such a
# build will be blocked by Gatekeeper on any machine other than this one.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLUTTER="${FLUTTER:-$HOME/development/flutter/bin/flutter}"
OUT="$ROOT/build/release"
ARCHIVES="$ROOT/build/archives"
NOTARY_PROFILE="${NOTARY_PROFILE:-kapynotes-notary}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
APP_NAME="Kapy Notes"
# No space in the DMG filename, so the download URL needs no %20 escaping.
DMG_NAME="KapyNotes"
DEV_ID="Developer ID Application: Kapybara LLC (96V66447C6)"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
BUILD_NUMBER="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f2)"

mkdir -p "$OUT" "$ARCHIVES"

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

# Flutter has to run first so the ephemeral xcconfig, the plugin Swift package
# and the compiled Dart kernel exist before xcodebuild archives the target.
prepare_macos() {
  "$FLUTTER" build macos --release
}

archive_macos() {
  local archive="$1"
  rm -rf "$archive"
  xcodebuild archive \
    -workspace "$ROOT/macos/Runner.xcworkspace" \
    -scheme Runner \
    -configuration Release \
    -archivePath "$archive" \
    -destination 'generic/platform=macOS'
}

build_mac_direct() {
  info "macOS $VERSION ($BUILD_NUMBER) → Developer ID, direct download"
  prepare_macos
  archive_macos "$ARCHIVES/kapy-developerid.xcarchive"
  rm -rf "$OUT/developerid"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVES/kapy-developerid.xcarchive" \
    -exportOptionsPlist "$ROOT/packaging/ExportOptions-macos-developerid.plist" \
    -exportPath "$OUT/developerid"

  local app="$OUT/developerid/$APP_NAME.app"
  local dmg="$OUT/$DMG_NAME-$VERSION.dmg"

  info "Verifying the exported app is signed and hardened"
  codesign --verify --strict --deep --verbose=2 "$app"
  # Distribution builds must not carry get-task-allow; it would fail notarisation.
  if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'get-task-allow'; then
    echo "error: get-task-allow present in a distribution build" >&2
    exit 1
  fi

  # Two notarisation passes, deliberately. Stapling only the disk image leaves
  # the copy the user drags to /Applications without a ticket of its own, so its
  # first launch needs an online Gatekeeper lookup. Notarising the app first and
  # stapling it means the installed copy validates offline; the image is then
  # notarised in turn so mounting it is trusted too.
  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    info "Pass 1 of 2 — notarising the app"
    local zip="$OUT/$DMG_NAME-app.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
  fi

  info "Building disk image"
  rm -f "$dmg"
  local staging
  staging="$(mktemp -d)"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$staging"

  # The image is signed too, so Gatekeeper trusts it before it is opened.
  codesign --sign "$DEV_ID" --timestamp "$dmg"

  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    info "SKIP_NOTARIZE=1 — stopping before notarisation"
    echo "  → $dmg (unnotarised, will be blocked on other machines)"
    return
  fi

  info "Pass 2 of 2 — notarising the disk image"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"

  info "Verifying"
  xcrun stapler validate "$dmg"
  spctl -a -vvv -t open --context context:primary-signature "$dmg"
  echo "  → $dmg"
}

build_ios() {
  info "iOS $VERSION ($BUILD_NUMBER) → App Store"
  "$FLUTTER" build ipa \
    --release \
    --export-options-plist="$ROOT/packaging/ExportOptions-ios-appstore.plist"
  cp "$ROOT/build/ios/ipa/"*.ipa "$OUT/kapy-ios.ipa"
  echo "  → $OUT/kapy-ios.ipa"
}

build_mac_store() {
  info "macOS $VERSION ($BUILD_NUMBER) → Mac App Store"
  prepare_macos
  archive_macos "$ARCHIVES/kapy-appstore.xcarchive"
  rm -rf "$OUT/appstore"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVES/kapy-appstore.xcarchive" \
    -exportOptionsPlist "$ROOT/packaging/ExportOptions-macos-appstore.plist" \
    -exportPath "$OUT/appstore"
  cp "$OUT/appstore/"*.pkg "$OUT/kapy-macos.pkg"
  echo "  → $OUT/kapy-macos.pkg"
}

case "${1:-mac-direct}" in
  mac-direct) build_mac_direct ;;
  ios)        build_ios ;;
  mac-store)  build_mac_store ;;
  *)          echo "Usage: $0 [mac-direct|ios|mac-store]" >&2; exit 1 ;;
esac

info "Done"
