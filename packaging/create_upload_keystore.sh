#!/usr/bin/env bash
#
# Creates the Google Play upload keystore and the android/key.properties that
# points at it.
#
#   packaging/create_upload_keystore.sh [keystore-path]
#
# Default path is ~/kapynotes-upload.jks, deliberately outside the repo. Both
# the keystore and key.properties are gitignored, and a signing key does not
# belong in version control regardless.
#
# THIS KEY IS NOT RECOVERABLE BY YOU. Play App Signing re-signs the app with
# Google's own key for distribution, but this upload key is how Play recognises
# the uploader. Lose it and shipping an update needs a key reset with Google
# support, which takes days. Back up the .jks file and the password the moment
# this finishes.
#
# The script refuses to overwrite an existing keystore, because doing so would
# silently destroy the only copy of a key that may already be registered with
# Play.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

KEYSTORE="${1:-$HOME/kapynotes-upload.jks}"
ALIAS="upload"
PROPERTIES="$ROOT/android/key.properties"

# A DN is mandatory. Play never shows it to users, but keytool will sit and
# prompt for all six fields without it, which makes this unscriptable.
DNAME="CN=Kapybara LLC, OU=Kapy Notes, O=Kapybara LLC, L=, ST=, C=US"

command -v keytool >/dev/null 2>&1 || {
  echo "keytool not found. It ships with the JDK; Android Studio installs one." >&2
  exit 1
}

if [[ -e "$KEYSTORE" ]]; then
  echo "A keystore already exists at $KEYSTORE" >&2
  echo "Refusing to overwrite it. If this is the key Play knows, keep it." >&2
  exit 1
fi

if [[ -e "$PROPERTIES" ]]; then
  echo "android/key.properties already exists. Delete it first if you meant to start over." >&2
  exit 1
fi

echo "Creating the Kapy Notes upload keystore"
echo "  keystore: $KEYSTORE"
echo "  alias:    $ALIAS"
echo
echo "Choose a password you can retrieve later. A password manager entry is the"
echo "right place; it is needed for every release build from now on."
echo

# read -s keeps the password off the screen and out of shell history, which is
# why this is not a command-line argument.
read -r -s -p "Password: " PASSWORD
echo
read -r -s -p "Confirm:  " CONFIRM
echo

[[ -n "$PASSWORD" ]] || { echo "Password cannot be empty." >&2; exit 1; }
[[ "$PASSWORD" == "$CONFIRM" ]] || { echo "Passwords do not match." >&2; exit 1; }
# Java's keystore format enforces this and the error it gives is cryptic.
(( ${#PASSWORD} >= 6 )) || { echo "Password must be at least 6 characters." >&2; exit 1; }

keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -dname "$DNAME" \
  -storepass "$PASSWORD" \
  -keypass "$PASSWORD" >/dev/null

chmod 600 "$KEYSTORE"

# The store and key passwords are the same above, so both fields get it here.
umask 077
cat > "$PROPERTIES" <<PROPS
storeFile=$KEYSTORE
storePassword=$PASSWORD
keyAlias=$ALIAS
keyPassword=$PASSWORD
PROPS

echo
echo "Created $KEYSTORE"
echo "Created android/key.properties"
echo
echo "Fingerprint Play will show under App integrity:"
keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" -storepass "$PASSWORD" 2>/dev/null |
  grep -E "SHA1:|SHA256:" | sed 's/^/  /'
echo
echo "Back up $KEYSTORE and its password now, somewhere that survives this Mac."
echo "Then: packaging/release.sh android"
