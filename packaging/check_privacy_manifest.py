#!/usr/bin/env python3
"""Does ios/Runner/PrivacyInfo.xcprivacy agree with packaging/privacy.json?

Both sides are read rather than remembered. packaging/privacy.json is the
declaration as published, so adding a data type is one edit there and this
check follows. The list used to be spelled out in the preflight instead, which
is how an empty collected-data answer went on passing for the eleven versions
after accounts shipped.

Its own file rather than a heredoc inside the preflight: the shell there wraps
python in a command substitution, and the bash macOS ships mis-pairs
apostrophes inside one, so a comment with an odd number of them broke the whole
script. Prose that cannot break a gate is worth a file.

Prints OK <count>, or a sentence naming what disagrees. Never exits non-zero;
the caller decides what a disagreement costs.
"""
import json
import os
import sys

# App Store Connect category names on the left, Apple manifest keys on the
# right. An unmapped category is a hard error rather than a silent pass: a new
# data type has to be taught to this map before it can ship.
#
# The left-hand side is not guessable. AUDIO_DATA reads like the obvious name
# for the audio one and is wrong; the real token is AUDIO. Read them with
# "asc web privacy catalog" before adding a row.
KEYS = {
    "EMAIL_ADDRESS": "NSPrivacyCollectedDataTypeEmailAddress",
    "USER_ID": "NSPrivacyCollectedDataTypeUserID",
    "OTHER_USER_CONTENT": "NSPrivacyCollectedDataTypeOtherUserContent",
    "PHOTOS_OR_VIDEOS": "NSPrivacyCollectedDataTypePhotosorVideos",
    "AUDIO": "NSPrivacyCollectedDataTypeAudioData",
}


def main() -> None:
    with open("packaging/privacy.json", encoding="utf-8") as handle:
        record = json.load(handle)
    wanted = [usage["category"] for usage in record["dataUsages"]]

    unmapped = sorted(c for c in wanted if c not in KEYS)
    if unmapped:
        print("unmapped in check_privacy_manifest.py: " + ", ".join(unmapped))
        return

    manifest = json.loads(os.environ.get("MANIFEST_JSON") or "[]")
    declared = {entry.get("NSPrivacyCollectedDataType") for entry in manifest}

    missing = [c for c in wanted if KEYS[c] not in declared]
    extra = sorted(declared - {KEYS[c] for c in wanted})
    if missing:
        print("missing from the manifest: " + ", ".join(missing))
    elif extra:
        print("in the manifest but not the record: " + ", ".join(extra))
    else:
        print(f"OK {len(wanted)}")


if __name__ == "__main__":
    main()
    sys.exit(0)
