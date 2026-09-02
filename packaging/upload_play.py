#!/usr/bin/env python3
#
# Confirms the Play Console listing and delivers the Android App Bundle.
#
#   packaging/upload_play.py confirm    show the tracks and the version codes on them
#   packaging/upload_play.py validate   run the bundle preflight, upload nothing
#   packaging/upload_play.py upload     validate, then deliver to a track
#
# With no argument it runs confirm -> validate -> upload in that order.
#
#   --track internal|alpha|beta|production   default: internal
#   --bundle PATH                            default: build/release/kapy-android.aab
#
# The default track is deliberately `internal`. It is visible only to testers
# you name, so a first delivery cannot land in front of real users by accident.
# Promote from the Play Console once the build has been checked on a device.
#
# Delivery needs a Google Cloud service account with Play Console access:
#
#   1. In Google Cloud, create a service account and download its JSON key.
#   2. In Play Console -> Users and permissions, invite that service account's
#      email and grant it release permissions for this app.
#   3. Save the JSON key to packaging/.play-credentials.json (gitignored), or
#      point GOOGLE_PLAY_SERVICE_ACCOUNT at it.
#
# Like App Store Connect, the Play API cannot create the listing. The app has
# to exist in the Play Console before the first upload, and its package name is
# permanent from that moment on.

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PACKAGE_NAME = "com.kapybara.kapynotes"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3"
UPLOAD_API = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BUNDLE = os.path.join(ROOT, "build", "release", "kapy-android.aab")
CREDENTIALS = os.environ.get(
    "GOOGLE_PLAY_SERVICE_ACCOUNT",
    os.path.join(ROOT, "packaging", ".play-credentials.json"),
)
VALID_TRACKS = ("internal", "alpha", "beta", "production")

BLUE, BOLD, RED, RESET = "\033[1;34m", "\033[1m", "\033[1;31m", "\033[0m"


def info(message):
    print(f"\n{BLUE}==>{RESET} {BOLD}{message}{RESET}", flush=True)


def die(message):
    print(f"{RED}failed:{RESET} {message}", file=sys.stderr)
    raise SystemExit(1)


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def access_token() -> str:
    """Mint an OAuth2 token from the service account key.

    The RS256 signature is produced by openssl rather than a Python crypto
    package, so this script keeps to the standard library.
    """
    if not os.path.exists(CREDENTIALS):
        die(f"no service account key at {CREDENTIALS}. See the header of this script.")
    with open(CREDENTIALS) as handle:
        account = json.load(handle)
    for field in ("client_email", "private_key"):
        if not account.get(field):
            die(f"service account key is missing '{field}'")

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": account["client_email"],
        "scope": SCOPE,
        "aud": TOKEN_URL,
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"

    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as key_file:
        key_file.write(account["private_key"])
        key_path = key_file.name
    try:
        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=signing_input.encode(), capture_output=True,
        )
        if signed.returncode != 0:
            die(f"openssl could not sign the token: {signed.stderr.decode().strip()}")
    finally:
        os.unlink(key_path)

    assertion = f"{signing_input}.{b64url(signed.stdout)}"
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=body)) as response:
            return json.loads(response.read().decode())["access_token"]
    except urllib.error.HTTPError as error:
        die(f"token exchange rejected the key: {error.read().decode()[:300]}")


TOKEN = None


def call(method, url, *, body=None, data=None, content_type=None):
    global TOKEN
    if TOKEN is None:
        TOKEN = access_token()
    payload = data if data is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Authorization", "Bearer " + TOKEN)
    if content_type:
        request.add_header("Content-Type", content_type)
    elif body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode()
        try:
            message = json.loads(detail)["error"]["message"]
        except Exception:
            message = detail[:400]
        die(f"{method} {url.split('?')[0]}\n  {message}")


def pubspec_version():
    name, code = None, None
    try:
        for line in open(os.path.join(ROOT, "pubspec.yaml")):
            if line.startswith("version:"):
                value = line.split(":", 1)[1].strip()
                name, _, code = value.partition("+")
    except OSError:
        pass
    return name, code


def confirm(track):
    info(f"Play listing for {PACKAGE_NAME}")
    edit = call("POST", f"{API}/applications/{PACKAGE_NAME}/edits", body={})
    edit_id = edit["id"]
    try:
        tracks = call("GET", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/tracks")
        found = False
        for entry in tracks.get("tracks", []):
            codes = sorted(
                code
                for release in entry.get("releases", [])
                for code in release.get("versionCodes", []) or []
            )
            statuses = {r.get("status") for r in entry.get("releases", [])}
            print(f"  {entry['track']:<12} {', '.join(map(str, codes)) or 'no builds':<22} "
                  f"{', '.join(sorted(s for s in statuses if s))}")
            found = True
        if not found:
            print("  no tracks carry a release yet")
    finally:
        # Confirm is read-only; drop the edit rather than leave it dangling.
        call("DELETE", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}")

    name, code = pubspec_version()
    print(f"  staged      {name} ({code}) -> {track}")


def validate(bundle):
    info(f"Validating {os.path.basename(bundle)}")
    preflight = os.path.join(ROOT, "packaging", "preflight_android.sh")
    result = subprocess.run([preflight, "--bundle", bundle])
    if result.returncode != 0:
        die("bundle preflight failed; nothing was uploaded")


def upload(bundle, track):
    name, _ = pubspec_version()
    info(f"Uploading {os.path.basename(bundle)} to '{track}'")
    edit = call("POST", f"{API}/applications/{PACKAGE_NAME}/edits", body={})
    edit_id = edit["id"]

    with open(bundle, "rb") as handle:
        blob = handle.read()
    uploaded = call(
        "POST",
        f"{UPLOAD_API}/applications/{PACKAGE_NAME}/edits/{edit_id}/bundles?uploadType=media",
        data=blob, content_type="application/octet-stream",
    )
    version_code = uploaded["versionCode"]
    print(f"  bundle accepted as versionCode {version_code}")

    call(
        "PUT",
        f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/tracks/{track}",
        body={"track": track,
              "releases": [{"name": name, "versionCodes": [str(version_code)],
                            "status": "completed"}]},
    )
    print(f"  assigned to the {track} track")

    call("POST", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}:commit")
    print(f"""
  Delivered. Play processes the bundle in a few minutes, and the Console shows
  it under Release -> Testing -> {track}. Promote it from there once you have
  installed it on a device.""")


def main():
    args = sys.argv[1:]
    mode, track, bundle = "all", "internal", DEFAULT_BUNDLE
    index = 0
    while index < len(args):
        argument = args[index]
        if argument in ("confirm", "validate", "upload", "all"):
            mode = argument
        elif argument == "--track":
            index += 1
            track = args[index] if index < len(args) else ""
        elif argument == "--bundle":
            index += 1
            bundle = args[index] if index < len(args) else ""
        else:
            die(f"unknown argument '{argument}'")
        index += 1

    if track not in VALID_TRACKS:
        die(f"track must be one of {', '.join(VALID_TRACKS)}")
    if mode in ("validate", "upload", "all") and not os.path.exists(bundle):
        die(f"no bundle at {bundle}. Run packaging/release.sh android first.")

    if mode in ("confirm", "all"):
        confirm(track)
    if mode in ("validate", "upload", "all"):
        validate(bundle)
    if mode in ("upload", "all"):
        upload(bundle, track)


if __name__ == "__main__":
    main()
