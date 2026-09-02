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
| Copyright | `2026 Kapybara LLC` (App Store Connect adds the © symbol) |
| Support URL | https://kapynotes.com/support |
| Marketing URL | https://kapynotes.com |
| Privacy Policy URL | https://kapynotes.com/privacy |
| Price | **Free at launch.** Paid is the eventual intent, but v1.0.0 ships free so the first submission does not wait on the Paid Apps Agreement. See *Going paid later* below. |

### English (U.S.) listing copy

All of the copy below, plus the subtitle, categories, privacy policy URL and
both screenshot sets, is already live on the record, with one exception:
the review notes, which are called out under **Review notes**. Re-push any
field with the same values if it is ever cleared.

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

> This build has no in-app purchases, subscriptions, external purchase links,
> account, or login. All functionality is available immediately after launch.
> Notes and calculations are stored only on the device. The only network
> activity is an HTTPS refresh of public currency rates from Frankfurter, with
> ExchangeRate-API as a fallback; no note content is included. To test, enter
> `1250 + 8%` or `100 km / 2 h` on any line and the result appears beside it.

The copy above is **not yet on the record**. App Store Connect refuses a PATCH
to the review detail unless the four contact fields are sent with it, so the
notes still open with the old "This paid App Store build is the Pro Lifetime
edition" sentence. Paste the corrected text when you fill in the App Review
contact details, or the reviewer is told the app is paid while the listing
shows it as free.

### Repo-verified release settings

- [x] Bundle ID `com.kapybara.kapynotes`
- [x] Team `96V66447C6`
- [x] Version and build `1.0.0+1`
- [x] Automatic App Store signing export options
- [x] Universal iPhone and iPad target (`TARGETED_DEVICE_FAMILY = "1,2"`)
- [x] `ITSAppUsesNonExemptEncryption = false`
- [x] App privacy manifest is a Runner target resource
- [x] 1024 by 1024 marketing icon is present and opaque
- [x] Adaptive light/dark launch screen uses the canonical Kapy mark on iPhone and iPad
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

- [x] Create an Apple Distribution certificate. Present as of September 2, 2026: `Apple Distribution: Kapybara LLC (96V66447C6)`.
- [x] Register the explicit App ID `com.kapybara.kapynotes` with no special capabilities. The exported IPA embeds `iOS Team Store Provisioning Profile: com.kapybara.kapynotes`, resolving `96V66447C6.com.kapybara.kapynotes`.
- [x] Create the App Store Connect app record using the settled values above. Created as app id `6807810082`. The version record was renamed `1.0` to `1.0.0` so it matches `CFBundleShortVersionString`.
- [x] Deploy the website. The homepage, privacy policy, support page, and terms all return HTTP 200 as of September 2, 2026.
- [ ] Answer App Privacy as **Data Not Collected**. The app sends no notes, calculations, identifiers or analytics; whichever rate source is contacted receives only the connection metadata inherent to an HTTPS request, which the privacy policy discloses. Frankfurter says its API does not collect personal data, while Cloudflare receives basic analytics information. ExchangeRate-API remains a fallback, so request written confirmation from both providers if App Review requires it.
- [x] Complete the updated age-rating questionnaire. The repo audit supports **4+**: no in-app controls, messaging, user-generated network content, advertising, violence, sexual content, substances, gambling, loot boxes, or unrestricted web access. Submitted through the API; the record now reads `FOUR_PLUS` and Brazil `L`.
- [x] Content Rights is **Yes, rights are secured** (`USES_THIRD_PARTY_CONTENT`) because the app displays third-party exchange-rate data.
- [x] Export compliance answered itself. Build 1 processed `VALID` and reports
  `usesNonExemptEncryption = false`, picked up from `Info.plist`.
- [ ] Answer IDFA **No** when the submission flow asks. No advertising or IDFA
  SDK is in the dependency graph.
- [x] DSA trader status is **Active** across 27 EU countries, last updated
  14 June 2026. It lives at App Store Connect → Business → Agreements →
  Compliance, not on the app record.
- [x] Availability is set to 174 of 175 territories, with new territories opted
  in. **China mainland is excluded**: mainland distribution has required an ICP
  filing number for new apps since 1 September 2023, and Apple already reports
  `CANNOT_SELL` for that storefront. Re-enable it only alongside a filing.
- [x] Price is set to **Free** (USA base territory, price point `10000`). A free
  price schedule needs no Paid Apps Agreement, which is what unblocked the
  first submission.
- [ ] Accept the Paid Apps Agreement and finish banking and tax details before
  the app can ever be sold. Not required to ship v1.0.0 free.
- [x] Review notes are set on version 1.0.0, with `demoAccountRequired` false.
- [x] App Review contact details are filled in, and the review notes no longer
  describe the build as paid.
- [x] Release type is `MANUAL`. Note that it reverted to `AFTER_APPROVAL` once
  after a UI save, so re-check it just before submitting.

Two gates, one local and one against the live record:

    packaging/preflight_ios.sh --submission

checks the repo and toolchain before archiving. Everything the App Store
Connect API can see — version, build, listing, screenshots, rating, price,
availability, review contact — was verified separately and passed 25 of 25
checks. **App Privacy is the one thing the API cannot read at all**: the app
resource exposes no data-usage relationship, so *Data Not Collected* has to be
confirmed by eye in the UI.

Two API paths worth recording, because the obvious ones return 404 and read as
"not configured" when the resource is really there:

- availability is `GET /v1/apps/{id}/appAvailabilityV2`, not
  `/v2/apps/{id}/appAvailability`
- a single territory toggles through `PATCH /v1/territoryAvailabilities/{id}`,
  while the `/v2/` form of that same path returns `NOT_FOUND`

Run the read-only gate before archiving or opening App Store Connect:

    packaging/preflight_ios.sh --submission

### Screenshots

Both sets are required because the app is Universal.

    packaging/screenshots.sh all

That builds the simulator app and writes PNGs at the exact sizes App Store
Connect expects:

- `build/screenshots/iphone-6.9/` — 1320 × 2868, from iPhone 16 Pro Max
- `build/screenshots/ipad-13/` — 2064 × 2752, from iPad Pro 13-inch

Uploaded, all eight accepted with no errors. Apple files these two sizes under
the older display-type enums, `APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129`; the
6.9-inch and 13-inch enums do not exist in the API.

Four scenes per device — a currency budget, a percentage estimate, a scaled
recipe and an invoice in dark mode — each one a seeded store written into the
simulator's container by `packaging/screenshot_seed.py` and captured after a
relaunch. Nothing demo-only is compiled into the app. Rates in the seed are
frozen, so a rerun produces the same figures without the network.

The iPhone scenes keep the full note visible; the caret shows that the compact
editor is ready to type. Re-run a single device with `screenshots.sh iphone`
or `screenshots.sh ipad`.

### Build and upload

From `app/`:

    flutter build ipa --release \
      --export-options-plist=packaging/ExportOptions-ios-appstore.plist

The equivalent repository wrapper is:

    packaging/release.sh ios

Then confirm the record and deliver the build:

    packaging/upload_ios.sh

That looks the app record up by bundle ID, prints the build numbers App Store
Connect already holds, runs Apple's validation, and only then uploads. It needs
an App Store Connect API key; the script header explains the one-time setup.
Every upload needs a build number higher than the previous upload.

Transporter.app and Xcode Organizer deliver the same package if you would
rather click through it. The app record itself has to be created in the App
Store Connect UI either way, because Apple's API rejects CREATE on the apps
resource.

After processing, install the build through TestFlight on a real iPhone and
iPad. Attach the processed build to version 1.0.0, complete every required
metadata section, choose the release mode, and submit for review.

### Going paid later

Free to paid is allowed at any time and needs no review. The catch is that it
is a one-way door for everyone who already downloaded: an App Store purchase is
permanent, so every free download keeps the app forever, including every future
update. Flipping the price to 19.99 later only affects new users.

Two consequences worth deciding on before the free window gets long:

- Keep the free window deliberate and short if the plan is really a paid app.
  The giveaway is small at launch and grows with every download.
- When the time comes, a non-consumable **Pro Lifetime** in-app purchase is
  usually the better instrument than flipping the app price. It keeps free
  installs as the acquisition funnel and puts the paywall where you control
  it, rather than trading the whole funnel for a cold-start 19.99 listing.
  It does mean StoreKit work and a new App Privacy review, and the review
  notes above would have to stop saying there are no in-app purchases.

The website still sells the Mac build as Pro Lifetime at USD 19.99. That is
fine alongside a free iOS app, but do not add a purchase link for it inside
the iOS app: buying digital content used in the app has to go through Apple.
The app's only outbound link is the exchange-rate attribution, and it should
stay that way.

### v1.1 sync reminder

When accounts ship, add in-app account deletion. If any social login is added,
also add Sign in with Apple. Provide App Review with a working demo account.
