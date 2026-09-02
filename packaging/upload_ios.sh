#!/usr/bin/env bash
#
# Confirms the App Store Connect record and delivers the iOS build.
#
#   packaging/upload_ios.sh confirm   look up the app record, list existing builds
#   packaging/upload_ios.sh validate  run Apple's pre-delivery checks, upload nothing
#   packaging/upload_ios.sh upload    validate, then deliver the IPA
#
# With no argument it runs confirm → validate → upload in that order.
#
# Delivery uses an App Store Connect API key, which needs three things:
#
#   1. A key with the App Manager role, created at App Store Connect →
#      Users and Access → Integrations → App Store Connect API.
#   2. The downloaded AuthKey_<KEYID>.p8 saved to ~/.appstoreconnect/private_keys/.
#      Apple lets you download it exactly once. altool searches that directory
#      by name, so the filename must keep the AuthKey_<KEYID>.p8 form.
#   3. ASC_KEY_ID and ASC_ISSUER_ID, either exported or written to
#      packaging/.asc-credentials (gitignored) as KEY=value lines.
#
# The app record itself cannot be created from here. Apple's API rejects CREATE
# on the apps resource, so the record is made once in the App Store Connect UI.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
IPA="$ROOT/build/release/kapy-ios.ipa"
BUNDLE_ID="com.kapybara.kapynotes"
KEY_DIR="$HOME/.appstoreconnect/private_keys"
CREDS="$ROOT/packaging/.asc-credentials"
MODE="${1:-all}"

case "$MODE" in
  confirm|validate|upload|all) ;;
  *) echo "usage: packaging/upload_ios.sh [confirm|validate|upload]" >&2; exit 2 ;;
esac

# shellcheck source=/dev/null
[[ -f "$CREDS" ]] && source "$CREDS"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
BUILD_NUMBER="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f2)"

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
die() { printf '\033[1;31mfailed:\033[0m %s\n' "$1" >&2; exit 1; }

require_credentials() {
  [[ -n "${ASC_KEY_ID:-}" ]] || die "ASC_KEY_ID is not set. See the header of this script."
  [[ -n "${ASC_ISSUER_ID:-}" ]] || die "ASC_ISSUER_ID is not set. See the header of this script."
  [[ -f "$KEY_DIR/AuthKey_$ASC_KEY_ID.p8" ]] \
    || die "no AuthKey_$ASC_KEY_ID.p8 in $KEY_DIR"
}

require_ipa() {
  [[ -f "$IPA" ]] || die "no IPA at $IPA. Run packaging/release.sh ios first."
}

# altool mints the ES256 token the API expects, which saves reimplementing JWT
# signing here just to read the record back. It prints the token to stderr
# alongside its banner, so the streams are merged and the JWT picked by shape.
asc_get() {
  local path="$1" jwt
  jwt="$(xcrun altool --generate-jwt \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
    --p8-file-path "$KEY_DIR/AuthKey_$ASC_KEY_ID.p8" 2>&1 \
    | grep -oE '^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' | tail -1)"
  [[ -n "$jwt" ]] || die "could not mint an App Store Connect token; check the key values"
  curl -sS -H "Authorization: Bearer $jwt" "https://api.appstoreconnect.apple.com$path"
}

confirm_record() {
  info "App record for $BUNDLE_ID"
  local response app_id app_name
  response="$(asc_get "/v1/apps?filter\[bundleId\]=$BUNDLE_ID")"

  if grep -q '"errors"' <<<"$response"; then
    die "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["errors"][0]["detail"])' <<<"$response")"
  fi

  app_id="$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "")' <<<"$response")"
  if [[ -z "$app_id" ]]; then
    cat >&2 <<EOF
  No record exists for $BUNDLE_ID.

  Create it at https://appstoreconnect.apple.com/apps → + → New App:
    Platform          iOS
    Name              Kapy Notes - Memo & Calculator
    Primary language  English (U.S.)
    Bundle ID         $BUNDLE_ID
    SKU               kapynotes-ios

  Then run this again. The first delivery cannot proceed without the record.
EOF
    exit 1
  fi

  app_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["attributes"]["name"])' <<<"$response")"
  printf '  record    %s (id %s)\n' "$app_name" "$app_id"

  # Every delivery needs a build number no lower-ranked than the last one, so
  # show what App Store Connect already holds before adding to it.
  local builds
  builds="$(asc_get "/v1/builds?filter\[app\]=$app_id&limit=5&sort=-version" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(", ".join(b["attributes"]["version"] for b in d) or "none")')"
  printf '  builds    %s\n' "$builds"
  printf '  staged    %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
}

validate_build() {
  info "Validating $VERSION ($BUILD_NUMBER)"
  xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}

upload_build() {
  info "Uploading $VERSION ($BUILD_NUMBER) to App Store Connect"
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  cat <<EOF

  Delivered. Processing usually takes 5-30 minutes, and App Store Connect
  emails when the build leaves processing. Export compliance still has to be
  answered on the build before it can be attached to the 1.0.0 version.
EOF
}

require_credentials
case "$MODE" in
  confirm) confirm_record ;;
  validate) require_ipa; validate_build ;;
  upload) require_ipa; validate_build; upload_build ;;
  all) require_ipa; confirm_record; validate_build; upload_build ;;
esac
