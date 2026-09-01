# Shipping Kapy Notes

One codebase, bundle ID `com.kapybara.kapynotes`, team `96V66447C6` (Kapybara LLC).

| Artifact | Channel | Status | Command |
|---|---|---|---|
| `KapyNotes-<version>.dmg` | Direct, kapynotes.com | **current plan** | `packaging/release.sh mac-direct` |
| `kapy-ios.ipa` | iOS App Store | later | `packaging/release.sh ios` |
| `kapy-macos.pkg` | Mac App Store | not in use | `packaging/release.sh mac-store` |

The product is called **Kapy Notes** everywhere: the Dock and Home Screen label,
the bundle (`Kapy Notes.app`), the in-app wordmark, and the App Store listing
name. Ten characters, comfortably inside the 30-char store cap.

Two deliberate exceptions:

- The **bundle ID** stays lowercase reverse-DNS, `com.kapybara.kapynotes`.
- The **DMG filename** has no space, `KapyNotes-1.0.0.dmg`, so the download URL
  needs no `%20`. The volume and the app inside it are both `Kapy Notes`.

`README.md` and the marketing site still say `Kapynötes`. Worth reconciling
separately — nothing in the build depends on it.

---

## The Mac DMG

Everything but notarisation is wired up and verified. The exported app is signed
by `Developer ID Application: Kapybara LLC`, runs hardened, carries only
`app-sandbox` and `network.client`, and has no `get-task-allow` — `release.sh`
fails the build if that entitlement ever reappears.

The one remaining step is a notarisation credential, stored once:

    xcrun notarytool store-credentials kapynotes-notary \
      --apple-id <your-apple-id> --team-id 96V66447C6 \
      --password <app-specific-password>

The password is an app-specific one generated at appleid.apple.com, not the
account password. Then:

    packaging/release.sh mac-direct

That archives, exports, builds and signs the DMG, submits it to Apple, waits,
and staples the ticket. Confirm the result before publishing:

    spctl -a -vvv -t open --context context:primary-signature build/release/KapyNotes-1.0.0.dmg

You want `source=Notarized Developer ID`. Without the ticket it reads
`rejected / source=Unnotarized Developer ID`, which is what an unnotarised
build shows on every machine but the one that built it.

`SKIP_NOTARIZE=1` builds the DMG without contacting Apple, for local testing.

Bump `version:` in `pubspec.yaml` for each public build so the DMG filename and
the in-app version track the release.

---

## The iOS App Store, when you get to it

Nothing exists on the Apple side yet, so in order:

**1. Certificate.** The keychain only has the Developer ID cert, which cannot
sign for the App Store. In **Xcode → Settings → Accounts**, sign in on the
Kapybara LLC team, then **Manage Certificates → + → Apple Distribution**.
Leave signing on Automatic; Xcode installs the provisioning profile on first
archive.

**2. App ID.** [Developer portal](https://developer.apple.com/account/resources/identifiers)
→ **Identifiers → + → App IDs → App**, explicit bundle ID
`com.kapybara.kapynotes`. No capabilities needed — the app uses no push,
iCloud, or sign-in services. If a Mac App Store build is ever a possibility,
tick macOS as well as iOS now; adding it later is harder and it is what enables
one listing to cover both platforms.

**3. App Store Connect record.** [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
→ **Apps → +**. Name `Kapy Notes`, bundle ID as above, SKU e.g. `KAPY-001`.

**4. Build and upload.**

    packaging/release.sh ios

Upload with **Transporter** from the Mac App Store, or `xcrun altool`. Every
upload needs a build number higher than the last — bump the `+N` in
`pubspec.yaml` (`version: 1.0.0+1`) or App Store Connect rejects it.

**5. Listing metadata.**

| Field | Value |
|---|---|
| Subtitle | 30 chars max, e.g. "Every line is a calculator" |
| Category | Productivity primary; Utilities is a reasonable secondary |
| Support URL | https://kapynotes.com |
| Privacy Policy URL | https://kapynotes.com/privacy |
| Copyright | 2026 Kapybara LLC |
| Age rating | 4+ |
| App Privacy | **Data Not Collected** — notes never leave the device and the exchange-rate request carries no user data |

Screenshots, both required, because `TARGETED_DEVICE_FAMILY = "1,2"` makes the
app universal:

- **iPhone 6.9"** — 1320 × 2868 or 1290 × 2796
- **iPad 13"** — 2064 × 2752 or 2048 × 2732

Export compliance is already answered in the repo:
`ITSAppUsesNonExemptEncryption = false`, accurate because the only network call
is an HTTPS GET to `open.er-api.com`. No `PrivacyInfo.xcprivacy` is needed —
the app uses no required-reason APIs, bundles no analytics, and
`path_provider_foundation` 2.6.0 is a pure-Dart FFI plugin with no native
binary of its own.
