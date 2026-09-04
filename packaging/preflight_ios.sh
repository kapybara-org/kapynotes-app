#!/usr/bin/env bash
#
# Read-only App Store preflight for the universal Kapy Notes iOS target.
#
#   packaging/preflight_ios.sh               repo and toolchain checks
#   packaging/preflight_ios.sh --archive     also require distribution signing
#   packaging/preflight_ios.sh --submission  also require live URLs/screenshots

set -u

cd "$(dirname "$0")/.."
ROOT="$PWD"
MODE="${1:-}"
FLUTTER="${FLUTTER:-$HOME/development/flutter/bin/flutter}"

case "$MODE" in
  ""|--archive|--submission) ;;
  *) echo "usage: packaging/preflight_ios.sh [--archive|--submission]" >&2; exit 2 ;;
esac

failures=0
warnings=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }
warn() { printf '  WARN  %s\n' "$1" >&2; warnings=$((warnings + 1)); }

require_for() {
  local required_mode="$1" message="$2"
  if [[ "$MODE" == "$required_mode" || "$MODE" == "--submission" ]]; then
    fail "$message"
  else
    warn "$message"
  fi
}

setting() {
  local key="$1"
  printf '%s\n' "$BUILD_SETTINGS" \
    | sed -n "s/^[[:space:]]*$key = //p" \
    | head -1
}

image_property() {
  local path="$1" property="$2"
  sips -g "$property" "$path" 2>/dev/null \
    | sed -n "s/^[[:space:]]*$property: //p"
}

check_image() {
  local path="$1" width="$2" height="$3" alpha="$4"
  if [[ ! -f "$path" ]]; then
    fail "missing image $path"
    return
  fi

  local actual_width actual_height actual_alpha
  actual_width="$(image_property "$path" pixelWidth)"
  actual_height="$(image_property "$path" pixelHeight)"
  actual_alpha="$(image_property "$path" hasAlpha)"
  if [[ "$actual_width" == "$width" && "$actual_height" == "$height" && "$actual_alpha" == "$alpha" ]]; then
    pass "$path is ${width}x${height}, alpha $alpha"
  else
    fail "$path is ${actual_width}x${actual_height}, alpha $actual_alpha; expected ${width}x${height}, alpha $alpha"
  fi
}

printf 'Kapy Notes iOS App Store preflight\n\n'

printf 'Toolchain\n'
if command -v xcodebuild >/dev/null && command -v xcrun >/dev/null; then
  XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
  IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
  if [[ "${XCODE_VERSION%%.*}" -ge 26 && "${IOS_SDK_VERSION%%.*}" -ge 26 ]]; then
    pass "Xcode $XCODE_VERSION with iOS SDK $IOS_SDK_VERSION meets the current upload floor"
  else
    fail "Xcode 26+ and the iOS 26+ SDK are required; found Xcode $XCODE_VERSION / iOS SDK $IOS_SDK_VERSION"
  fi
else
  fail "Xcode command-line tools are unavailable"
fi

if [[ -x "$FLUTTER" ]]; then
  FLUTTER_VERSION="$($FLUTTER --version | awk 'NR == 1 { print $2 }')"
  pass "Flutter $FLUTTER_VERSION at $FLUTTER"
else
  fail "Flutter executable not found at $FLUTTER"
fi

printf '\nBundle configuration\n'
for plist in \
  ios/Runner/Info.plist \
  ios/Runner/PrivacyInfo.xcprivacy \
  packaging/ExportOptions-ios-appstore.plist
do
  if plutil -lint "$plist" >/dev/null; then
    pass "$plist parses"
  else
    fail "$plist is invalid"
  fi
done
for catalog in \
  ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json \
  ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json \
  ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json
do
  if python3 -m json.tool "$catalog" >/dev/null; then
    pass "$catalog parses"
  else
    fail "$catalog is invalid"
  fi
done

DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw ios/Runner/Info.plist 2>/dev/null || true)"
EXPORT_COMPLIANCE="$(plutil -extract ITSAppUsesNonExemptEncryption raw ios/Runner/Info.plist 2>/dev/null || true)"
if [[ "$DISPLAY_NAME" == "Kapy Notes" ]]; then
  pass "Home Screen name is Kapy Notes"
else
  fail "CFBundleDisplayName is '$DISPLAY_NAME', expected 'Kapy Notes'"
fi
if [[ "$EXPORT_COMPLIANCE" == "false" ]]; then
  pass "non-exempt encryption is declared false"
else
  fail "ITSAppUsesNonExemptEncryption must be false for this network-only build"
fi
if plutil -extract UIRequiresFullScreen raw ios/Runner/Info.plist >/dev/null 2>&1; then
  fail "UIRequiresFullScreen is present; the iPad target must remain resizable"
else
  pass "iPad remains resizable and multitasking-capable"
fi

VERSION_LINE="$(grep -m1 '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//')"
VERSION_NAME="${VERSION_LINE%%+*}"
BUILD_NUMBER="${VERSION_LINE#*+}"
if [[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  pass "version $VERSION_NAME ($BUILD_NUMBER) is valid"
else
  fail "pubspec version '$VERSION_LINE' must be semantic version plus a positive build number"
fi

BUILD_SETTINGS="$(xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -showBuildSettings 2>/dev/null || true)"
if [[ "$(setting PRODUCT_BUNDLE_IDENTIFIER)" == "com.kapybara.kapynotes" ]]; then
  pass "bundle ID is com.kapybara.kapynotes"
else
  fail "unexpected PRODUCT_BUNDLE_IDENTIFIER: $(setting PRODUCT_BUNDLE_IDENTIFIER)"
fi
if [[ "$(setting DEVELOPMENT_TEAM)" == "96V66447C6" ]]; then
  pass "development team is Kapybara LLC (96V66447C6)"
else
  fail "unexpected DEVELOPMENT_TEAM: $(setting DEVELOPMENT_TEAM)"
fi
DEVICE_FAMILY="$(setting TARGETED_DEVICE_FAMILY | tr -d ' ')"
if [[ "$DEVICE_FAMILY" == "1,2" ]]; then
  pass "target is universal for iPhone and iPad"
else
  fail "TARGETED_DEVICE_FAMILY is '$DEVICE_FAMILY', expected '1,2'"
fi
if [[ "$(setting SDK_VERSION)" == 26.* || "$(setting SDKROOT)" == *iPhoneOS26.* ]]; then
  pass "Release target resolves to the iOS 26 SDK"
else
  fail "Release target is not resolving to the iOS 26 SDK"
fi

printf '\nPrivacy and native resources\n'
PRIVACY_TRACKING="$(plutil -extract NSPrivacyTracking raw ios/Runner/PrivacyInfo.xcprivacy 2>/dev/null || true)"
PRIVACY_COLLECTED_COUNT="$(plutil -extract NSPrivacyCollectedDataTypes raw ios/Runner/PrivacyInfo.xcprivacy 2>/dev/null || true)"
PRIVACY_TRACKING_DOMAIN_COUNT="$(plutil -extract NSPrivacyTrackingDomains raw ios/Runner/PrivacyInfo.xcprivacy 2>/dev/null || true)"
PRIVACY_APIS="$(plutil -extract NSPrivacyAccessedAPITypes json -o - ios/Runner/PrivacyInfo.xcprivacy 2>/dev/null || true)"
if [[ "$PRIVACY_TRACKING" == "false" && "$PRIVACY_COLLECTED_COUNT" == "0" && "$PRIVACY_TRACKING_DOMAIN_COUNT" == "0" ]]; then
  pass "privacy manifest declares no tracking and no collected data"
else
  fail "privacy manifest must declare no tracking, tracking domains, or collected data"
fi
for category in FileTimestamp DiskSpace UserDefaults; do
  if [[ "$PRIVACY_APIS" == *"NSPrivacyAccessedAPICategory$category"* ]]; then
    pass "privacy manifest includes the $category required-reason category"
  else
    fail "privacy manifest is missing $category required-reason coverage"
  fi
done
if rg -q 'PrivacyInfo\.xcprivacy in Resources' ios/Runner.xcodeproj/project.pbxproj; then
  pass "Runner embeds its privacy manifest"
else
  fail "Runner target does not embed PrivacyInfo.xcprivacy"
fi
if SEED_SELECTED=math python3 packaging/screenshot_seed.py | python3 -c '
import json, sys, time
seed = json.load(sys.stdin)
rates = seed["rates.v1"]
fresh = abs((time.time() * 1000) - rates["fetchedAt"]) < 60_000
frozen = rates["rates"].get("EUR") == 0.861401
raise SystemExit(0 if fresh and frozen else 1)
'; then
  pass "screenshot seed keeps its frozen rates fresh without a network refresh"
else
  fail "screenshot seed rates are stale or changed"
fi

LAUNCH_COMPILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kapynotes-launch.XXXXXX")"
trap 'rm -rf "$LAUNCH_COMPILE_DIR"' EXIT
if ibtool --errors --warnings --notices \
  --compile "$LAUNCH_COMPILE_DIR/LaunchScreen.storyboardc" \
  ios/Runner/Base.lproj/LaunchScreen.storyboard >/dev/null; then
  pass "adaptive iPhone/iPad launch storyboard compiles"
else
  fail "launch storyboard does not compile"
fi
if [[ "$(grep -c '"appearance" : "luminosity"' ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json)" -eq 1 ]]; then
  pass "launch background has a dark appearance variant"
else
  fail "launch background needs light and dark appearance variants"
fi

printf '\nApp icon and launch artwork\n'
check_image ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png 1024 1024 no
check_image ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png 112 112 yes
check_image ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png 224 224 yes
check_image ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png 336 336 yes

printf '\nSubmission dependencies\n'
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$IDENTITIES" == *"Apple Distribution:"*"(96V66447C6)"* ]]; then
  pass "Apple Distribution identity for Kapybara LLC is installed"
else
  require_for --archive "Apple Distribution identity for team 96V66447C6 is not installed"
fi

for url in \
  https://kapynotes.com/ \
  https://kapynotes.com/privacy \
  https://kapynotes.com/support \
  https://kapynotes.com/terms
do
  if curl --location --silent --show-error --fail \
    --connect-timeout 8 --max-time 20 --output /dev/null "$url"; then
    pass "$url is live"
  elif [[ "$MODE" == "--submission" ]]; then
    fail "$url is not reachable"
  else
    warn "$url is not reachable"
  fi
done

check_screenshot_set() {
  local directory="$1" width="$2" height="$3" label="$4"
  local count image actual_width actual_height actual_alpha
  count="$(find "$directory" -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -lt 1 || "$count" -gt 10 ]]; then
    if [[ "$MODE" == "--submission" ]]; then
      fail "$label needs 1 to 10 screenshots; found $count"
    else
      warn "$label needs 1 to 10 screenshots; found $count"
    fi
    return
  fi

  while IFS= read -r image; do
    actual_width="$(image_property "$image" pixelWidth)"
    actual_height="$(image_property "$image" pixelHeight)"
    actual_alpha="$(image_property "$image" hasAlpha)"
    if [[ "$actual_width" != "$width" || "$actual_height" != "$height" || "$actual_alpha" != "no" ]]; then
      fail "$image is ${actual_width}x${actual_height}, alpha $actual_alpha; expected ${width}x${height}, alpha no"
      return
    fi
  done < <(find "$directory" -maxdepth 1 -type f -name '*.png' | sort)
  pass "$label has $count opaque screenshots at ${width}x${height}"
}

check_screenshot_set build/screenshots/iphone-6.9 1320 2868 'iPhone 6.9-inch set'
check_screenshot_set build/screenshots/ipad-13 2064 2752 'iPad 13-inch set'

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Preflight failed with %d failure(s) and %d warning(s).\n' "$failures" "$warnings" >&2
  exit 1
fi

printf 'Preflight passed with %d warning(s).\n' "$warnings"
