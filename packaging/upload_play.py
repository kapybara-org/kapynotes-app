#!/usr/bin/env python3
#
# Confirms the Play Console listing and delivers the Android App Bundle.
#
#   packaging/upload_play.py confirm    show the tracks and the version codes on them
#   packaging/upload_play.py listing    push the store listing copy and graphics
#   packaging/upload_play.py validate   run the bundle preflight, upload nothing
#   packaging/upload_play.py upload     validate, then deliver to a track
#   packaging/upload_play.py promote    move an uploaded build to a wider track
#
#   --track internal|alpha|beta|production   alpha is closed testing, beta open
#   --rollout 0.2                            staged release, promote only
#
# Play refuses to accept a version code it has already seen, so a build cannot
# be re-uploaded to reach a wider track; promote reassigns the existing code
# instead. That also means users install the exact bytes that were tested.
#
#   packaging/upload_play.py promote --track beta
#   packaging/upload_play.py promote --track production --rollout 0.2
#
# With no argument it runs confirm -> validate -> upload in that order. `listing`
# is deliberately not in that sequence: listing copy changes far less often than
# builds do, and it is the one operation that overwrites text a human may have
# edited in the Console.
#
# The listing copy is read from packaging/play_listing.json, which is what
# actually gets pushed. SUBMISSION.md carries the same text for review; if you
# edit one, edit the other.
#
# What the API cannot do: the App content declarations. Data Safety, the
# content rating questionnaire, target audience, ads and app access are all
# Console-only, because they are attestations the developer makes rather than
# data about the build. Their settled answers are in SUBMISSION.md.
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


class PlayError(Exception):
    """An API error the caller wants to inspect rather than die on."""


def call(method, url, *, body=None, data=None, content_type=None, soft=False):
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
        if soft:
            raise PlayError(message)
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


LISTING_JSON = os.path.join(ROOT, "packaging", "play_listing.json")
PLAY_ASSETS = os.path.join(ROOT, "build", "store-listing", "play-store")

# Play's own names for the image slots, mapped to where the renderer puts them.
# A directory means every PNG in it, in filename order, which is the order Play
# shows them in; that is why the files are numbered.
IMAGE_SLOTS = [
    ("icon", os.path.join(PLAY_ASSETS, "icon-512.png")),
    ("featureGraphic", os.path.join(PLAY_ASSETS, "feature-graphic.png")),
    ("phoneScreenshots", os.path.join(PLAY_ASSETS, "phone")),
    ("sevenInchScreenshots", os.path.join(PLAY_ASSETS, "tablet-7")),
    ("tenInchScreenshots", os.path.join(PLAY_ASSETS, "tablet-10")),
]

# Play truncates silently rather than refusing, so a copy overrun would ship as
# a half sentence. Check before sending, not after.
COPY_LIMITS = {"title": 30, "shortDescription": 80, "fullDescription": 4000}


def listing_copy():
    if not os.path.exists(LISTING_JSON):
        die(f"no listing copy at {LISTING_JSON}")
    with open(LISTING_JSON) as handle:
        copy = json.load(handle)
    for field, limit in COPY_LIMITS.items():
        value = copy.get(field) or ""
        if not value:
            die(f"{field} is empty in play_listing.json")
        if len(value) > limit:
            die(f"{field} is {len(value)} characters, over Play's limit of {limit}")
    return copy


def push_listing():
    copy = listing_copy()
    language = copy.get("language", "en-US")
    info(f"Pushing the {language} listing for {PACKAGE_NAME}")

    for field, limit in COPY_LIMITS.items():
        print(f"  {field:<18} {len(copy[field]):>5} / {limit}")

    edit = call("POST", f"{API}/applications/{PACKAGE_NAME}/edits", body={})
    edit_id = edit["id"]
    committed = False
    try:
        call(
            "PUT",
            f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/details",
            body={
                "defaultLanguage": language,
                "contactEmail": copy["contactEmail"],
                "contactWebsite": copy["contactWebsite"],
            },
        )
        print("  contact details set")

        call(
            "PUT",
            f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/listings/{language}",
            body={
                "language": language,
                "title": copy["title"],
                "shortDescription": copy["shortDescription"],
                "fullDescription": copy["fullDescription"],
            },
        )
        print("  title, short and full description set")

        for slot, source in IMAGE_SLOTS:
            if os.path.isdir(source):
                files = sorted(
                    os.path.join(source, name)
                    for name in os.listdir(source)
                    if name.endswith(".png")
                )
            elif os.path.exists(source):
                files = [source]
            else:
                die(f"missing {slot} asset at {source}; run node packaging/play_graphics.mjs")

            # Replace rather than append, so re-running does not stack up
            # duplicate screenshots on the listing.
            call(
                "DELETE",
                f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/listings/{language}/{slot}",
            )
            for path in files:
                with open(path, "rb") as handle:
                    call(
                        "POST",
                        f"{UPLOAD_API}/applications/{PACKAGE_NAME}/edits/{edit_id}"
                        f"/listings/{language}/{slot}?uploadType=media",
                        data=handle.read(),
                        content_type="image/png",
                    )
            print(f"  {slot:<22} {len(files)} image(s)")

        call("POST", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}:commit")
        committed = True
        print("\n  Listing committed. It is a draft until the app is published.")
    finally:
        if not committed:
            call("DELETE", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}")


def promote(version_code, track, rollout):
    """Move an already-uploaded build to another track.

    Play refuses a second upload of a version code that already exists, so a
    build cannot be re-sent to reach a wider track. Promotion is a different
    call: it assigns the existing code to another track, which is also what
    keeps the artifact users install byte-identical to the one already tested.
    """
    if rollout is not None and not 0 < rollout <= 1:
        die("--rollout takes a fraction between 0 and 1, for example 0.2")

    target = f"{track} at {round(rollout * 100)}%" if rollout and rollout < 1 else track
    info(f"Promoting version code {version_code} to {target}")

    edit = call("POST", f"{API}/applications/{PACKAGE_NAME}/edits", body={})
    edit_id = edit["id"]
    committed = False
    try:
        # Confirm the code exists somewhere first. Play accepts a track update
        # naming an unknown version code and simply produces an empty release,
        # which looks like success and ships nothing.
        tracks = call("GET", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/tracks")
        known = {
            str(code)
            for entry in tracks.get("tracks", [])
            for release in entry.get("releases", [])
            for code in release.get("versionCodes", []) or []
        }
        if str(version_code) not in known:
            die(
                f"version code {version_code} is not on any track yet. "
                f"Known: {', '.join(sorted(known)) or 'none'}. Upload it first."
            )

        notes = listing_copy().get("releaseNotes")

        def build_release(status):
            release = {"versionCodes": [str(version_code)], "status": status}
            # userFraction is only meaningful while a release is in progress;
            # Play rejects it on any other status.
            if status == "inProgress":
                release["userFraction"] = rollout
            if notes:
                release["releaseNotes"] = [{"language": "en-US", "text": notes}]
            return release

        if rollout is not None and rollout < 1:
            # A staged release can be halted or widened from the Console if the
            # crash rate moves; a completed one is live for everyone at once.
            status = "inProgress"
        else:
            status = "completed"

        def put_and_commit(release_status):
            call(
                "PUT",
                f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}/tracks/{track}",
                body={"track": track, "releases": [build_release(release_status)]},
            )
            call(
                "POST",
                f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}:commit",
                soft=True,
            )

        try:
            put_and_commit(status)
        except PlayError as error:
            # An app that has never been published is a "draft app", and Play
            # only accepts draft releases on it. The first public release has
            # to be sent for review by a human in the Console; there is no API
            # for that step. Fall back to staging it as a draft so the build,
            # the track and the release notes are all in place for that click.
            if "draft" not in str(error).lower():
                die(f"commit failed\n  {error}")
            print("  App has never been published, so Play requires a draft release.")
            status = "draft"
            call("DELETE", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}")
            edit_id = call(
                "POST", f"{API}/applications/{PACKAGE_NAME}/edits", body={}
            )["id"]
            put_and_commit(status)

        committed = True
    finally:
        if not committed:
            call("DELETE", f"{API}/applications/{PACKAGE_NAME}/edits/{edit_id}")

    if status == "draft":
        print(f"\n  Version code {version_code} is staged as a DRAFT on '{track}'.")
        print("  It is not with reviewers yet. In the Console, open the track and")
        print("  press 'Send for review' to submit the app for the first time.")
        print("  Every later release can go out from here without that step.")
        return

    print(f"  version code {version_code} is now on '{track}'")
    if track in ("alpha", "beta", "production"):
        print("  This track is reviewed by Google before it reaches users.")
    if rollout is not None and rollout < 1:
        print(f"  Staged at {round(rollout * 100)}%. Increase or halt it from the Console.")


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
    rollout, version_code, track_given = None, None, False
    index = 0
    while index < len(args):
        argument = args[index]
        if argument in ("confirm", "listing", "validate", "upload", "promote", "all"):
            mode = argument
        elif argument == "--track":
            index += 1
            track = args[index] if index < len(args) else ""
            track_given = True
        elif argument == "--bundle":
            index += 1
            bundle = args[index] if index < len(args) else ""
        elif argument == "--rollout":
            index += 1
            try:
                rollout = float(args[index]) if index < len(args) else None
            except ValueError:
                die("--rollout takes a fraction, for example 0.2")
        elif argument == "--version-code":
            index += 1
            version_code = args[index] if index < len(args) else ""
        else:
            die(f"unknown argument '{argument}'")
        index += 1

    # Promotion widens who can install the app, so the target is never implied.
    if mode == "promote" and not track_given:
        die("promote needs an explicit --track, for example --track beta")
    if mode == "promote" and version_code is None:
        _, version_code = pubspec_version()
        if not version_code:
            die("could not read the version code from pubspec.yaml; pass --version-code")

    if track not in VALID_TRACKS:
        die(f"track must be one of {', '.join(VALID_TRACKS)}")
    if mode in ("validate", "upload", "all") and not os.path.exists(bundle):
        die(f"no bundle at {bundle}. Run packaging/release.sh android first.")

    if mode in ("confirm", "all"):
        confirm(track)
    if mode == "listing":
        push_listing()
    if mode == "promote":
        promote(version_code, track, rollout)
    if mode in ("validate", "upload", "all"):
        validate(bundle)
    if mode in ("upload", "all"):
        upload(bundle, track)


if __name__ == "__main__":
    main()
