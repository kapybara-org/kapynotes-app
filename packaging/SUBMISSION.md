# Shipping Kapy Notes

One codebase, bundle ID `com.kapybara.kapynotes`, team `96V66447C6` (Kapybara LLC).

| Artifact | Channel | Status | Command |
|---|---|---|---|
| `KapyNotes-<version>.dmg` | Direct, kapynotes.com | **current plan** | `packaging/release.sh mac-direct` |
| `kapy-ios.ipa` | iOS App Store | **v1.0.0 submission** | `packaging/release.sh ios` |
| `kapy-macos.pkg` | Mac App Store | not in use | `packaging/release.sh mac-store` |

The product is called **Kapy Notes** in the Dock, on the Home Screen, in the
bundle (`Kapy Notes.app`), and in the in-app wordmark. The App Store listing
uses **Kapy Notes - Memo & Calculator**, which is exactly 30 characters.

Two deliberate exceptions:

- The **bundle ID** stays lowercase reverse-DNS, `com.kapybara.kapynotes`.
- The **DMG filename** has no space, `KapyNotes-1.0.0.dmg`, so the download URL
  needs no `%20`. The volume and the app inside it are both `Kapy Notes`.

`README.md` and the marketing site still say `Kapynötes`. Worth reconciling
separately. Nothing in the build depends on it.

---

## The Mac DMG

Everything but notarisation is wired up and verified. The exported app is signed
by `Developer ID Application: Kapybara LLC`, runs hardened, carries only
`app-sandbox` and `network.client`, and has no `get-task-allow`. `release.sh`
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

### The installer window

The image opens onto Kapy's own artwork: the app on the left, Applications on
the right, and a dashed arrow between them. `packaging/dmg/` holds the pieces —
`background.tiff` (1x and 2x in one file) and `VolumeIcon.icns`. Both are
committed, so a release build only copies them in. Redraw them after a brand
change with:

    swift tool/generate_dmg_background.swift

`release.sh` positions the icons by scripting Finder, which macOS gates behind
Automation permission. **Run it from Terminal the first time** and approve the
prompt for "Terminal wants to control Finder"; permission cannot be granted
from a background process, and until it is the layout step is skipped with a
warning. The image it produces is still complete and installable — it just
opens as a plain Finder window, so check the window before publishing.

The window geometry lives in `release.sh` (`WINDOW_W`, `ICON_Y`, and friends)
and is duplicated in the drawing tool. They have to agree, or the icons land
off their cards.

---

## iOS App Store v1.0.0

### App record values

Enter these values verbatim.

| Field | Value |
|---|---|
| App name | `Kapy Notes - Memo & Calculator` |
| Primary language | English (U.S.) |
| Bundle ID | `com.kapybara.kapynotes` |
| SKU | `kapynotes-ios` |
| Team | Kapybara LLC (`96V66447C6`) |
| Version | `1.0.0` |
| Build | `1` |
| Primary category | Productivity |
| Secondary category | Utilities, optional |
| Copyright | `© 2026 Kapybara LLC` |
| Support URL | https://kapynotes.com |
| Marketing URL | https://kapynotes.com |
| Privacy Policy URL | https://kapynotes.com/privacy |

### English (U.S.) listing copy

**Subtitle** (28 of 30 characters)

> Notes with a live calculator

**Promotional text** (132 of 170 characters)

> Turn everyday notes into instant answers. Write calculations, conversions, budgets, plans, and lists in one calm, private workspace.

**Description** (727 of 4,000 characters)

> Kapy Notes is a fast, private notebook with a live calculator built into every line.
>
> Write a thought, type a calculation, and see the result right beside it. There is no mode switching, formula setup, or separate calculator required.
>
> USE IT FOR
> • Everyday notes and lists
> • Budgets and expense estimates
> • Currency, unit, and percentage calculations
> • Planning, journaling, and quick scratch work
>
> BUILT FOR FOCUS
> • Instant, editable calculations as you type
> • A clean layout for iPhone and iPad
> • Light and dark appearance
> • Notes stored locally on your device
> • No account, login, ads, or tracking
>
> Kapy Notes works offline for notes and calculations. An internet connection is used only to refresh currency exchange rates.

**Keywords** (97 of 100 bytes)

    notepad,math,budget,currency,converter,percent,lists,offline,private,productivity,journal,planner

**Review notes**

> App is fully local-first; no account or login required for any feature.

### Repo-verified release settings

- [x] Bundle ID `com.kapybara.kapynotes`
- [x] Team `96V66447C6`
- [x] Version and build `1.0.0+1`
- [x] Automatic App Store signing export options
- [x] Universal iPhone and iPad target (`TARGETED_DEVICE_FAMILY = "1,2"`)
- [x] `ITSAppUsesNonExemptEncryption = false`
- [x] App privacy manifest is a Runner target resource
- [x] 1024 by 1024 marketing icon is present and opaque
- [x] No analytics, crash-reporting, advertising, or IDFA SDK is in the iOS dependency graph
- [x] Privacy policy source exists at `/privacy`
- [x] Real two-pane iPad layout, not a stretched phone layout
- [x] Source-aware exchange-rate attribution and fallback link
- [x] `url_launcher_ios` ships an empty privacy manifest, so it adds no disclosures

### The iPad layout

A Universal app is reviewed on iPad, and until this release the app forced the
compact phone layout there: one column, a hamburger drawer, and most of a
13-inch display left empty. That is the shape of a Guideline 4.0 rejection.

The compact/wide switch is now decided by width alone, so iPad gets the same
sidebar, editor and results columns the desktop build uses. Two insets come
with that, because the wide layout is its own chrome rather than a `Scaffold`:
it takes the bottom safe area so the running total clears the home indicator,
and it lifts both panes over the software keyboard. Both are covered by tests
in `test/app_test.dart` under `window chrome`.

The compact layout still applies to every iPhone, and to an iPad in a narrow
Split View.

### Exchange-rate sources and attribution

Frankfurter is the primary source, using its public v2 USD rates endpoint. If
that request times out, returns an error, or produces an incomplete snapshot,
the app requests the existing ExchangeRate-API open endpoint instead. The two
datasets are never merged, and a failed refresh never replaces cached rates.

The source is persisted with each snapshot. Settings shows **Rates by
Frankfurter** for primary data, or the fallback's required **Rates By Exchange
Rate API** credit when that source is active, with the corresponding link and
the date the app refreshed the snapshot. Legacy source-less caches are credited
to ExchangeRate-API because that was the only provider used by those builds.
The labels, links, primary-only path, failover path, and cache preservation are
pinned by tests.

This source link is the app's only outbound link and the reason `url_launcher`
is a dependency.

### Apple-account and publishing checklist

- [ ] Create an Apple Distribution certificate. The September 1, 2026 local audit found only `Developer ID Application: Kapybara LLC (96V66447C6)`.
- [ ] Register the explicit App ID `com.kapybara.kapynotes` with no special capabilities.
- [ ] Create the App Store Connect app record using the settled values above.
- [ ] Deploy the website. `kapynotes.com` is registered on Cloudflare and its zone answers, but no record points at the Worker, so the support and privacy URLs do not resolve. Run `wrangler login`, then `npm --workspace website run deploy`.
- [ ] Answer App Privacy as **Data Not Collected**. The app sends no notes, calculations, identifiers or analytics; whichever rate source is contacted receives only the connection metadata inherent to an HTTPS request, which the privacy policy discloses. Frankfurter says its API does not collect personal data, while Cloudflare receives basic analytics information. ExchangeRate-API remains a fallback, so request written confirmation from both providers if App Review requires it.
- [ ] Complete age rating as **4+**, IDFA as **No**, and export compliance as **No non-exempt encryption**.

### Screenshots

Both sets are required because the app is Universal.

    packaging/screenshots.sh all

That builds the simulator app and writes PNGs at the exact sizes App Store
Connect expects:

- `build/screenshots/iphone-6.9/` — 1320 × 2868, from iPhone 16 Pro Max
- `build/screenshots/ipad-13/` — 2064 × 2752, from iPad Pro 13-inch

Four scenes per device — a currency budget, a percentage estimate, a scaled
recipe and an invoice in dark mode — each one a seeded store written into the
simulator's container by `packaging/screenshot_seed.py` and captured after a
relaunch. Nothing demo-only is compiled into the app. Rates in the seed are
frozen, so a rerun produces the same figures without the network.

The iPhone scenes show the keyboard, because the compact editor deliberately
opens ready to type. Re-run a single device with `screenshots.sh iphone` or
`screenshots.sh ipad`.

### Build and upload

From `app/`:

    flutter build ipa --release \
      --export-options-plist=packaging/ExportOptions-ios-appstore.plist

The equivalent repository wrapper is:

    packaging/release.sh ios

Upload `build/ios/ipa/*.ipa` with Transporter or Xcode Organizer. Every upload
needs a build number higher than the previous upload.

After processing, install the build through TestFlight on a real iPhone and
iPad. Attach the processed build to version 1.0.0, complete every required
metadata section, choose the release mode, and submit for review.

### v1.1 sync reminder

When accounts ship, add in-app account deletion. If any social login is added,
also add Sign in with Apple. Provide App Review with a working demo account.
