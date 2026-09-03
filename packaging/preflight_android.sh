#!/usr/bin/env bash
#
# Read-only Google Play preflight for the Kapy Notes Android build.
#
#   packaging/preflight_android.sh                repo and toolchain checks
#   packaging/preflight_android.sh --archive      also require release signing
#   packaging/preflight_android.sh --submission   also require listing assets
#   packaging/preflight_android.sh --bundle FILE  inspect a built .aab
#
# The single most important check here is that a bundle is not signed with the
# debug key. Gradle falls back to the debug key when android/key.properties is
# missing, so `flutter build appbundle` always succeeds; Play then rejects the
# upload, or worse, a debug-signed artifact gets published to a track.
#
# The application ID is verified too, because it is permanent. Play has no
# rename: a wrong ID on the first upload means a new listing, losing installs,
# ratings and reviews.

set -u

cd "$(dirname "$0")/.."
ROOT="$PWD"
MODE="${1:-}"
BUNDLE_ARG="${2:-}"
FLUTTER="${FLUTTER:-$HOME/development/flutter/bin/flutter}"

APPLICATION_ID="com.kapybara.kapynotes"
GRADLE="$ROOT/android/app/build.gradle.kts"
KEY_PROPERTIES="$ROOT/android/key.properties"
PLAY_ASSETS="$ROOT/build/store-listing/play-store"

case "$MODE" in
  ""|--archive|--submission|--bundle) ;;
  *) echo "usage: packaging/preflight_android.sh [--archive|--submission|--bundle FILE]" >&2
     exit 2 ;;
esac

failures=0
warnings=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }
warn() { printf '  WARN  %s\n' "$1" >&2; warnings=$((warnings + 1)); }

# Escalate to a failure only in the modes where the thing is actually required.
require_for() {
  local required_mode="$1" message="$2"
  if [[ "$MODE" == "$required_mode" || "$MODE" == "--submission" ]]; then
    fail "$message"
  else
    warn "$message"
  fi
}

echo "Kapy Notes Google Play preflight"

# ---------------------------------------------------------------- bundle mode
if [[ "$MODE" == "--bundle" ]]; then
  echo
  echo "Bundle"
  bundle="$BUNDLE_ARG"
  [[ -n "$bundle" ]] || { fail "--bundle needs a path to an .aab"; exit 1; }

  if [[ ! -f "$bundle" ]]; then
    fail "no bundle at $bundle"
    exit 1
  fi
  pass "$(basename "$bundle") is $(( $(stat -f%z "$bundle") / 1024 / 1024 )) MB"

  if ! command -v jarsigner >/dev/null 2>&1; then
    warn "jarsigner not on PATH, cannot verify the signature"
  else
    signers="$(jarsigner -verify -verbose:summary -certs "$bundle" 2>&1)"
    if grep -q "jar verified" <<<"$signers"; then
      pass "bundle signature verifies"
    else
      fail "bundle signature does not verify"
    fi
    # The Flutter/Android debug key is always CN=Android Debug.
    if grep -qi "CN=Android Debug" <<<"$signers"; then
      fail "bundle is signed with the DEBUG key and must not be uploaded"
    else
      pass "bundle is not debug-signed"
    fi
  fi
  echo
  if (( failures )); then
    echo "Bundle preflight failed with $failures failure(s)." >&2
    exit 1
  fi
  echo "Bundle preflight passed with $warnings warning(s)."
  exit 0
fi

# ------------------------------------------------------------------ toolchain
echo
echo "Toolchain"
if [[ -x "$FLUTTER" ]]; then
  pass "Flutter at $FLUTTER"
else
  fail "no Flutter at $FLUTTER (override with FLUTTER=...)"
fi
if command -v jarsigner >/dev/null 2>&1; then
  pass "jarsigner available for signature checks"
else
  warn "jarsigner not on PATH; signing cannot be verified"
fi

# -------------------------------------------------------------- configuration
echo
echo "Bundle configuration"
if [[ -f "$GRADLE" ]]; then
  pass "android/app/build.gradle.kts present"

  actual_id="$(sed -n 's/.*applicationId = "\(.*\)".*/\1/p' "$GRADLE" | head -1)"
  if [[ "$actual_id" == "$APPLICATION_ID" ]]; then
    pass "application ID is $APPLICATION_ID"
  else
    fail "application ID is '$actual_id', expected '$APPLICATION_ID' (permanent once uploaded)"
  fi

  actual_ns="$(sed -n 's/.*namespace = "\(.*\)".*/\1/p' "$GRADLE" | head -1)"
  if [[ "$actual_ns" == "$APPLICATION_ID" ]]; then
    pass "namespace matches the application ID"
  else
    warn "namespace is '$actual_ns', application ID is '$APPLICATION_ID'"
  fi

  if grep -q 'signingConfigs.getByName("debug")' "$GRADLE" \
     && ! grep -q 'hasReleaseKeystore' "$GRADLE"; then
    fail "release build type is hard-wired to the debug signing config"
  else
    pass "release build type resolves a real signing config"
  fi
else
  fail "no android/app/build.gradle.kts"
fi

version_line="$(grep -m1 '^version:' "$ROOT/pubspec.yaml" 2>/dev/null | sed 's/version: *//')"
if [[ -n "$version_line" ]]; then
  pass "version ${version_line%%+*} (${version_line##*+}) from pubspec.yaml"
else
  fail "no version in pubspec.yaml"
fi

manifest="$ROOT/android/app/src/main/AndroidManifest.xml"
if [[ -f "$manifest" ]]; then
  if grep -q 'android:debuggable="true"' "$manifest"; then
    fail "AndroidManifest.xml sets android:debuggable=true"
  else
    pass "AndroidManifest.xml does not force debuggable"
  fi
  # Flutter only puts INTERNET in the debug and profile manifests. Without it
  # in main, a release build silently fails every exchange-rate refresh.
  if grep -q 'android.permission.INTERNET' "$manifest"; then
    pass "INTERNET is declared in the release manifest"
  else
    fail "INTERNET is missing from main/AndroidManifest.xml; rate refresh will fail in release"
  fi
  # url_launcher needs an ACTION_VIEW/https query to see a browser under
  # Android 11 package visibility.
  if grep -q 'android.intent.action.VIEW' "$manifest"; then
    pass "ACTION_VIEW query present for the attribution link"
  else
    fail "no ACTION_VIEW/https query; url_launcher cannot open the rate-source link"
  fi
  permissions="$(sed -n 's/.*uses-permission android:name="\([^"]*\)".*/\1/p' "$manifest" | sort -u)"
  pass "declared permissions: $(tr '\n' ' ' <<<"$permissions")"
else
  fail "no android/app/src/main/AndroidManifest.xml"
fi

# ------------------------------------------------------------------- signing
echo
echo "Release signing"
if [[ -f "$KEY_PROPERTIES" ]]; then
  pass "android/key.properties present"
  store_file="$(sed -n 's/^storeFile=//p' "$KEY_PROPERTIES" | head -1)"
  if [[ -z "$store_file" ]]; then
    fail "key.properties has no storeFile"
  elif [[ -f "$store_file" ]]; then
    pass "keystore exists at $store_file"
  else
    fail "keystore missing at '$store_file'"
  fi
  for field in storePassword keyAlias keyPassword; do
    if grep -q "^$field=." "$KEY_PROPERTIES"; then
      pass "$field is set"
    else
      fail "$field is empty in key.properties"
    fi
  done
  if git -C "$ROOT" check-ignore -q android/key.properties 2>/dev/null; then
    pass "key.properties is gitignored"
  else
    fail "key.properties is NOT gitignored"
  fi
else
  require_for --archive "no android/key.properties; see android/key.properties.example"
fi

# ---------------------------------------------------------------- listing art
if [[ "$MODE" == "--submission" ]]; then
  echo
  echo "Play listing assets"
  for set_name in phone tablet-7 tablet-10; do
    dir="$PLAY_ASSETS/$set_name"
    count=$(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ')
    # Play requires between 2 and 8 screenshots per form factor.
    if (( count >= 2 && count <= 8 )); then
      pass "$set_name has $count screenshots"
    else
      fail "$set_name has $count screenshots, Play wants between 2 and 8"
    fi
  done

  # The icon and the feature graphic are the two listing assets the app build
  # never produces, so they are the two most likely to be missing on the day.
  # Both come from packaging/play_graphics.mjs. Play is strict about the alpha
  # channel in opposite directions: the icon must carry one, the feature
  # graphic must not.
  check_graphic() {
    local file="$1" label="$2" want_w="$3" want_h="$4" want_alpha="$5" max_kb="$6"

    if [[ ! -f "$file" ]]; then
      fail "no $label; run: node packaging/play_graphics.mjs"
      return
    fi

    local width height alpha size_kb
    width=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    alpha=$(sips -g hasAlpha "$file" 2>/dev/null | awk '/hasAlpha/ {print $2}')
    size_kb=$(( $(stat -f%z "$file") / 1024 ))

    if [[ "$width" == "$want_w" && "$height" == "$want_h" ]]; then
      pass "$label is ${width}x${height}"
    else
      fail "$label is ${width}x${height}, Play wants ${want_w}x${want_h}"
    fi

    if [[ "$alpha" == "$want_alpha" ]]; then
      pass "$label alpha channel is correct (hasAlpha=$alpha)"
    else
      fail "$label has hasAlpha=$alpha, Play wants $want_alpha"
    fi

    if (( size_kb <= max_kb )); then
      pass "$label is ${size_kb} KB"
    else
      fail "$label is ${size_kb} KB, over the ${max_kb} KB limit"
    fi
  }

  check_graphic "$PLAY_ASSETS/icon-512.png" "store icon" 512 512 yes 1024
  check_graphic "$PLAY_ASSETS/feature-graphic.png" "feature graphic" 1024 500 no 15360
fi

echo
if (( failures )); then
  echo "Preflight failed with $failures failure(s) and $warnings warning(s)." >&2
  exit 1
fi
echo "Preflight passed with $warnings warning(s)."
