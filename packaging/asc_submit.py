#!/usr/bin/env python3
#
# Takes an uploaded iOS build through to App Review.
#
#   packaging/asc_submit.py build     wait until App Store Connect has processed the build
#   packaging/asc_submit.py prepare   create the version, attach the build, set What's New,
#                                     and remove any phased release
#   packaging/asc_submit.py submit    send the version to App Review
#   packaging/asc_submit.py status    print where the version stands
#
# Reads from the environment:
#
#   VER           the version string, for example 1.35.1
#   BUILD         the build number, for example 43
#   NOTES_FILE    What's New for this version (prepare and status)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#                 an App Store Connect team API key and the path of its .p8
#   BUILD_WAIT_MINUTES  how long "build" waits for processing; default 60
#
# Every release goes to all users the moment it is approved, so prepare deletes
# any phased release and fails if one is still there afterwards.
#
# The token is signed here with PyJWT and cryptography
# (pip install PyJWT cryptography), so the key is only ever read from its file.
# Nothing printed names a person or a credential: this repository is public,
# and so are its CI logs.

import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
APP = "6807810082"
TOKEN_LIFETIME = 20 * 60
TOKEN_REFRESH = 10 * 60
POLL_SECONDS = 60
WHATS_NEW_LIMIT = 4000


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is not set")
    return value


_token, _minted = None, 0


def token():
    global _token, _minted
    now = int(time.time())
    if _token is None or now - _minted > TOKEN_REFRESH:
        with open(env("ASC_KEY_PATH")) as handle:
            key = handle.read()
        _token = jwt.encode(
            {"iss": env("ASC_ISSUER_ID"), "iat": now, "exp": now + TOKEN_LIFETIME,
             "aud": "appstoreconnect-v1"},
            key,
            algorithm="ES256",
            headers={"kid": env("ASC_KEY_ID"), "typ": "JWT"},
        )
        _minted = now
    return _token


def call(method, path, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{method} {path.split('?')[0]} -> {error.code} {error.read().decode()[:800]}")


def optional(path):
    """A to-one relationship that does not exist answers 404 rather than null."""
    try:
        return call("GET", path)["data"]
    except SystemExit:
        return None


def notes():
    with open(env("NOTES_FILE"), encoding="utf-8") as handle:
        text = handle.read().strip()
    if not text:
        raise SystemExit("NOTES_FILE is empty")
    if len(text) > WHATS_NEW_LIMIT:
        raise SystemExit(f"What's New is {len(text)} characters, over the limit of {WHATS_NEW_LIMIT}")
    return text


def find_build():
    found = call(
        "GET",
        f"/v1/builds?filter[app]={APP}&filter[version]={env('BUILD')}"
        f"&filter[preReleaseVersion.version]={env('VER')}&include=preReleaseVersion",
    )["data"]
    return found[0] if found else None


def find_version():
    found = call(
        "GET",
        f"/v1/apps/{APP}/appStoreVersions?filter[versionString]={env('VER')}&filter[platform]=IOS",
    )["data"]
    return found[0] if found else None


def phased_release(version_id):
    return optional(f"/v1/appStoreVersions/{version_id}/appStoreVersionPhasedRelease")


def wait_for_build():
    deadline = time.time() + int(os.environ.get("BUILD_WAIT_MINUTES", "60")) * 60
    while True:
        found = find_build()
        state = found and found["attributes"]["processingState"]
        print(f"build {env('VER')} ({env('BUILD')}): {state or 'not listed yet'}", flush=True)
        if state == "VALID":
            print("usesNonExemptEncryption", found["attributes"].get("usesNonExemptEncryption"))
            return
        if state in ("FAILED", "INVALID"):
            raise SystemExit(f"App Store Connect marked the build {state}")
        if time.time() > deadline:
            raise SystemExit("gave up waiting for the build to finish processing")
        time.sleep(POLL_SECONDS)


def prepare():
    whats_new = notes()
    build = find_build()
    if not build or build["attributes"]["processingState"] != "VALID":
        raise SystemExit("the build is not VALID yet; run 'build' first")

    version = find_version()
    if not version:
        version = call("POST", "/v1/appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": env("VER"),
                           "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
        }})["data"]
        print("created version", version["id"])
    version_id = version["id"]

    call("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build",
         {"data": {"type": "builds", "id": build["id"]}})

    localizations = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    for localization in localizations:
        call("PATCH", f"/v1/appStoreVersionLocalizations/{localization['id']}", {"data": {
            "type": "appStoreVersionLocalizations",
            "id": localization["id"],
            "attributes": {"whatsNew": whats_new},
        }})
        sets = call("GET", f"/v1/appStoreVersionLocalizations/{localization['id']}"
                           "/appScreenshotSets?include=appScreenshots")["data"]
        print("locale", localization["attributes"]["locale"], "screenshot sets",
              [(s["attributes"]["screenshotDisplayType"],
                len(s["relationships"]["appScreenshots"]["data"] or [])) for s in sets])

    phased = phased_release(version_id)
    if phased:
        call("DELETE", f"/v1/appStoreVersionPhasedReleases/{phased['id']}")
        print("deleted phased release", phased["id"], phased["attributes"].get("phasedReleaseState"))
    if phased_release(version_id):
        raise SystemExit("a phased release is still attached to the version")
    print("phased none (100% on approval)")

    review = optional(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    print("review detail set", review and {
        name: bool(value) for name, value in review["attributes"].items() if name != "notes"
    })
    attributes = call("GET", f"/v1/appStoreVersions/{version_id}")["data"]["attributes"]
    print("version", attributes.get("versionString"), attributes.get("appStoreState"),
          attributes.get("appVersionState"), attributes.get("releaseType"))


def submit():
    version = find_version()
    if not version:
        raise SystemExit(f"no App Store version {env('VER')}; run 'prepare' first")
    version_id = version["id"]
    submission = call("POST", "/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions",
        "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
    }})["data"]
    call("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
        },
    }})
    result = call("PATCH", f"/v1/reviewSubmissions/{submission['id']}", {"data": {
        "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True},
    }})["data"]
    print("submission", result["attributes"].get("state"))
    time.sleep(10)
    attributes = call("GET", f"/v1/appStoreVersions/{version_id}")["data"]["attributes"]
    print("version", attributes.get("versionString"), attributes.get("appStoreState"),
          attributes.get("appVersionState"))


def status():
    version = find_version()
    if not version:
        raise SystemExit(f"no App Store version {env('VER')}")
    version_id = version["id"]
    build = optional(f"/v1/appStoreVersions/{version_id}/build")
    localization = call("GET", f"/v1/appStoreVersions/{version_id}"
                               "/appStoreVersionLocalizations")["data"][0]["attributes"]
    phased = phased_release(version_id)
    report = {
        "state": version["attributes"]["appStoreState"],
        "build": build and build["attributes"]["version"],
        "whatsNew_matches": (localization.get("whatsNew") or "").strip() == notes(),
        "phased": "none (100% on approval)" if not phased else phased["attributes"]["phasedReleaseState"],
        "releaseType": version["attributes"]["releaseType"],
    }
    print(json.dumps(report))
    if phased or not report["whatsNew_matches"] or report["build"] != env("BUILD"):
        raise SystemExit("the version does not match this release")


MODES = {"build": wait_for_build, "prepare": prepare, "submit": submit, "status": status}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        raise SystemExit(f"usage: packaging/asc_submit.py {'|'.join(MODES)}")
    MODES[sys.argv[1]]()
