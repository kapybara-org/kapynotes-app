#!/usr/bin/env bash
#
# Builds the shippable Kapy artifacts.
#
#   mac-direct    → build/release/KapyNotes-<version>.dmg  notarised, to ship
#   mac-unsigned  → build/release/KapyNotes-<version>-unsigned.dmg  CI only
#   ios           → build/release/kapy-ios.ipa       for App Store Connect
#   mac-store     → build/release/kapy-macos.pkg     Mac App Store (not in use yet)
#   android       → build/release/kapy-android.aab   for Google Play
#
# Usage:  packaging/release.sh [mac-direct|mac-unsigned|ios|mac-store|android]
#
# `dmg-template` regenerates the committed DMG window layout; see
# build_dmg_template. It is a maintenance command, not a build.
#
# The Android bundle needs android/key.properties and the keystore it points
# at. See android/key.properties.example. Without them Gradle falls back to
# the debug key, and preflight_android.sh refuses the build rather than let a
# debug-signed bundle reach Play.
#
# Notarising needs a stored credential. Create it once:
#   xcrun notarytool store-credentials kapynotes-notary \
#     --apple-id <apple-id> --team-id 96V66447C6 --password <app-specific-password>
#
# CI has no keychain to store that in. Set NOTARY_KEY_PATH, NOTARY_KEY_ID and
# NOTARY_ISSUER instead and an App Store Connect API key is used. FLUTTER
# overrides the SDK path for runners that install it elsewhere.
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

# The window layout Finder would write, captured once and committed. Named
# without the leading dot on purpose: `.DS_Store` is in .gitignore, so the real
# filename could never be tracked.
DMG_TEMPLATE="$ROOT/packaging/dmg/DS_Store"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
BUILD_NUMBER="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f2)"

mkdir -p "$OUT" "$ARCHIVES"

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

# notarytool credentials. Locally that is the stored keychain profile; CI has
# no keychain to store one in, so it passes an App Store Connect API key
# instead. Same submission either way.
notarize() {
  local target="$1"
  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$target" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER" \
      --wait
  else
    xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

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
    notarize "$zip"
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
  notarize "$dmg"
  xcrun stapler staple "$dmg"

  info "Verifying"
  xcrun stapler validate "$dmg"
  spctl -a -vvv -t open --context context:primary-signature "$dmg"
  echo "  → $dmg"
}

# Assembles what the disk image contains: the app, the drop target, the
# background art and the volume icon. Shared so that the image and the layout
# template are always staged from exactly the same contents.
stage_dmg_contents() {
  local app="$1"
  local staging="$2"
  mkdir -p "$staging/.background"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  cp "$ROOT/packaging/dmg/background.tiff" "$staging/.background/background.tiff"
  cp "$ROOT/packaging/dmg/VolumeIcon.icns" "$staging/.VolumeIcon.icns"
}

# Lays out the installer window: the app on the left, a drop target on the
# right, and the artwork from packaging/dmg behind both.
#
# Only `dmg-template` calls this. Scripting Finder needs a logged-in desktop
# session and Automation permission, so it cannot run on a CI runner; the
# .DS_Store it produces is committed and installed instead.
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

  if [[ ! -f "$DMG_TEMPLATE" ]]; then
    echo "error: $DMG_TEMPLATE is missing — the image would open with Finder's" >&2
    echo "       default window instead of the Kapy layout. Regenerate it on a" >&2
    echo "       Mac with a desktop session: packaging/release.sh dmg-template" >&2
    exit 1
  fi

  rm -f "$dmg"
  staging="$(mktemp -d)"
  stage_dmg_contents "$app" "$staging"
  # hdiutil copies dotfiles from the source folder, so the layout is present
  # the moment the volume first mounts. Nothing has to drive Finder.
  cp "$DMG_TEMPLATE" "$staging/.DS_Store"

  # A read-write image with room to spare. It stays read-write only long
  # enough to flag the custom volume icon, which needs a mounted volume.
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
  # fails loudly here instead of silently shipping the wrong image.
  mounted="$(hdiutil attach "$temp_dmg" -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
  if [[ "$mounted" != "/Volumes/$APP_NAME" ]]; then
    echo "error: image mounted at '$mounted', not /Volumes/$APP_NAME" >&2
    hdiutil detach "$mounted" -force >/dev/null 2>&1 || true
    exit 1
  fi

  # Marks the volume as having a custom icon, so .VolumeIcon.icns is used.
  SetFile -a C "$mounted" 2>/dev/null || true
  sync

  # Spotlight or a stray Finder window can still be holding the volume.
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

build_android() {
  info "Android $VERSION ($BUILD_NUMBER) → Google Play"
  "$ROOT/packaging/preflight_android.sh" --archive
  "$FLUTTER" build appbundle --release
  cp "$ROOT/build/app/outputs/bundle/release/app-release.aab" "$OUT/kapy-android.aab"
  # Re-check the copied artifact, so what ships is what was verified.
  "$ROOT/packaging/preflight_android.sh" --bundle "$OUT/kapy-android.aab"
  echo "  → $OUT/kapy-android.aab"
}

# Regenerates the committed window layout by letting Finder write one, then
# lifting the .DS_Store off the mounted volume.
#
# Run it on a Mac with a desktop session — answering yes to the Automation
# prompt — after changing any geometry constant above or the background art,
# and commit the result. Every build afterwards, local or CI, reuses it.
build_dmg_template() {
  local app staging temp_dmg mounted size_mb

  # Finder keys the layout on filenames, so any recent export will do.
  app="$OUT/developerid/$APP_NAME.app"
  [[ -d "$app" ]] || app="$ROOT/build/macos/Build/Products/Release/$APP_NAME.app"
  if [[ ! -d "$app" ]]; then
    echo "error: no $APP_NAME.app to lay out. Build one first:" >&2
    echo "       flutter build macos --release" >&2
    exit 1
  fi

  info "Capturing the DMG window layout"
  staging="$(mktemp -d)"
  stage_dmg_contents "$app" "$staging"
  size_mb=$(( $(du -sm "$staging" | cut -f1) + 60 ))
  temp_dmg="$OUT/$DMG_NAME-template.dmg"
  rm -f "$temp_dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov \
    -format UDRW -fs HFS+ -size "${size_mb}m" "$temp_dmg" >/dev/null
  rm -rf "$staging"

  if [[ -d "/Volumes/$APP_NAME" ]]; then
    hdiutil detach "/Volumes/$APP_NAME" -force >/dev/null 2>&1 || true
  fi
  mounted="$(hdiutil attach "$temp_dmg" -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
  if [[ "$mounted" != "/Volumes/$APP_NAME" ]]; then
    echo "error: image mounted at '$mounted', not /Volumes/$APP_NAME" >&2
    hdiutil detach "$mounted" -force >/dev/null 2>&1 || true
    exit 1
  fi

  if ! apply_dmg_layout "$APP_NAME"; then
    echo "error: could not script Finder. Grant Automation permission to this" >&2
    echo "       terminal under System Settings > Privacy & Security." >&2
    hdiutil detach "$mounted" -force >/dev/null 2>&1 || true
    exit 1
  fi
  sync

  if [[ ! -f "$mounted/.DS_Store" ]]; then
    echo "error: Finder scripted cleanly but wrote no .DS_Store to $mounted" >&2
    hdiutil detach "$mounted" -force >/dev/null 2>&1 || true
    exit 1
  fi
  cp "$mounted/.DS_Store" "$DMG_TEMPLATE"

  hdiutil detach "$mounted" >/dev/null 2>&1 || hdiutil detach "$mounted" -force >/dev/null
  rm -f "$temp_dmg"
  echo "  → $DMG_TEMPLATE ($(stat -f%z "$DMG_TEMPLATE") bytes) — commit this"
}

# An installable-looking image built without any certificate, for CI to hand
# back on every push. Gatekeeper will refuse it on any machine but the one that
# built it — the point is to see the app and the installer window, not to ship.
build_mac_unsigned() {
  info "macOS $VERSION ($BUILD_NUMBER) → unsigned, for testing only"
  prepare_macos
  local app="$ROOT/build/macos/Build/Products/Release/$APP_NAME.app"
  if [[ ! -d "$app" ]]; then
    echo "error: $app missing after a successful build" >&2
    exit 1
  fi
  local dmg="$OUT/$DMG_NAME-$VERSION-unsigned.dmg"
  build_disk_image "$app" "$dmg"
  echo "  → $dmg (unsigned — will not open on another Mac)"
}

case "${1:-mac-direct}" in
  mac-direct)   build_mac_direct ;;
  ios)          build_ios ;;
  mac-store)    build_mac_store ;;
  mac-unsigned) build_mac_unsigned ;;
  android)      build_android ;;
  dmg-template) build_dmg_template ;;
  *)            echo "Usage: $0 [mac-direct|mac-unsigned|ios|mac-store|android|dmg-template]" >&2; exit 1 ;;
esac

info "Done"
