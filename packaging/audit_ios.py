#!/usr/bin/env python3
#
# Read-only audit of the live App Store Connect record.
#
#   packaging/audit_ios.py
#
# preflight_ios.sh checks the repo and the toolchain before archiving. This
# checks the other half: what App Store Connect actually holds. It reads only,
# so it is safe to run at any point, including while a version is in review.
#
# It needs the same credentials as upload_ios.sh: ASC_KEY_ID and ASC_ISSUER_ID
# exported or written to packaging/.asc-credentials, and the matching
# AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/.
#
# Exits non-zero when a blocker is found, so it can gate a release script.
#
# One thing it deliberately cannot check: **App Privacy**. The apps resource
# exposes no data-usage relationship of any kind, so whether "Data Not
# Collected" has been published has to be confirmed by eye in the UI. Every
# other item below is read from the live record.

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.kapybara.kapynotes"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_DIR = os.path.expanduser("~/.appstoreconnect/private_keys")

BOLD, RED, GREEN, DIM, RESET = "\033[1m", "\033[1;31m", "\033[1;32m", "\033[2m", "\033[0m"

blockers: list[str] = []
warnings: list[str] = []


def die(message: str):
    print(f"{RED}failed:{RESET} {message}", file=sys.stderr)
    raise SystemExit(2)


def credentials() -> tuple[str, str]:
    key_id, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    creds = os.path.join(ROOT, "packaging", ".asc-credentials")
    if os.path.exists(creds):
        for line in open(creds):
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            name, _, value = line.partition("=")
            if name == "ASC_KEY_ID":
                key_id = key_id or value
            elif name == "ASC_ISSUER_ID":
                issuer = issuer or value
    if not key_id or not issuer:
        die("ASC_KEY_ID / ASC_ISSUER_ID are not set. See the header of upload_ios.sh.")
    return key_id, issuer


def token() -> str:
    """altool mints the ES256 token, which saves reimplementing JWT signing."""
    key_id, issuer = credentials()
    p8 = os.path.join(KEY_DIR, f"AuthKey_{key_id}.p8")
    if not os.path.exists(p8):
        die(f"no AuthKey_{key_id}.p8 in {KEY_DIR}")
    out = subprocess.run(
        ["xcrun", "altool", "--generate-jwt", "--apiKey", key_id,
         "--apiIssuer", issuer, "--p8-file-path", p8],
        capture_output=True, text=True,
    )
    for line in (out.stdout + out.stderr).splitlines():
        line = line.strip()
        if re.fullmatch(r"ey[\w-]+\.[\w-]+\.[\w-]+", line):
            return line
    die("could not mint an App Store Connect token; check the key values")


JWT = token()


def get(path: str) -> tuple[bool, object]:
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(url)
    request.add_header("Authorization", "Bearer " + JWT)
    try:
        with urllib.request.urlopen(request) as response:
            return True, json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        try:
            errors = json.loads(error.read().decode())["errors"]
            return False, "; ".join(e.get("code", "?") for e in errors)
        except Exception:
            return False, "request failed"


def check(ok: bool, label: str, detail: str = "", blocker: bool = True) -> None:
    mark = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
    print(f"  {mark}  {label:<34} {detail}")
    if not ok:
        (blockers if blocker else warnings).append(label)


def pubspec_version() -> str | None:
    try:
        for line in open(os.path.join(ROOT, "pubspec.yaml")):
            if line.startswith("version:"):
                return line.split(":", 1)[1].strip().split("+")[0]
    except OSError:
        pass
    return None


ok, apps = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
if not ok or not apps.get("data"):
    die(f"no App Store Connect record for {BUNDLE_ID}")
app = apps["data"][0]
APP_ID = app["id"]
print(f"\n{BOLD}{app['attributes']['name']}{RESET}  {DIM}({BUNDLE_ID}, id {APP_ID}){RESET}")

# The editable version is the newest one; a released app would also list
# older, read-only versions.
ok, versions = get(f"/v1/apps/{APP_ID}/appStoreVersions?limit=1&include=build")
version = versions["data"][0]
VER = version["id"]
va = version["attributes"]

print(f"\n{BOLD}VERSION{RESET}")
expected = pubspec_version()
check(va["versionString"] == expected if expected else bool(va["versionString"]),
      "version matches pubspec",
      f"{va['versionString']}" + (f" vs pubspec {expected}" if expected and va["versionString"] != expected else ""))
check(va["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW",
                             "WAITING_FOR_REVIEW", "IN_REVIEW",
                             "PENDING_DEVELOPER_RELEASE", "READY_FOR_SALE"),
      "state", va["appStoreState"])
check(va["releaseType"] in ("MANUAL", "SCHEDULED", "AFTER_APPROVAL"), "release type",
      va["releaseType"] + ("" if va["releaseType"] == "MANUAL" else "  (not manual)"))
check(bool(va.get("copyright")), "copyright", va.get("copyright") or "BLANK")
check(va.get("usesIdfa") is not None, "IDFA declared", f"usesIdfa={va.get('usesIdfa')}")

included = versions.get("included", [])
check(bool(included), "build attached", included[0]["attributes"]["version"] if included else "NONE")
if included:
    ok, build = get(f"/v1/builds/{included[0]['id']}")
    ba = build["data"]["attributes"]
    check(ba["processingState"] == "VALID", "build processing", ba["processingState"])
    check(ba.get("usesNonExemptEncryption") is False, "export compliance",
          f"usesNonExemptEncryption={ba.get('usesNonExemptEncryption')}")
    check(not ba.get("expired"), "build not expired", f"expired={ba.get('expired')}")

print(f"\n{BOLD}LISTING{RESET}")
ok, locs = get(f"/v1/appStoreVersions/{VER}/appStoreVersionLocalizations")
LOC = locs["data"][0]["id"]
la = locs["data"][0]["attributes"]
check(bool(la.get("description")), "description", f"{len(la.get('description') or '')} chars")
keyword_bytes = len((la.get("keywords") or "").encode())
check(0 < keyword_bytes <= 100, "keywords within 100 bytes", f"{keyword_bytes} bytes")
check(bool(la.get("supportUrl")), "support URL", la.get("supportUrl") or "BLANK")
check(bool(la.get("marketingUrl")), "marketing URL", la.get("marketingUrl") or "BLANK", blocker=False)
check(bool(la.get("promotionalText")), "promotional text",
      f"{len(la.get('promotionalText') or '')} chars", blocker=False)

ok, infos = get(f"/v1/apps/{APP_ID}/appInfos")
info = infos["data"][0]
INFO = info["id"]
ok, ilocs = get(f"/v1/appInfos/{INFO}/appInfoLocalizations")
ila = ilocs["data"][0]["attributes"]
check(bool(ila.get("subtitle")), "subtitle", ila.get("subtitle") or "BLANK", blocker=False)
check(bool(ila.get("privacyPolicyUrl")), "privacy policy URL", ila.get("privacyPolicyUrl") or "BLANK")
ok, cats = get(f"/v1/appInfos/{INFO}?include=primaryCategory,secondaryCategory")
category_ids = [c["id"] for c in cats.get("included", [])]
check(bool(category_ids), "categories", category_ids or "NOT SET")
check(info["attributes"].get("appStoreAgeRating") is not None, "age rating",
      info["attributes"].get("appStoreAgeRating") or "NOT SET")

print(f"\n{BOLD}SCREENSHOTS{RESET}")
ok, sets = get(f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets?include=appScreenshots")
shots = sets.get("included", [])
bad = [s for s in shots
       if (s["attributes"].get("assetDeliveryState") or {}).get("state") != "COMPLETE"]
check(bool(sets.get("data")), "screenshot sets",
      [s["attributes"]["screenshotDisplayType"] for s in sets.get("data", [])] or "NONE")
check(bool(shots) and not bad, "all screenshots COMPLETE", f"{len(shots)} shots, {len(bad)} not ready")

print(f"\n{BOLD}APP REVIEW INFO{RESET}")
ok, detail = get(f"/v1/appStoreVersions/{VER}/appStoreReviewDetail")
ra = detail.get("data", {}).get("attributes", {}) if ok and detail.get("data") else {}
for field in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail"):
    check(bool(ra.get(field)), field, ra.get(field) or "BLANK")
notes = ra.get("notes") or ""
check(bool(notes), "review notes", f"{len(notes)} chars")

print(f"\n{BOLD}APP LEVEL{RESET}")
check(bool(app["attributes"].get("contentRightsDeclaration")), "content rights",
      app["attributes"].get("contentRightsDeclaration") or "NOT SET")

ok, schedule = get(f"/v1/apps/{APP_ID}/appPriceSchedule?include=manualPrices")
check(ok and bool(schedule.get("included")), "price schedule",
      "set" if ok and schedule.get("included") else "NOT SET")

# Availability reads through appAvailabilityV2. The /v2/apps/{id}/appAvailability
# form returns 404 and looks deceptively like "never configured".
ok, availability = get(f"/v1/apps/{APP_ID}/appAvailabilityV2?include=territoryAvailabilities")
if ok:
    related = ((availability["data"].get("relationships") or {})
               .get("territoryAvailabilities") or {}).get("links", {}).get("related")
    on, off = [], []
    url = f"{related}?limit=200&include=territory" if related else None
    while url:
        page_ok, page = get(url)
        if not page_ok:
            break
        for territory in page.get("data", []):
            code = ((territory.get("relationships") or {})
                    .get("territory", {}).get("data") or {}).get("id")
            (on if territory["attributes"].get("available") else off).append(code)
        url = (page.get("links") or {}).get("next")
    check(bool(on), "territory availability", f"{len(on)} on, {len(off)} off")
    # Mainland China has required an ICP filing number for new apps since
    # 1 September 2023; without one the storefront reports CANNOT_SELL.
    check("CHN" not in on, "China mainland excluded",
          "CHN is ON but there is no ICP filing" if "CHN" in on else "excluded",
          blocker=False)
else:
    check(False, "territory availability", f"unreadable ({availability})")

print("\n" + "=" * 64)
print(f"{DIM}App Privacy is not exposed by the API. Confirm 'Data Not Collected'"
      f" is published in the UI.{RESET}")
print(f"BLOCKERS: {len(blockers)}")
for item in blockers:
    print(f"   - {item}")
print(f"WARNINGS: {len(warnings)}")
for item in warnings:
    print(f"   ~ {item}")

raise SystemExit(1 if blockers else 0)
