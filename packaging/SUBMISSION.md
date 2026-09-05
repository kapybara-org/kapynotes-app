# Shipping Kapy Notes

One codebase, bundle ID `com.kapybara.kapynotes`, team `96V66447C6` (Kapybara LLC).

| Artifact | Channel | Status | Command |
|---|---|---|---|
| `KapyNotes-<version>.dmg` | Direct, kapynotes.com | **current plan** | `packaging/release.sh mac-direct` |
| `kapy-ios.ipa` | iOS App Store | **live, 1.0.0** | `packaging/release.sh ios` |
| `kapy-notes.aab` | Google Play | **live, 1.4.0** | `packaging/release.sh android` |
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

## iOS App Store v1.0.0 — live

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

### The two gates

Both are read-only, so neither can damage a record:

    packaging/preflight_ios.sh --submission    the repo and the toolchain
    packaging/audit_ios.py                     the live App Store Connect record

Run the first before archiving. Run the second before opening App Store
Connect, and again just before submitting: it exits non-zero on a blocker, and
it re-reads the record rather than trusting what was set earlier. That matters,
because `releaseType` has silently reverted from `MANUAL` to `AFTER_APPROVAL`
after a UI save at least once.

`audit_ios.py` also compares the store's version string against `pubspec.yaml`.
The record was originally created as `1.0` while the build declared `1.0.0`,
which is the classic reason a processed build never appears in the version
dropdown.

**App Privacy is the one thing neither gate can check.** The apps resource
exposes no data-usage relationship of any kind, so *Data Not Collected* has to
be confirmed by eye in the UI. Everything else is read from the live record.

Three API shapes worth recording, because the obvious form returns 404 and
reads as "not configured" when the resource is really there:

- availability is `GET /v1/apps/{id}/appAvailabilityV2`, not
  `/v2/apps/{id}/appAvailability`
- a single territory toggles through `PATCH /v1/territoryAvailabilities/{id}`,
  while the `/v2/` form of that same path returns `NOT_FOUND`
- the age-rating questionnaire only accepts a complete payload; patching one
  attribute at a time always fails with `ENTITY_ERROR.ATTRIBUTE.REQUIRED`

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

This section is about the **App Store only**. Play works the opposite way and
a published free app can never be made paid there; see *Pricing* under Google
Play before applying any of this to Android.

On the App Store, free to paid is allowed at any time and needs no review. The
catch is that it is a one-way door for everyone who already downloaded: an App
Store purchase is permanent, so every free download keeps the app forever,
including every future update. Flipping the price to 19.99 later only affects
new users.

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

---

## iOS App Store 1.7.0

1.0.0 went live on 2026-09-05, released manually from `PENDING_DEVELOPER_RELEASE`
once review passed. The store record now sits seven minor versions behind the
app, so the next iOS submission is a 1.0.0 → 1.7.0 jump and the listing has to
catch up with it before the build does.

### The version needs no Xcode change

`ios/Runner/Info.plist` reads `CFBundleShortVersionString` from
`$(FLUTTER_BUILD_NAME)` and `CFBundleVersion` from `$(FLUTTER_BUILD_NUMBER)`, so
bumping `version:` in `pubspec.yaml` is the whole job — an iOS archive built
today is 1.7.0 (8). The `MARKETING_VERSION = 1.0` entries in
`Runner.xcodeproj/project.pbxproj` belong to the **RunnerTests** target only and
never reach the shipped bundle. Do not "fix" them to match; they are inert.

### Three listing fields are now wrong, and one of them fails review

Sync landed in 1.5.0 and the record still describes a 1.0.0 app that had none.
All three must be corrected **before** 1.7.0 is submitted:

1. **Description.** It says `• Notes stored locally on your device` and
   `• No account, login, ads, or tracking`. Accounts and an optional server
   copy both exist now. Suggested replacement for those two lines:

   > • Notes stay on your device unless you turn on sync
   > • Optional account for sync — no ads, no tracking

2. **Review notes.** They still open with "This build has no in-app purchases,
   subscriptions, external purchase links, account, or login." A reviewer who
   reads that and then finds a sign-in screen has been told the app does
   something it does not. This is the field most likely to cost a rejection.
   Note that the corrected 1.0.0 text in the section above was never pushed
   either — App Store Connect refuses a PATCH to the review detail unless the
   four contact fields go with it.

3. **App Privacy.** Answered for an app that collected nothing. Sync collects an
   email address for the account, and stores note ciphertext the server cannot
   read. Email has to be declared; the note content is worth declaring as
   *Other Data* with linking off, since we hold bytes we cannot decrypt. This
   is answered on the record, not in a build, and a wrong answer here is a
   post-release removal rather than a rejection.

### What's New

Everything below is on iOS. Window pinning (1.6.0), the tray, the global
shortcuts and the self-updater are desktop-only and are deliberately absent.

> Sync, if you want it. Your notes on every device you own, encrypted on the
> device before they leave it — what reaches us is sealed, and we cannot read
> it. Signing in is your email and a six-digit code, with no password to invent.
> You pick an encryption passphrase that never leaves your device, and you are
> shown a recovery key once while you set up. Signing out leaves every note
> where it is.
>
> Export and import. Take every note out as a single .zip of markdown, readable
> in any editor, and read the same archive back later. The export lands in Files
> where you can move it anywhere. It is a copy you can take with you, not a
> scheduled backup, and the file is plain once it is saved.
>
> Links behave like links. Tap one to open or copy it, without changing the text
> you wrote.
>
> Kapy Notes opens on your latest note, ready for the next thought. Turn it off
> in Settings › General if you would rather keep your place.
>
> Copy Plain Text turns bullets and checkboxes into ordinary characters, so a
> list pasted into a message still reads as one.
>
> A line that counts something — 12 mangoes, 3 shirts — now totals like any
> other amount, and a labelled amount reads as its value.
>
> Kapy has moved into the header, and reacts to what you are doing.

### Build and upload

Unchanged from 1.0.0, and already scripted:

    packaging/preflight_ios.sh
    packaging/release.sh ios
    packaging/upload_ios.sh confirm     # record + the build numbers ASC holds
    packaging/upload_ios.sh upload      # validates, then delivers

`upload_ios.sh` reads `ASC_KEY_ID` and `ASC_ISSUER_ID` from
`packaging/.asc-credentials` and the key from
`~/.appstoreconnect/private_keys/`. That key carries App Manager, which is what
released 1.0.0 — so it is also enough to drive delivery from CI if an iOS
workflow is ever worth having. Export compliance still has to be answered on
each build before it can attach to a version.

---

## Google Play

**Live on the production track, serving version code 5 — that is 1.4.0.** The
three things this section used to call missing all exist now: the Play Console
listing, the upload keystore (`~/kapynotes-upload.jks`, with
`android/key.properties` pointing at it), and the service account. All of it is
reachable from this Mac, so `packaging/upload_play.py confirm` is the fastest
way to see what the Console actually holds:

    production   5                      completed
    beta         1                      completed
    alpha        no builds              draft
    internal     5                      completed

    node packaging/play_graphics.mjs              icon and feature graphic
    packaging/preflight_android.sh --submission   repo, signing and listing art
    packaging/release.sh android                  signed AAB to build/release/
    packaging/upload_play.py                      confirm, validate, deliver

### App record values

Enter these verbatim. The app name matches the App Store record, and fits both
stores' 30-character limit exactly.

| Field | Value |
|---|---|
| App name | `Kapy Notes - Memo & Calculator` |
| Default language | English (United States) |
| Package name | `com.kapybara.kapynotes` (**permanent**, see below) |
| App or game | App |
| Free or paid | **Free.** Same reasoning as iOS: a paid listing needs a merchant account, and v1.0.0 should not wait on one. |
| Category | Productivity |
| Tags | Notes, Calculator, Productivity |
| Contact email | hello@kapybara.company |
| Website | https://kapynotes.com |
| Privacy policy | https://kapynotes.com/privacy |
| Support URL | https://kapynotes.com/support |

### English (U.S.) listing copy

`packaging/play_listing.json` holds this same text and is what
`upload_play.py listing` actually pushes. The version below is here to be read
and approved; if you change one, change the other. The character counts are
checked by the script before anything is sent, because Play truncates an
overlong field silently instead of refusing it.

Pushed to the record on 3 September 2026, along with all 17 graphics.

**App name** (30 of 30 characters)

> Kapy Notes - Memo & Calculator

**Short description** (78 of 80 characters)

> Notepad with a live calculator on every line. Budgets, units, currency, lists.

**Full description** (1,648 of 4,000 characters)

> Kapy Notes is a fast, private notepad with a live calculator built into every line.
>
> Write a thought, type a calculation, and the answer appears right beside it. There is no mode to switch, no formula to set up, and no separate calculator to open.
>
> WRITE THE WAY YOU THINK
> Start with a plain note and add numbers wherever they belong. Kapy Notes reads each line as you type and keeps a running total at the bottom, so a shopping list, a travel budget, and a project estimate can live in the same place as the rest of your writing.
>
> WHAT PEOPLE USE IT FOR
> • Notes - meeting notes, ideas, and everyday scratch work
> • Checklists - groceries, packing, and to-dos you can tick off
> • Journal - dated entries with automatic day separators
> • Math - budgets, splits, percentages, and estimates
> • Conversions - currency, length, weight, volume, and temperature
>
> CALCULATIONS THAT READ LIKE SENTENCES
> • 1250 + 8% for tax or a tip
> • 120 EUR to USD at refreshed exchange rates
> • 350 g to oz while scaling a recipe
> • 180 C to F
> • 100 km / 2 h
>
> PRIVATE BY DEFAULT
> • Notes are stored on your device, not on our servers
> • No account and no login
> • No ads, no analytics, and no tracking
> • Works offline; the internet is used only to refresh currency rates
>
> BUILT TO STAY OUT OF THE WAY
> • Light and dark themes that follow your system setting
> • A two-pane layout on tablets and a single column on phones
> • Search across every note
> • Bold, bullets, and headings when a note needs structure
> • Timestamps in the time zone you choose
>
> Kapy Notes is free to use and has no in-app purchases.
>
> Exchange rates are supplied by Frankfurter, with ExchangeRate-API as a fallback.

Play rejects promotional decoration in the title and short description:
no emoji, no ALL CAPS words, no "#1", no "best", and no price claims. The copy
above is already clear of all of them. The section headers inside the full
description are allowed, because Play only restricts the title and the short
description.

### Listing graphics

`node packaging/play_graphics.mjs` renders the two assets the app build never
produces, into `build/store-listing/play-store/`:

| Asset | Spec | File |
|---|---|---|
| App icon | 512 x 512, 32-bit PNG, **alpha required**, under 1 MB | `icon-512.png` |
| Feature graphic | 1024 x 500, 24-bit PNG, **no alpha**, JPEG also accepted | `feature-graphic.png` |
| Phone screenshots | 5 at 1080 x 1920, 9:16, no alpha | `phone/` |
| 7-inch tablet | 5 at 1080 x 1920 | `tablet-7/` |
| 10-inch tablet | 5 at 1080 x 1920 | `tablet-10/` |

The alpha rule runs in opposite directions for the two graphics, which is the
easy thing to get wrong; `preflight_android.sh --submission` now checks the
dimensions, the alpha channel and the file size of both rather than only
counting screenshots.

The icon keeps the cream frame around the coral squircle on purpose. That is
what `values/colors.xml` sets as the adaptive-icon background, so the store
tile and the icon on the home screen after install are the same drawing.

A promo video is optional and there is none. Leaving it out is fine; adding one
later overlays a play button on the centre of the feature graphic, which is why
the artwork keeps its centre clear.

### Data Safety

Play's Data Safety form is stricter than Apple's App Privacy: it asks about
each data type separately instead of accepting one "not collected". The answers
below follow from the repo, not from intent.

- **Does your app collect or share any of the required user data types?**
  **No.** Notes, calculations and preferences are written to the app's own
  private storage through `path_provider` and never leave the device. There is
  no account, no backend, and no analytics, crash-reporting or advertising SDK
  in the dependency graph.
- The follow-up questions about encryption in transit, deletion requests and
  data types only appear once collection is declared, so the form ends there.
- **Advertising ID:** **not used.** No dependency merges
  `com.google.android.gms.permission.AD_ID` into the manifest; the only declared
  permission in the release build is `INTERNET`.
- **Photos, files, location, contacts, microphone:** none requested.

Storing data locally is not "collection" under Play's definition, which covers
data transmitted off the device. The rate refresh sends no note content: it is
an unauthenticated HTTPS GET for public USD rates, and the provider receives
only the connection metadata inherent to any HTTPS request, which
`https://kapynotes.com/privacy` discloses.

### Content rating and target audience

The IARC questionnaire, answered from the same audit that produced the App
Store 4+ rating:

- Category: **Utility, Productivity, Communication, or Other**
- Violence, sexuality, language, controlled substances, gambling: **No** to all
- Does the app let users interact or exchange content? **No**
- Does the app share the user's location? **No**
- Does the app allow the purchase of digital goods? **No**
- Does the app contain unrestricted internet browsing? **No.** The single
  attribution link opens the system browser; there is no in-app browser.

Expected result: **Everyone / PEGI 3**, matching 4+ on the App Store.

Target audience: select **13 and over**. Including an under-13 group pulls the
listing into the Families policy programme, with its own design and ads
requirements, for no benefit here. Answer **No** to "could your app's store
listing unintentionally appeal to children".

Other declarations: ads **No**, app access **all functionality available without
special access** (there is no login), and **No** to the government, financial,
health and news app categories.

### Repo-verified release settings

- [x] Package name `com.kapybara.kapynotes` pinned by preflight
- [x] Version `1.0.0`, version code `1`, from `pubspec.yaml`
- [x] `targetSdk` 36 and `compileSdk` 36, from Flutter 3.47.2
- [x] `INTERNET` declared in the release manifest
- [x] `ACTION_VIEW` / `https` query present for the attribution link
- [x] Release build type resolves a real signing config
- [x] Manifest does not force `debuggable`
- [x] Only `INTERNET` is requested; no `AD_ID`
- [x] All 5 screenshots present for phone, 7-inch and 10-inch
- [x] Store icon and feature graphic generated and spec-checked
- [ ] Upload keystore created and `android/key.properties` written

**The API 36 gate is already live.** Since 31 August 2026, a new app must
target Android 16 to be accepted at all. This build targets 36, so it clears
it, but that is the deadline that would silently reject the first upload if
Flutter were ever pinned back.

### The package name is permanent

`applicationId` is `com.kapybara.kapynotes`, matching the iOS bundle ID. It was
briefly Flutter's default `com.kapybara.kapy_notes`, and was corrected before
the first upload because **Play has no rename**. A wrong ID on the first upload
means abandoning the listing and starting again with no installs, ratings or
reviews. `preflight_android.sh` pins the value so it cannot drift.

### Two bugs the Android build shipped with

Both were found while wiring this up, and both only affect release builds,
which is exactly why neither showed up in development:

- **`INTERNET` was missing from `main/AndroidManifest.xml`.** Flutter adds it
  to the debug and profile manifests for its own tooling, so every rate refresh
  worked locally and would have failed silently in production.
- **No `ACTION_VIEW` / `https` entry under `<queries>`.** Android 11 package
  visibility means `url_launcher` cannot see a browser without one, so the
  exchange-rate attribution link would have done nothing.

Preflight now fails on either.

### Signing

Release signing is supplied out of tree through `android/key.properties`, which
is gitignored along with `*.jks`. One command creates both the keystore and the
properties file, prompting for a password it never echoes or stores in history:

    packaging/create_upload_keystore.sh

It writes `~/kapynotes-upload.jks`, refuses to overwrite an existing keystore,
and prints the SHA-1 and SHA-256 fingerprints that Play shows under **App
integrity**. To do it by hand instead, copy `android/key.properties.example`
and run:

    keytool -genkey -v -keystore ~/kapynotes-upload.jks \
      -keyalg RSA -keysize 2048 -validity 10000 -alias upload

**Back that keystore up somewhere durable.** Play App Signing re-signs for
distribution, but the upload key is how Play recognises you; losing it means a
key reset with Google before you can ship another update.

Without `key.properties`, Gradle falls back to the debug key so
`flutter run --release` still works. That build is not uploadable, so
`preflight_android.sh --bundle` checks the signer certificate and fails on
`CN=Android Debug` rather than let one reach Play.

### What only the Play Console can do

- Create the app. The API cannot, exactly as with App Store Connect.
- The **Data Safety** form, the content rating questionnaire, and the target
  audience declaration. Data Safety is stricter than Apple's App Privacy: it
  asks about each data type separately rather than accepting a single "not
  collected".
- Create the service account grant. `upload_play.py` needs a Google Cloud
  service account that has been invited under Users and permissions.

Set up on 3 September 2026 as
`kapynotes-play-publisher@kapynotes-play.iam.gserviceaccount.com`, with app-level
release permissions on Kapy Notes only and no account-level grants. Two things
cost time and will cost it again on the next Google Cloud project:

- The Play Console **API access** page could not be found from account
  settings. It was unnecessary: create the project, enable the Google Play
  Android Developer API on it, create the service account, then invite its
  email under **Users and permissions**. That path does not depend on where
  the Console has moved the shortcut.
- Key creation was blocked by the organisation policy
  `iam.disableServiceAccountKeyCreation`, which Google auto-enforces on new
  organisations under Secure by Default. The fix is an override scoped to the
  one project, not the organisation: set enforcement Off, create the key, then
  set the project back to inheriting. Existing keys keep working, so the
  exception does not need to stay open. If the override appears to take and
  key creation still fails, the newer managed constraint
  `iam.managed.disableServiceAccountKeyCreation` is enforced too and needs the
  same treatment.

A 401 means the key or the API; `The caller does not have permission` means the
service account has not been invited to the app yet.

### Account type: organization, so no closed-test gate

Confirmed on 3 September 2026: the Kapybara LLC Play account is an
**organization** account, so it can publish straight to production.

This is what it avoids. A **personal** account created after 13 November 2023
must run a closed test with **12 testers opted in for 14 continuous days**
before it can even apply for production access, and that application is
reviewed for up to a week. "Opted in" means installed, not invited, and the
14 days reset if the twelfth tester drops out on day seven. Organization
accounts are exempt from all of it.

Internal testing is still worth one pass to check the signed bundle on a real
device, but it is a choice here, not a gate.

### Pricing: free, and it cannot be undone

**Play is not the App Store on this point.** On the App Store a free app can be
flipped to paid at any time. On Play, once an app is published free, **it can
never become paid** — the only direction that stays open is paid to free. The
Console says as much on the pricing page, and that sentence is the whole
decision.

**Free is the only option that fits the product plan**, which is settled as of
3 September 2026: a free basic app, plus a **Pro Lifetime** unlock at USD 20
that adds sync and a raised page limit. Both features are still to be built.

A Paid listing charges for the download itself, so it cannot express that plan
at all — it would put the USD 20 in front of the basic version instead of in
front of Pro. Free plus a one-time in-app product is the shape that matches,
and it is also what iOS does, so the two stores stay coherent for anyone who
owns both devices.

The permanent free-to-paid door closing therefore costs nothing here. What it
does close is the option of ever charging for the download, which is not the
plan and would contradict the free basic tier.

Leave **automatic protection** on. It adds an installer check that nudges users
who obtained the app somewhere other than Play back to Play. That costs nothing
here because the website deliberately sends Android and iOS to the stores and
offers no direct download — see the note at the top of
`website/src/pages/index.astro`. Revisit the toggle only if a direct APK is
ever offered, because it would then nag those users.

### Delivery

`upload_play.py` defaults to the `internal` track, which is visible only to
named testers, so a first delivery cannot land in front of real users by
mistake. Promote from the Console after checking the build on a device.

    packaging/upload_play.py --track internal

The listing screenshots are already generated for all three form factors under
`build/store-listing/play-store/`, from the same scenes as the App Store set.

### Shipping 1.7.0, the first Play build with sync

Production is on 1.4.0. Going to 1.7.0 crosses 1.5.0, where accounts and sync
shipped, and that is what makes this more than a version bump. The build itself
is the easy half:

    packaging/preflight_android.sh --submission
    packaging/release.sh android                        # signed AAB, 1.7.0 (8)
    packaging/upload_play.py upload --track internal
    packaging/upload_play.py promote --track production --rollout 0.2

Version code comes from the `+N` half of `pubspec.yaml`, so it is 8 and Play
has not seen it. `promote` reassigns the code that was tested rather than
rebuilding, so production installs the exact bytes internal did.

**Three listing obligations come with sync, and two of them are removal-grade.**
Play enforces these after publication, not at review, so getting them wrong is
a takedown rather than a rejection:

1. **Data Safety is now a real disclosure.** The current answer is "no data
   collected", which stops being true the moment a build with sync reaches
   production. Two data types, and the second is the one easily missed:

   - **Personal info → Email address.** Optional, App functionality and
     Account management.
   - **App activity → Other user-generated content**, for the note text sync
     uploads. Optional, App functionality *only* — note content plays no part
     in managing an account. Not "Files and docs", which is for user files and
     documents; Google's description of Other user-generated content gives
     "notes" as one of its examples.

   Declare the note content even though it is end-to-end encrypted. Play asks
   whether data is *collected*, not whether it is legible to us — we transmit
   and store it, so it is. Nothing is *shared*: R2 is our own storage, not a
   third-party recipient.

   Do not declare Photos and videos or Files and docs. Attachments have server
   routes and a payload type but no client: `lib/export/archive.dart` says
   there are none to collect until the app can make one, and no image picker
   exists. That changes the day attachments ship.
2. **In-app account deletion — which does not exist, in either half.** This is
   the blocker, and it is missing code rather than a form. `lib/ui/account/
   sync_pane.dart` offers Sign out and nothing else, and the server has three
   routes — `attachments`, `keys`, `sync` — with no account route at all. The
   1.5.0 entry in `releases.ts` claims "Deleting your account, from the same
   place, removes everything"; that shipped as copy and not as a feature, and
   the claim is live on kapynotes.com today.

   Both stores require it once an app can create accounts: Apple under review
   guideline 5.1.1(v), where it is a rejection, and Play under its User Data
   policy, where it also wants a deletion URL reachable without installing the
   app and enforces after publication. So this has to be built before either
   store gets a 1.7.0 with sync in it — deletion in the app, a route on the
   server that erases the user, their notes and their key bundle, and a page on
   the site describing how to ask. `kapynotes.com/support` currently says the
   opposite: "there is no account to delete".
3. **The store description contradicts the build.** `play_listing.json` says
   "Notes are stored on your device, not on our servers" and "No account and no
   login" under PRIVATE BY DEFAULT. Both are accurate for the 1.4.0 that is
   live and wrong for 1.7.0. Do not push the listing before the build — the
   copy must not describe sync while production still serves 1.4.0. Replacement
   for that block:

       PRIVATE BY DEFAULT
       • Your notes stay on your device unless you turn on sync
       • Sync is end-to-end encrypted — we cannot read your notes
       • Optional account, used only for sync; no ads, analytics, or tracking
       • Works offline; the internet is used for sync and exchange rates

   `releaseNotes` still says "First release of Kapy Notes for Android" and
   needs the 1.5.0-to-1.7.0 story instead. The iOS *What's New* under
   **iOS App Store 1.7.0** covers the same ground and can be reused nearly
   verbatim, minus the App Store phrasing.

Order that respects all three: upload to internal → push the corrected listing
and Data Safety → promote to production. If a social login is ever added, Sign
in with Apple becomes mandatory on iOS; email codes alone do not trigger it.

### What changes when Pro Lifetime ships

Nothing below blocks v1.0.0. It is listed here because the free listing is
being published on the assumption that all of it is possible later, and it is.

- **Product type.** Pro Lifetime is a Play **one-time product**, configured as
  non-consumable so the entitlement is permanently owned and restores on a new
  device. It is not a subscription and not a listing price.
- **Play Billing is mandatory** for unlocking in-app features on Android. The
  Mac build sells the same Pro Lifetime for USD 19.99 direct from the website;
  honouring a licence bought there is fine, but the Android app must not gain
  a link or prompt that steers users to buy it outside Play. Anti-steering
  rules have been moving since the Epic litigation, so re-check them at
  implementation time rather than trusting this paragraph.
- **Start the payments profile early.** Selling anything needs a Play payments
  profile with bank and tax details, and verification is not instant. It is not
  needed to publish v1.0.0 free, so it is the thing most likely to be left
  until it is urgent.
- **Listing declarations change.** The store gains an "In-app purchases" badge
  and the price range. The iOS review notes and this document both currently
  state there are no in-app purchases; both have to stop saying that.
- **Data Safety changes with sync, not with billing.** Sync moves note content
  off the device, which turns the current "no data collected" answer into a
  real disclosure covering what is uploaded, that it is encrypted in transit,
  and that users can request deletion. That is the same release that owes Play
  in-app account deletion, above.
