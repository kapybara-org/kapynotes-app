#!/usr/bin/env python3
#
# Takes an uploaded iOS build through to App Review.
#
#   packaging/asc_submit.py build     wait until App Store Connect has processed the build
#   packaging/asc_submit.py prepare   create the version (or swap in an earlier one waiting for
#                                     review), attach the build, set What's New, and remove
#                                     any phased release
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
# When VER has no App Store version yet and an earlier version is still waiting
# for review, prepare swaps it, as fastlane's reject_if_possible does: it
# cancels that review submission, waits until the version can be edited again,
# and renames it to VER, so VER goes to review in its place. Only that one
# shape is swapped: exactly one earlier version not yet released, in
# WAITING_FOR_REVIEW, held alone by the one open review submission. If the
# earlier version is in review or later, prepare changes nothing and exits with
# DEFERRED_EXIT (3): the build is uploaded, and the submission waits until the
# earlier version is released. Anything else it does not expect stops the run
# before it changes anything more.
#
# The token is signed here with PyJWT and cryptography (hash-pinned in
# packaging/asc-requirements.txt), so the key is only ever read from its file.
# Nothing printed names a person or a credential: this repository is public,
# and so are its CI logs.

import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APP = "6807810082"
TOKEN_LIFETIME = 20 * 60
TOKEN_REFRESH = 10 * 60
POLL_SECONDS = 60
WHATS_NEW_LIMIT = 4000
CANCEL_WAIT_SECONDS = 10 * 60
CANCEL_POLL_SECONDS = 15
DEFERRED_EXIT = 3

# appStoreState and appVersionState values, by what they mean for a new version.
# A value in none of these stops the swap check.
STAGES = {
    "released": {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION",
                 "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"},
    "waiting": {"WAITING_FOR_REVIEW"},
    "editable": {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                 "READY_FOR_REVIEW", "INVALID_BINARY", "WAITING_FOR_EXPORT_COMPLIANCE"},
    "in_review_or_later": {"IN_REVIEW", "PENDING_CONTRACT", "PENDING_APPLE_RELEASE",
                           "PENDING_DEVELOPER_RELEASE", "ACCEPTED", "PROCESSING_FOR_APP_STORE",
                           "PROCESSING_FOR_DISTRIBUTION"},
}
# What a cancelled version may show while the cancel lands, and once it has.
CANCELLING_VERSION = {"WAITING_FOR_REVIEW"}
CANCELLED_VERSION = {"DEVELOPER_REJECTED", "PREPARE_FOR_SUBMISSION"}
# Every review submission state except COMPLETE, which is done with.
OPEN_SUBMISSIONS = "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES,CANCELING,COMPLETING"


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
        import jwt

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


def call(method, path, body=None, missing_ok=False):
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
        if missing_ok and error.code == 404:
            return None
        raise SystemExit(f"{method} {path.split('?')[0]} -> {error.code} {error.read().decode()[:800]}")


def optional(path):
    """A to-one relationship that does not exist answers 404 rather than null.

    Only a 404 means absent. Any other failure stops the run, so a check that
    could not be made never reads as "there is none".
    """
    found = call("GET", path, missing_ok=True)
    return found and found["data"]


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


def every(path):
    """A list that fits in one page. A second page stops the run rather than
    leaving something unseen."""
    page = call("GET", path)
    if (page.get("links") or {}).get("next"):
        raise SystemExit(f"GET {path.split('?')[0]} has more than one page; stopping")
    return page["data"]


def states(version):
    attributes = version["attributes"]
    found = {attributes.get(name) for name in ("appStoreState", "appVersionState")} - {None}
    if not found:
        raise SystemExit(f"version {version['id']} reports no state; stopping")
    return found


def stage(version):
    found = states(version)
    stages = {name for name, members in STAGES.items() if found & members}
    known = set().union(*STAGES.values())
    if len(stages) != 1 or not found <= known:
        raise SystemExit(f"version {version['attributes'].get('versionString')} is in "
                         f"{sorted(found)}, which this script does not handle; stopping")
    return stages.pop()


def version_key(text):
    try:
        return tuple(int(part) for part in text.split("."))
    except (AttributeError, ValueError):
        raise SystemExit(f"cannot compare version string {text!r}; stopping")


def plan_new_version():
    """What to do when VER has no App Store version yet. Reads only.

    Returns None to create VER, or (version, submission) to swap. Exits with
    DEFERRED_EXIT when an earlier version is in review or later.
    """
    pending = [version for version in
               every(f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=200")
               if stage(version) != "released"]
    if not pending:
        return None
    if len(pending) > 1:
        raise SystemExit("more than one unreleased version: "
                         f"{sorted(v['attributes'].get('versionString') or '?' for v in pending)}; stopping")
    old = pending[0]
    name = old["attributes"].get("versionString")
    if version_key(name) >= version_key(env("VER")):
        raise SystemExit(f"unreleased version {name} is not lower than {env('VER')}; stopping")
    if stage(old) == "in_review_or_later":
        print(f"version {name} is {sorted(states(old))}. Build {env('BUILD')} is uploaded, and "
              f"submitting {env('VER')} waits until {name} is released. Nothing was changed.", flush=True)
        raise SystemExit(DEFERRED_EXIT)
    if any(old["attributes"].get(field) != "WAITING_FOR_REVIEW"
           for field in ("appStoreState", "appVersionState")):
        raise SystemExit(f"version {name} is {sorted(states(old))}, not WAITING_FOR_REVIEW in both "
                         "appStoreState and appVersionState; stopping")

    submissions = every(f"/v1/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS"
                        f"&filter[state]={OPEN_SUBMISSIONS}&limit=200")
    if len(submissions) != 1:
        raise SystemExit(f"{len(submissions)} open review submissions, not one; stopping")
    submission = submissions[0]
    if submission["attributes"].get("state") != "WAITING_FOR_REVIEW":
        raise SystemExit(f"the open review submission is {submission['attributes'].get('state')}, "
                         "not WAITING_FOR_REVIEW; stopping")
    items = every(f"/v1/reviewSubmissions/{submission['id']}/items?include=appStoreVersion&limit=50")
    held = [((item.get("relationships") or {}).get("appStoreVersion") or {}).get("data") for item in items]
    if len(items) != 1 or not held[0] or held[0].get("id") != old["id"]:
        raise SystemExit(f"the open review submission holds {len(items)} items, not only version {name}; "
                         "stopping")
    return old, submission


def swap(old, submission):
    """Cancel the earlier version's review and rename it to VER."""
    name, version_id, submission_id = old["attributes"]["versionString"], old["id"], submission["id"]
    print(f"swapping: cancelling the review of {name} to send {env('VER')} in its place", flush=True)
    call("PATCH", f"/v1/reviewSubmissions/{submission_id}", {"data": {
        "type": "reviewSubmissions", "id": submission_id, "attributes": {"canceled": True},
    }})

    deadline = time.time() + CANCEL_WAIT_SECONDS
    while True:
        found = optional(f"/v1/reviewSubmissions/{submission_id}")
        submission_state = found["attributes"].get("state") if found else "GONE"
        version_states = states(call("GET", f"/v1/appStoreVersions/{version_id}")["data"])
        print(f"submission {submission_state}, version {sorted(version_states)}", flush=True)
        if submission_state not in ("WAITING_FOR_REVIEW", "CANCELING", "COMPLETE", "GONE"):
            raise SystemExit(f"the cancelled submission went to {submission_state}; stopping")
        if not version_states <= CANCELLING_VERSION | CANCELLED_VERSION:
            raise SystemExit(f"version {name} went to {sorted(version_states)} while cancelling; stopping")
        if submission_state in ("COMPLETE", "GONE") and version_states <= CANCELLED_VERSION:
            break
        if time.time() > deadline:
            raise SystemExit(f"the cancel did not finish within {CANCEL_WAIT_SECONDS // 60} minutes; stopping")
        time.sleep(CANCEL_POLL_SECONDS)

    call("PATCH", f"/v1/appStoreVersions/{version_id}", {"data": {
        "type": "appStoreVersions", "id": version_id,
        "attributes": {"versionString": env("VER"), "releaseType": "AFTER_APPROVAL"},
    }})
    renamed = call("GET", f"/v1/appStoreVersions/{version_id}")["data"]
    if renamed["attributes"].get("versionString") != env("VER"):
        raise SystemExit(f"version {version_id} still reads {renamed['attributes'].get('versionString')}; stopping")
    print(f"renamed {name} to {env('VER')}", flush=True)
    return renamed


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
    swap_with = None if version else plan_new_version()
    if swap_with:
        version = swap(*swap_with)
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
        "state": sorted(states(version)),
        "build": build and build["attributes"]["version"],
        "whatsNew_matches": (localization.get("whatsNew") or "").strip() == notes(),
        "phased": "none (100% on approval)" if not phased else phased["attributes"]["phasedReleaseState"],
        "releaseType": version["attributes"]["releaseType"],
    }
    print(json.dumps(report))
    if (phased or not report["whatsNew_matches"] or report["build"] != env("BUILD")
            or report["state"] != ["WAITING_FOR_REVIEW"]):
        raise SystemExit("the version does not match this release")


MODES = {"build": wait_for_build, "prepare": prepare, "submit": submit, "status": status}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        raise SystemExit(f"usage: packaging/asc_submit.py {'|'.join(MODES)}")
    MODES[sys.argv[1]]()
