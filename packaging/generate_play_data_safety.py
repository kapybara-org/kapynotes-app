#!/usr/bin/env python3
"""Build and validate Kapy Notes' Google Play Data Safety declaration.

Google periodically changes the CSV schema, so the declaration is generated
from Google's current template rather than keeping a hand-written subset. The
output is a complete replacement document for applications.dataSafety.
"""

import argparse
import csv
import io
import os
import ssl
import sys
import urllib.error
import urllib.request


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUTPUT = os.path.join(ROOT, "packaging", "play_data_safety.csv")
DEFAULT_TEMPLATE_URL = (
    "https://storage.googleapis.com/support-kms-prod/"
    "b5v9It2EgwrgyY1gPFVB3jPUypc5lL3oNg2G"
)

QUESTION = "Question ID (machine readable)"
RESPONSE = "Response ID (machine readable)"
VALUE = "Response value"
REQUIREMENT = "Answer requirement"
LABEL = "Human-friendly question label"
FIELDS = [QUESTION, RESPONSE, VALUE, REQUIREMENT, LABEL]

APP_FUNCTIONALITY = "PSL_APP_FUNCTIONALITY"
ACCOUNT_MANAGEMENT = "PSL_ACCOUNT_MANAGEMENT"
ACCOUNT_CREATION_RESPONSE = "PSL_ACM_USER_ID_OTHER_AUTH"
ACCOUNT_DELETION_URL = "https://kapynotes.com/support#delete-your-account"
DATA_DELETION_URL = "https://kapynotes.com/support#deleting-your-data"

# Google's public sample CSV still lacks the account-creation and deletion
# questions required by applications.dataSafety. Keep those package-specific
# rows here until the sample catches up. The API validates their machine IDs.
ACCOUNT_ROWS = [
    (
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "PSL_ACM_USER_ID_PASSWORD",
        "MULTIPLE_CHOICE",
        "Which account creation methods does the app support? / Username and password",
    ),
    (
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "PSL_ACM_USER_ID_OTHER_AUTH",
        "MULTIPLE_CHOICE",
        "Which account creation methods does the app support? / Username and other authentication",
    ),
    (
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "PSL_ACM_USER_ID_PASSWORD_OTHER_AUTH",
        "MULTIPLE_CHOICE",
        "Which account creation methods does the app support? / Username, password, and other authentication",
    ),
    (
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "PSL_ACM_OAUTH",
        "MULTIPLE_CHOICE",
        "Which account creation methods does the app support? / OAuth",
    ),
    (
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "PSL_ACM_OTHER",
        "MULTIPLE_CHOICE",
        "Which account creation methods does the app support? / Other",
    ),
    (
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "PSL_ACM_NONE",
        "MULTIPLE_CHOICE",
        "Which account creation methods does the app support? / No account creation",
    ),
    (
        "PSL_ACM_SPECIFY",
        "",
        "MAYBE_REQUIRED",
        "Describe the supported account creation method",
    ),
    (
        "PSL_ACCOUNT_DELETION_URL",
        "",
        "MAYBE_REQUIRED",
        "Account deletion URL",
    ),
    (
        "PSL_SUPPORT_DATA_DELETION_BY_USER",
        "DATA_DELETION_YES",
        "SINGLE_CHOICE",
        "Can users request deletion of their data? / Yes",
    ),
    (
        "PSL_SUPPORT_DATA_DELETION_BY_USER",
        "DATA_DELETION_NO",
        "SINGLE_CHOICE",
        "Can users request deletion of their data? / No",
    ),
    (
        "PSL_SUPPORT_DATA_DELETION_BY_USER",
        "DATA_DELETION_NO_AUTO_DELETED",
        "SINGLE_CHOICE",
        "Can users request deletion of their data? / Automatically deleted within 90 days",
    ),
    (
        "PSL_DATA_DELETION_URL",
        "",
        "MAYBE_REQUIRED",
        "Data deletion URL",
    ),
    (
        "PSL_DATA_COLLECTION_COMPLIES_FAMILY_POLICY",
        "",
        "OPTIONAL",
        "Families Policy commitment",
    ),
    (
        "PSL_INDEPENDENTLY_VALIDATED",
        "",
        "OPTIONAL",
        "Independent security review",
    ),
    (
        "PSL_UPI_BADGE_OPT_IN",
        "",
        "OPTIONAL",
        "UPI badge opt-in",
    ),
    (
        "PSL_HAS_OUTSIDE_APP_ACCOUNTS",
        "",
        "OPTIONAL",
        "Can users log in with accounts created outside this app?",
    ),
    (
        "PSL_OUTSIDE_APP_ACCOUNT_TYPES",
        "PSL_LOGIN_WITH_OUTSIDE_APP_ID",
        "MULTIPLE_CHOICE",
        "How are outside accounts created? / Out-of-app identification",
    ),
    (
        "PSL_OUTSIDE_APP_ACCOUNT_TYPES",
        "PSL_LOGIN_THROUGH_EMPLOYMENT_OR_ENTERPRISE_ACCOUNT",
        "MULTIPLE_CHOICE",
        "How are outside accounts created? / Employment or enterprise",
    ),
    (
        "PSL_OUTSIDE_APP_ACCOUNT_TYPES",
        "PSL_OUTSIDE_APP_ACCOUNT_TYPE_OTHER",
        "MULTIPLE_CHOICE",
        "How are outside accounts created? / Other",
    ),
    (
        "PSL_OUTSIDE_APP_ACCOUNT_TYPE_SPECIFY",
        "",
        "MAYBE_REQUIRED",
        "Describe how outside accounts are created",
    ),
]

# Only off-device processing that is in scope under Play's rules is listed.
# Encrypted note, photo, video, and recording attachments are end-to-end
# encrypted and excluded. Photos remain because a profile photo is deliberately
# public to collaborators. User-generated content remains because space names
# are stored in plaintext and cloud summary requests are readable in flight.
DECLARATION = {
    "PSL_NAME": {
        "label": "Name",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY, ACCOUNT_MANAGEMENT},
    },
    "PSL_EMAIL": {
        "label": "Email address",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY, ACCOUNT_MANAGEMENT},
    },
    "PSL_USER_ACCOUNT": {
        "label": "User IDs",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY, ACCOUNT_MANAGEMENT},
    },
    "PSL_PURCHASE_HISTORY": {
        "label": "Purchase history",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY, ACCOUNT_MANAGEMENT},
    },
    "PSL_PHOTOS": {
        "label": "Photos",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY},
    },
    "PSL_AUDIO": {
        "label": "Voice or sound recordings",
        "ephemeral": True,
        "purposes": {APP_FUNCTIONALITY},
    },
    "PSL_USER_GENERATED_CONTENT": {
        "label": "Other user-generated content",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY},
    },
    "PSL_DEVICE_ID": {
        "label": "Device or other identifiers",
        "ephemeral": False,
        "purposes": {APP_FUNCTIONALITY},
    },
}


class DeclarationError(ValueError):
    pass


def _read_csv(text):
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames != FIELDS:
        raise DeclarationError(
            "Google's Data Safety template columns changed; review the new "
            "schema before generating a declaration"
        )
    rows = list(reader)
    if not rows:
        raise DeclarationError("the Data Safety template contains no questions")
    return rows


def _download(url):
    # Respect SSL_CERT_FILE when macOS' standalone Python lacks the system root
    # certificates. The release instructions already use /etc/ssl/cert.pem.
    context = ssl.create_default_context()
    with urllib.request.urlopen(url, context=context, timeout=30) as response:
        return response.read().decode("utf-8-sig")


def _set(rows, question, value, response=None):
    matches = [
        row
        for row in rows
        if row[QUESTION] == question and (response is None or row[RESPONSE] == response)
    ]
    if len(matches) != 1:
        suffix = f" / {response}" if response else ""
        raise DeclarationError(
            f"expected one template row for {question}{suffix}, found {len(matches)}"
        )
    matches[0][VALUE] = value


def build(template_text):
    rows = _read_csv(template_text)
    # Replace the obsolete single deletion question in Google's sample with
    # the complete account-aware group currently required by the live API.
    rows = [
        row
        for row in rows
        if row[QUESTION] != "PSL_DATA_COLLECTION_USER_REQUEST_DELETE"
    ]
    insertion = next(
        index
        for index, row in enumerate(rows)
        if row[QUESTION] == "PSL_DATA_COLLECTION_ENCRYPTED_IN_TRANSIT"
    ) + 1
    rows[insertion:insertion] = [
        {
            QUESTION: question,
            RESPONSE: response,
            VALUE: "",
            REQUIREMENT: requirement,
            LABEL: label,
        }
        for question, response, requirement, label in ACCOUNT_ROWS
    ]
    for row in rows:
        row[VALUE] = ""

    _set(rows, "PSL_DATA_COLLECTION_COLLECTS_PERSONAL_DATA", "TRUE")
    _set(rows, "PSL_DATA_COLLECTION_ENCRYPTED_IN_TRANSIT", "TRUE")
    _set(
        rows,
        "PSL_SUPPORTED_ACCOUNT_CREATION_METHODS",
        "TRUE",
        ACCOUNT_CREATION_RESPONSE,
    )
    _set(rows, "PSL_ACCOUNT_DELETION_URL", ACCOUNT_DELETION_URL)
    _set(
        rows,
        "PSL_SUPPORT_DATA_DELETION_BY_USER",
        "TRUE",
        "DATA_DELETION_YES",
    )
    _set(rows, "PSL_DATA_DELETION_URL", DATA_DELETION_URL)

    for data_type, details in DECLARATION.items():
        type_rows = [
            row
            for row in rows
            if row[RESPONSE] == data_type and row[QUESTION].startswith("PSL_DATA_TYPES_")
        ]
        if len(type_rows) != 1:
            raise DeclarationError(
                f"expected one data-type row for {data_type}, found {len(type_rows)}"
            )
        type_rows[0][VALUE] = "TRUE"

        prefix = f"PSL_DATA_USAGE_RESPONSES:{data_type}:"
        _set(
            rows,
            prefix + "PSL_DATA_USAGE_COLLECTION_AND_SHARING",
            "TRUE",
            "PSL_DATA_USAGE_ONLY_COLLECTED",
        )
        _set(
            rows,
            prefix + "PSL_DATA_USAGE_EPHEMERAL",
            "TRUE" if details["ephemeral"] else "FALSE",
        )
        _set(
            rows,
            prefix + "DATA_USAGE_USER_CONTROL",
            "TRUE",
            "PSL_DATA_USAGE_USER_CONTROL_OPTIONAL",
        )
        for purpose in details["purposes"]:
            _set(
                rows,
                prefix + "DATA_USAGE_COLLECTION_PURPOSE",
                "TRUE",
                purpose,
            )

    validate_rows(rows)
    return rows


def validate_rows(rows):
    values = {(row[QUESTION], row[RESPONSE]): row[VALUE] for row in rows}
    allowed_values = {}

    for question in (
        "PSL_DATA_COLLECTION_COLLECTS_PERSONAL_DATA",
        "PSL_DATA_COLLECTION_ENCRYPTED_IN_TRANSIT",
    ):
        if values.get((question, "")) != "TRUE":
            raise DeclarationError(f"{question} must be TRUE")
        allowed_values[(question, "")] = "TRUE"

    required_account_answers = {
        ("PSL_SUPPORTED_ACCOUNT_CREATION_METHODS", ACCOUNT_CREATION_RESPONSE): "TRUE",
        ("PSL_ACCOUNT_DELETION_URL", ""): ACCOUNT_DELETION_URL,
        ("PSL_SUPPORT_DATA_DELETION_BY_USER", "DATA_DELETION_YES"): "TRUE",
        ("PSL_DATA_DELETION_URL", ""): DATA_DELETION_URL,
    }
    for key, expected_value in required_account_answers.items():
        if values.get(key) != expected_value:
            raise DeclarationError(f"required account response is invalid: {key}")
        allowed_values[key] = expected_value

    selected = {
        row[RESPONSE]
        for row in rows
        if row[QUESTION].startswith("PSL_DATA_TYPES_") and row[VALUE] == "TRUE"
    }
    expected = set(DECLARATION)
    if selected != expected:
        raise DeclarationError(
            "selected data types differ from the audited declaration: "
            f"expected {sorted(expected)}, got {sorted(selected)}"
        )

    for data_type, details in DECLARATION.items():
        type_rows = [
            row
            for row in rows
            if row[RESPONSE] == data_type
            and row[QUESTION].startswith("PSL_DATA_TYPES_")
        ]
        if len(type_rows) != 1:
            raise DeclarationError(f"could not resolve selected type {data_type}")
        allowed_values[(type_rows[0][QUESTION], data_type)] = "TRUE"

        prefix = f"PSL_DATA_USAGE_RESPONSES:{data_type}:"
        expected_true = {
            (
                prefix + "PSL_DATA_USAGE_COLLECTION_AND_SHARING",
                "PSL_DATA_USAGE_ONLY_COLLECTED",
            ),
            (
                prefix + "DATA_USAGE_USER_CONTROL",
                "PSL_DATA_USAGE_USER_CONTROL_OPTIONAL",
            ),
            *{
                (prefix + "DATA_USAGE_COLLECTION_PURPOSE", purpose)
                for purpose in details["purposes"]
            },
        }
        for key in expected_true:
            if values.get(key) != "TRUE":
                raise DeclarationError(f"required response is not TRUE: {key}")
            allowed_values[key] = "TRUE"

        ephemeral = values.get((prefix + "PSL_DATA_USAGE_EPHEMERAL", ""))
        expected_ephemeral = "TRUE" if details["ephemeral"] else "FALSE"
        if ephemeral != expected_ephemeral:
            raise DeclarationError(
                f"{data_type} ephemeral response must be {expected_ephemeral}"
            )
        allowed_values[(prefix + "PSL_DATA_USAGE_EPHEMERAL", "")] = expected_ephemeral

    for row in rows:
        key = (row[QUESTION], row[RESPONSE])
        if row[VALUE] and allowed_values.get(key) != row[VALUE]:
            raise DeclarationError(
                f"unexpected response {row[VALUE]!r} for "
                f"{row[QUESTION]} / {row[RESPONSE]}"
            )

    return rows


def load_declaration(path=DEFAULT_OUTPUT):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        rows = _read_csv(handle.read())
    return validate_rows(rows)


def render(rows):
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=FIELDS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def print_summary(rows):
    validate_rows(rows)
    print("  encrypted in transit: yes")
    print("  account creation:     email and one-time code")
    print("  account deletion:     in-app and published web route")
    print("  data deletion:        in-app and published web route")
    print("  shared data:          none")
    for data_type, details in DECLARATION.items():
        handling = "ephemeral" if details["ephemeral"] else "retained"
        purposes = ", ".join(
            purpose.removeprefix("PSL_").replace("_", " ").lower()
            for purpose in sorted(details["purposes"])
        )
        print(f"  {details['label']:<30} optional, {handling}, {purposes}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template-url", default=DEFAULT_TEMPLATE_URL)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    try:
        if args.check:
            rows = load_declaration(args.output)
            print_summary(rows)
            return
        rows = build(_download(args.template_url))
        text = render(rows)
        with open(args.output, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        print(f"Wrote {args.output}")
        print_summary(rows)
    except (OSError, DeclarationError, urllib.error.URLError) as error:
        print(f"failed: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
