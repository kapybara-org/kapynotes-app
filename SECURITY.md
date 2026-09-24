# Security

## Reporting a vulnerability

Report privately through GitHub's [security advisory
form](https://github.com/kapybara-org/kapynotes-app/security/advisories/new).
It reaches the maintainers without the report ever being public, and we can
open a fix branch against the advisory.

Please do not open a public issue for anything exploitable.

## Scope

This repository is the client: the Flutter app, its packaging, and its release
pipeline. The sync backend it talks to at `api.kapynotes.com` is a separate,
closed-source service — vulnerabilities in it are in scope for this form too,
even though the code is not here.

Of particular interest:

- Anything that lets a note reach the server in a form the server can read.
  Notes are encrypted on device; the key handling lives in `lib/sync/`.
- Anything affecting the recovery key flow (`lib/sync/recovery_key.dart`).
- Anything that would let an attacker get an update installed: the macOS
  release is signed with an EdDSA key, which Sparkle checks, and the Windows
  installer with DSA, which the app checks itself before running it
  (`lib/data/update_signature.dart`). The public halves ship inside the app.

## Update signing

Releases are signed and notarised in `.github/workflows/desktop-release.yml`.
The macOS build carries a Developer ID signature and an Apple notarisation
ticket; the Windows installer is **not** Authenticode-signed yet, so
SmartScreen will warn on it. That is expected, and is not a compromise of the
download — verify against the checksums on the release page if in doubt.
