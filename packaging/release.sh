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

# Installer window geometry. These match packaging/dmg/background.tiff, which
# tool/generate_dmg_background.swift draws at exactly WINDOW_W x WINDOW_H;
# change one and regenerate the other.
WINDOW_W=640
WINDOW_H=448
TITLE_BAR=28
ICON_SIZE=116
ICON_Y=182
APP_ICON_X=176
DROP_ICON_X=464
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
  build_disk_image "$app" "$dmg"

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

# Lays out the installer window: the app on the left, a drop target on the
# right, and the artwork from packaging/dmg behind both.
#
# The layout is applied by scripting Finder, which needs Automation
# permission for whatever runs this script — macOS asks the first time. If
# that is refused, or nobody is logged in, the image is still built and still
# installs; it just opens with Finder's default window.
apply_dmg_layout() {
  local volume="$1"
  osascript <<APPLESCRIPT
with timeout of 120 seconds
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- {left, top, right, bottom}; the extra $TITLE_BAR is the title bar, so
    -- the content area matches the background image exactly.
    set the bounds of container window to {200, 160, $((200 + WINDOW_W)), $((160 + WINDOW_H + TITLE_BAR))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON_SIZE
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {$APP_ICON_X, $ICON_Y}
    set position of item "Applications" of container window to {$DROP_ICON_X, $ICON_Y}
    update without registering applications
    -- Finder writes the .DS_Store that carries all of the above when the
    -- window closes, so the image must not be detached before it does.
    delay 2
    close
  end tell
end tell
end timeout
APPLESCRIPT
}

build_disk_image() {
  local app="$1"
  local dmg="$2"
  local staging temp_dmg mounted size_mb

  rm -f "$dmg"
  staging="$(mktemp -d)"
  mkdir -p "$staging/.background"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  cp "$ROOT/packaging/dmg/background.tiff" "$staging/.background/background.tiff"
  cp "$ROOT/packaging/dmg/VolumeIcon.icns" "$staging/.VolumeIcon.icns"

  # A read-write image with room to spare: Finder has to write its own
  # .DS_Store into it before the compressed copy is made.
  size_mb=$(( $(du -sm "$staging" | cut -f1) + 60 ))
  temp_dmg="$OUT/$DMG_NAME-rw.dmg"
  rm -f "$temp_dmg"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$staging" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    -size "${size_mb}m" \
    "$temp_dmg" >/dev/null
  rm -rf "$staging"

  # A leftover mount from an earlier build owns the volume name we need, and
  # macOS would silently mount this one as "Kapy Notes 1" instead.
  if [[ -d "/Volumes/$APP_NAME" ]]; then
    echo "  detaching an already-mounted $APP_NAME volume"
    hdiutil detach "/Volumes/$APP_NAME" -force >/dev/null 2>&1 || true
  fi
  # Read the mount point back rather than assuming it, so a renamed volume
  # fails loudly here instead of quietly skipping the layout.
  mounted="$(hdiutil attach "$temp_dmg" -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
  if [[ "$mounted" != "/Volumes/$APP_NAME" ]]; then
    echo "error: image mounted at '$mounted', not /Volumes/$APP_NAME" >&2
    hdiutil detach "$mounted" -force >/dev/null 2>&1 || true
    exit 1
  fi

  if apply_dmg_layout "$APP_NAME" >/dev/null 2>&1; then
    echo "  window laid out over the Kapy background"
  else
    echo "  warning: could not script Finder; shipping an unstyled window" >&2
  fi
  # Marks the volume as having a custom icon, so .VolumeIcon.icns is used.
  SetFile -a C "$mounted" 2>/dev/null || true
  sync

  # Finder can still be holding the volume a moment after closing its window.
  hdiutil detach "$mounted" >/dev/null 2>&1 ||
    hdiutil detach "$mounted" -force >/dev/null
  hdiutil convert "$temp_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
  rm -f "$temp_dmg"
}

build_ios() {
  info "iOS $VERSION ($BUILD_NUMBER) → App Store"
  "$ROOT/packaging/preflight_ios.sh" --archive
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
