# Kapy Notes

Offline-first notes where every line is also a live calculator. Write freely;
any line that looks like arithmetic is worked out as you type and its result
appears in a gutter beside it.

```
Lisbon trip budget

Flights for two
flights = 412 eur              412.00 EUR
flights to usd                 478.29 USD

Food and getting around        // rough guess
daily = 55 eur                  55.00 EUR
daily * 7                      385.00 EUR

total                        2,288.00 EUR
```

One Flutter codebase, four platforms: **macOS, Windows, iOS, Android.**

## Running it

```bash
flutter pub get
flutter run -d macos      # or: windows, <ios device>, <android device>
flutter test
```

Built on Flutter 3.47.2 against the standalone **`material_ui`** package
rather than `package:flutter/material.dart`. Material and Cupertino moved out
of the SDK in 3.44 and the in-SDK libraries are formally deprecated in the
November 2026 release, so this is where new code belongs; it also means design
fixes arrive on the package's own schedule instead of the quarterly SDK train.
`cupertino_ui` comes in transitively and backs the `.adaptive` widgets — there
is no direct import, so it is not listed as a dependency.

Verified on Flutter 3.47.2. Android needs JDK 17+ (`flutter config --jdk-dir`)
and SDK platform 36; iOS needs Xcode's iOS platform installed
(`xcodebuild -downloadPlatform iOS`). Goldens under `test/goldens/` render
with macOS system fonts — regenerate them on macOS with
`flutter test --update-goldens`.

## Releasing

Desktop releases are cut by tagging. The tag must match `version:` in
`pubspec.yaml`, and a job checks that before anything expensive runs:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

`.github/workflows/desktop-release.yml` then builds a notarised DMG on a macOS
runner and the Inno Setup installer on a Windows one, uploads both to the
`kapynotes` R2 bucket under `downloads/`, and cuts a GitHub Release. The
landing page pins both filenames, so bump them in
`website/src/pages/index.astro` and redeploy — the release job prints this
reminder in its summary.

Tags rather than pushes because the artifacts are named after the version and
served `immutable` for a year: republishing one filename would leave Cloudflare
edges serving the old bytes indefinitely.

`.github/workflows/desktop-ci.yml` runs on every push instead, building both
desktop platforms unsigned and keeping them as artifacts. Windows has to be
built there — `flutter build windows` needs a Windows host with Visual Studio's
C++ workload, and macOS does not offer the subcommand at all. Note the billing
multipliers on a private repo: Windows 2x, macOS 10x.

Local builds still work exactly as before:

```bash
packaging/release.sh mac-direct    # notarised DMG, using the keychain profile
packaging/release.sh mac-unsigned  # same image, no certificate; what CI builds
packaging/release.sh ios           # .ipa for App Store Connect
packaging/preflight_ios.sh --submission  # complete iOS readiness check
```

The app ships as `Kapy Notes` under bundle ID `com.kapybara.kapynotes`, signed
by Kapybara LLC (team `96V66447C6`). `SKIP_NOTARIZE=1` builds a DMG without
contacting Apple, for local testing. `packaging/SUBMISSION.md` covers the
certificates, the notarisation credential and the App Store metadata.

### The DMG window layout

Finder writes the installer window's background and icon positions into a
`.DS_Store`, and scripting Finder needs a desktop session no CI runner has. So
the layout is captured once and committed as `packaging/dmg/DS_Store` — without
the leading dot, which `.gitignore` would swallow. `build_disk_image` copies it
in and refuses to build if it is missing, rather than quietly shipping Finder's
default window.

Regenerate it after changing the window geometry constants in `release.sh` or
the artwork, then commit the result:

```bash
packaging/release.sh dmg-template
```

### In-app updates

Desktop builds schedule a quiet check of `dl.kapynotes.com/latest.json` five
seconds after launch and resume. The checker makes a network request at most
once every 24 hours after a successful response; failures retry after two
hours. When a newer release exists, the app puts a dot on the settings gear
and an **Update** button in Settings → Updates. Nothing is downloaded before
that button is pressed; the check is only a few hundred bytes of JSON.

The install itself is Sparkle on macOS and WinSparkle on Windows, behind the
`auto_updater` plugin. Only the install half is used: Sparkle's own background
check runs against the standard user driver, which throws its update panel on
screen the moment it finds something, so the quiet half is `UpdateChecker` in
`lib/data/update_checker.dart` instead.

There are two appcasts because the two frameworks disagree about what
`sparkle:version` means — Sparkle compares it against `CFBundleVersion` (the
`+N` half of pubspec's version), WinSparkle against the `ProductVersion` string
in `windows/runner/Runner.rc`. The release job writes both, plus `latest.json`,
with a five-minute cache header; they are the only mutable objects in the
bucket.

Because macOS compares build numbers, a release that forgets to bump `+N` would
tell every Mac it is already current. The `verify` job fails the release rather
than let that ship.

**Signing keys — already set up.** Both feeds are signed and the public halves
are compiled into the app, so a hijacked feed cannot ship a payload. The
EdDSA public key is `SUPublicEDKey` in `macos/Runner/Info.plist`; the DSA one
is `windows/runner/resources/dsa_pub.pem`. Their private halves are the
`SPARKLE_ED_PRIVATE_KEY` and `WINSPARKLE_DSA_PRIVATE_KEY` repository secrets,
and the release job fails loudly if either is missing.

The Sparkle private key also lives in the login keychain of the Mac it was
generated on, which is the only copy that can be re-exported. Print the public
key any time to check the plist still matches:

```bash
macos/Pods/Sparkle/bin/generate_keys -p        # needs `flutter build macos` first
macos/Pods/Sparkle/bin/generate_keys -x key.txt  # re-export for a new CI secret
```

Note `sign_update`'s `-s` flag is deprecated and now fails; the release job
uses `--ed-key-file`. The WinSparkle key is plain OpenSSL DSA and can be
regenerated anywhere:

```bash
openssl dsaparam -out dsaparam.pem 2048
openssl gendsa -out dsa_priv.pem dsaparam.pem
openssl dsa -in dsa_priv.pem -pubout -out windows/runner/resources/dsa_pub.pem
```

Rotating either key means the release after it cannot be installed by anyone
still running an older build — their copy only trusts the key it shipped with.

The macOS app is sandboxed, which forbids it from replacing its own bundle, so
installation goes through Sparkle's `Installer.xpc`. That needs
`SUEnableInstallerLauncherService` in `Info.plist` and the two
`mach-lookup.global-name` temporary exceptions in `Runner/*.entitlements` —
remove either and updates fail at install time, after the download.

On Windows, WinSparkle runs the Inno installer with `/VERYSILENT`, which skips
its `[Run]` entry; `RestartApplications=yes` is what brings the app back
afterwards. The install is per-user, so it raises no UAC prompt — but see below
for what SmartScreen still does.

### Windows signing

The installer is not Authenticode-signed — there is no certificate yet — so
SmartScreen shows "unknown publisher", and because reputation attaches to the
certificate rather than the file, that will not improve across releases. Buying
one needs a cloud HSM (e.g. Azure Trusted Signing) to sign from CI, since
code-signing keys must now live on certified hardware.

This is also the one place the in-app updater is not seamless: every Windows
update runs an unsigned installer, so SmartScreen warns each time. macOS has no
equivalent problem — the DMG is Developer ID signed and notarised.

## How it works

### The calculation engine (`lib/calc/`)

A purpose-built expression engine rather than a general maths library, because
the interesting behaviour is in the natural phrasing, the unit algebra and the
refusal to guess.

| File | Role |
|---|---|
| `lexer.dart` | Text → tokens. Absorbs `1,250` thousands separators, `$`/`€` symbols and `//` comments. |
| `parser.dart` | Tokens → AST. Recursive descent; `of`/`off`/`on`/`to`/`in`/`per` are operators. |
| `evaluator.dart` | AST → value, against a scope that carries down the note. |
| `unit.dart`, `unit_registry.dart` | Dimensional algebra over ~110 units plus live currencies. |
| `engine.dart` | Runs a whole note top to bottom. |
| `format.dart` | Compact display text and full-precision copy text. |
| `highlight.dart` | Re-runs the lexer to colour the note. |

**Percentages are a value type, not a text rewrite.** `20%` evaluates to a
`PercentValue`, so `1250 + 8%` means "add 8 percent *of 1250*" while
`0.08 + 1250` still means what it says. The same rule gives `20% of 80`,
`20% off 50` and `25 as a % of 200` without any of them being special-cased in
a regular expression.

**Units carry dimensions.** `100 km / 2 h` produces `50 km/h` because the unit
is a product of exponents, not a label. Conversions are offset-aware, so
`100 degC to degF` is `212 °F`, while `20 degC + 5 degC` treats the right side
as a difference and gives `25 °C`.

**A line that does not parse produces nothing.** Someone mid-sentence is not
someone with a syntax error, and "I have 3 apples" must not render a result.
Lines are only attempted when they carry an arithmetic signal, and anything
that fails to parse is left as plain text.

**A label followed by a marked amount is a value.** `Coffee $4.50`,
`Lunch 12 usd` and `Run 5 km` each read as the amount and join the running
total, so a budget needs no `=` on every line. The marker carries the whole
rule: a bare trailing number is refused, because `Lunch 12` and `Room 12` are
the same shape and nothing in the text separates them. Writing a currency or a
unit is the user saying which one they meant. This is tried only after the
whole line has failed to parse, so `100 km / 2 h` is still a division.

**Running scope.** A variable assigned on one line is available below it, and
`prev`, `sum`, `total` and `avg` accumulate as the note is read downward. A
line that is *only* `total` reports the total without adding itself to it.

### The editor (`lib/ui/editor/`)

Flutter can style a text field's content directly, so this is one real,
editable, syntax-coloured `TextField` — not the transparent-textarea-over-a-
mirrored-div stack a browser forces on you.

Results are aligned by laying the note out a second time with the same width,
style and strut the field uses, and reading each line's offset from it. The
gutter and the field share one `ScrollController`. That combination is what
keeps a result pinned to its line through wrapping, scrolling and text scaling
— and it is asserted directly in `test/note_editor_test.dart`, which compares
chip positions against the field's own `RenderEditable` geometry.

Clicking a result copies it at full precision.

Typed and pasted web addresses stay ordinary note text, but appear as links.
Tap one on touch devices, or Command-click on Apple platforms and Control-click
elsewhere, to open it. Selecting or long-pressing a link exposes a dedicated
Copy Link action while leaving the platform's normal text copy and paste intact.

Currency codes can sit directly beside an amount, such as `10usd` or `10eur`;
`rs` is accepted as an INR shorthand, so `10rs` and `10inr` are equivalent.
Lines that start with `//` are treated and styled as quiet comments.

Daily separator timestamps follow the time zone selected in Settings. The
default follows the device, while an explicit city uses bundled IANA rules so
day boundaries and daylight-saving changes are based on the original edit
instant. Existing separators are plain note text and are not rewritten when
the setting changes.

The sidebar uses that same time zone for each note's compact updated date and
time. Notes are kept newest-updated-first on load and move to the top as soon
as they are edited. During a search, the timestamp is temporarily replaced by
the matching line so body-only results still have context.

### Storage (`lib/data/`)

Everything is one JSON file in the platform's application-support directory.
No account, no sync, no server.

On iOS and Android, disk lookup is not on the launch critical path. The first
Flutter frame is a focused plain-text capture field with no calculator, theme,
font, image, or network setup ahead of it. Saved notes hydrate in the
background. If someone types before hydration finishes, that text becomes a
normal new note during the handoff, without dropping focus or the keyboard.

Writes are coalesced into a 250 ms window and forced out whenever the app is
backgrounded or asked to exit, with a write-then-rename so a crash mid-write
cannot truncate the file. The in-memory copy is always current, so nothing on
screen ever waits for the disk. Large JSON reads and all JSON writes are moved
off the UI isolate so a long note history cannot interrupt typing.

Exchange rates are the only networked feature. The cached snapshot is
published before the full calculator mounts, so currency maths is available
as soon as hydration completes and keeps working offline; a failed refresh
changes nothing. Refreshes use Frankfurter's v2 USD rates first and try the
ExchangeRate-API open endpoint only when the primary response fails validation.
Snapshots are never combined, and their source is cached for accurate
attribution. Network client creation and stale refreshes wait until after the
editor is ready. Rates then refresh on launch, resume, and every six hours while
the app stays open. With no rates ever fetched, currency lines simply stay
plain text.

## Notable deviations from the original spec

The spec described an Electron build. These changed for Flutter:

| Spec | Here | Why |
|---|---|---|
| mathjs | Purpose-built engine | No Dart equivalent with unit support, and percentages want to be a value type. |
| Layered textarea + mirrored div | One `TextField` with a custom controller | Flutter styles editable text natively. |
| Separate highlight tokenizer | The parser's own lexer | Colouring cannot drift from evaluation if it is the same code. |
| Regex `preprocess()` | Lexer and parser | `max(1,250)` and `1,250` need context to tell apart; a regex cannot. |
| `localStorage`, write per keystroke | JSON file, coalesced writes | A synchronous disk write per keystroke is the wrong trade off the web. |
| URL `?note=<id>` | Desktop selection plus mobile edit recency | Restores the right note across native app restarts. |
| React Query | `RatesRepository` | One cached resource does not need a query layer. |
| Two-pane only | Desktop two-pane; mobile editor with a notes drawer | Note taking stays one tap away on a phone. |

## Platform notes

- **macOS** — hidden title bar with the traffic lights inset into the sidebar;
  the toolbar's inert stretch is the window drag region. Sandboxed, with
  `network.client` added for the rate refresh.
- **Windows / Linux** — native caption retained.
- **iOS / Android:** accepts text on the first Flutter frame, then opens the
  most recently edited note when no launch text was entered. A launch draft
  becomes a new note, unless the app was opened from the Write widget, which
  carries it into the note being written instead. Search and the full note
  list are built only when the hamburger drawer first opens; the gutter is
  fixed-width and the divider is hidden.
- **The Write widget (iOS / Android)** — one cell on the Home Screen, the same
  action on the Lock Screen, and on iOS 18 a control for Control Centre and
  the Action button. It shows a pencil and the word *Write*, and deliberately
  no note text: a widget that previewed what somebody wrote would have to read
  the note store, keep itself refreshed against a system budget, and show that
  writing to whoever picks up a locked phone. Showing only the action costs
  none of that, and means the widget is drawn once and never updated again.
  Tapping it opens the **last note at its end**, keyboard up, rather than
  making a new one — a way back into the notebook, not a way to fill it with
  one-line fragments, and not something that spends a plan's note allowance on
  a mis-tap. The platform reports that a launch came from the widget over a
  single method channel, `kapynotes/quick_capture`; the only Dart that knows
  is `lib/core/quick_capture.dart`, and everything else about the launch is
  unchanged. Android names its own intent action; iOS opens `kapynotes://write`
  and the scene delegate parks it.
- **Every platform:** *Ready to type on open* is on by default. The latest note
  opens focused on a fresh line, and returning to the app starts another
  append position without saving empty lines. It can be disabled in Settings
  › General.
- Shortcuts: `⌘/Ctrl N` new note, `⌘/Ctrl F` search, `⌘/Ctrl \` toggle
  sidebar, `⌘/Ctrl ⌫` delete note. Two more are registered with the OS and
  answer from inside any other app: `⌥⌘X` / `Ctrl+Shift+X` summons the window,
  `⌥⌘N` / `Ctrl+Shift+N` summons it onto a blank note. All of them are
  rebindable in Settings › Shortcuts.
- Closing the window quits on Windows and leaves the process running on macOS,
  each platform's own convention. *Keep running in the tray* (Settings ›
  General, off by default) makes both hide to a tray icon instead, so the
  system-wide shortcuts go on answering. The icon carries Open, New Note and
  Quit — the only way out of an app whose close button no longer closes it —
  and exists only while the setting does. Windows takes a single-instance lock
  to go with it: an app that looks shut is one whose desktop icon gets clicked
  a second time, and two copies share one notes file.

## Window chrome

macOS hides the title bar so the toolbar can act as window chrome, which means
the OS draws the traffic lights straight over whatever is in the window's
top-left corner. Which widget that is depends on state: the sidebar when it is
showing, the toolbar when it is collapsed. `WindowChrome` owns the geometry and
each pane asks for the inset it needs — the sidebar is tall enough to start
*below* the buttons, while a one-row toolbar has to step *around* them.

On a touch device the same corner belongs to the status bar and the bottom edge
to the home indicator. The compact layout's `Scaffold` handles its top chrome,
while the editor folds the bottom inset into the padding the text *and* the
results gutter share — insetting only one would pull them apart.

## Two alignment traps

Both were caught on a real device after the widget tests passed, and both now
have tests of their own.

`TextField` merges the style you give it *over* the Material text theme, so
any metric property you leave unset — `letterSpacing` especially — is
inherited. The field then renders wider than the same string measured with
your style alone, wraps somewhere else, and every result below the wrap sits
on the wrong line. `EditorMetrics.textStyle` pins all of them.

`RenderEditable` also wraps text inside `width - (1px + cursorWidth)`, holding
that sliver back for the caret. It is smaller than one monospace glyph, so it
only bites for lines that land in the gap — which is exactly what makes it
easy to ship. `EditorMetrics.textLayoutWidth` applies it to both sides.
