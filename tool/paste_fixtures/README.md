# Paste fixtures

Real clipboard payloads for testing the "paste anything faithfully" pipeline. One directory per capture under
`test/fixtures/paste/<source>/<case>/`: a `fixture.json` plus one file per clipboard representation. The generated
list of every fixture is `test/fixtures/paste/INDEX.md`; `node tool/paste_fixtures/validate.mjs [--index]` checks them.

`fixture.json` has `source`, `case`, `app`, `platform`, `capture` (`real` or `synthesized`), `how`, `url` (when there is one),
`notes` and `items[].representations[] = { type, file }`. Types use the platform's own names (macOS UTIs, Windows
formats such as `HTML Format` stored as the full CF_HTML payload with its header). Files hold the exact bytes. A
`sidecars` list names files stored beside the representations that are **not** clipboard types (for example the
`clip_image001.png` a Word `file:///` URL points at, or the two files a Finder fixture refers to).

`macos-snapshot.json`, beside a macOS fixture whose read derives something (rich text as HTML, resources, VS Code's data,
files, an image), is the map the macOS rich clipboard's `read` returns for it, bytes as `{"base64": …}`. The hosted
`RichClipboardFixtureTests` compares it; `tool/paste_fixtures/update_macos_snapshots.sh` regenerates it.

## The three kinds of fixture

**Headless web captures (`capture: real`, `headless/`).** Pages are driven in `chrome-headless-shell` over CDP with
puppeteer-core. A selection is a DOM range plus `document.execCommand('copy')`; a copy button is clicked for real
(trusted input event); the Google Docs / Sheets editors are driven with CDP key events carrying the editing commands
(`selectAll`, `copy`). What Chrome put on its (in-memory) clipboard is read back with
`navigator.clipboard.read({unsanitized: ['text/html']})`. Two things are reconstructed because the headless clipboard
does not expose them, so read them as "what Chrome for macOS writes", not as a byte capture of NSPasteboard:

* `public.html` is the serialized markup prefixed with `<meta charset='utf-8'>`, exactly as Chromium's
  `ClipboardMac::WriteHTML` does (also for the async `navigator.clipboard.write` path).
* `org.chromium.source-url` is the page URL, written for selection copies (Chrome's copy event). Copy-button captures have
  none, because the page writes through the async clipboard API.

**Synthesized native apps (`capture: synthesized`, `synthesize/`).** Word, Outlook, Excel, Numbers, Slack, Gmail,
VS Code, the ChatGPT/Claude Mac apps, Finder are written by Node scripts (`word.mjs`, `sheets.mjs`, `apps.mjs`) from
the structure those apps emit; Apple Notes, Pages, Safari and the copied image by `apple.swift`, which builds RTF /
flat RTFD / Cocoa HTML with `NSAttributedString` (how Cocoa apps produce them) and the WebArchive plist by hand. Each
fixture's `notes` says what is solid and what is a guess. The Mac/Windows Word, Outlook and Excel fixtures are the
least certain, the ChatGPT and Claude Mac app fixtures are explicit guesses. Real captures replace them one for one.

**Real native captures (`capture_macos.swift`).** Copy something in the app, then run from the repo root:

```
swift tool/paste_fixtures/capture_macos.swift <source> <case> [--pasteboard <name>] [--out <dir>] [--force]
```

It reads `NSPasteboard.general` (or the named pasteboard) and writes every type of every item, then a stub
`fixture.json` whose `app`, `how` and `notes` say `TODO` (`validate.mjs` fails until you fill them in). It never calls
`clearContents`, `setData`, `setString`, `setPropertyList` or `writeObjects`. Using the source/case of a synthesized
fixture replaces it; a real fixture is only replaced with `--force`. `test_capture_macos.swift` is the self-test: it
fills a private named pasteboard, never the general one, and captures that.

## Guarding the system clipboard

The Mac that built this corpus is someone's working machine, so the headless scripts never touch
`NSPasteboard.general`, and `capture.mjs` / `gcapture.mjs` read `NSPasteboard.general.changeCount` around every fixture and
abort (exit code 9) if it moves. `watch_changecount.sh` logs the count once a second while a session runs, so a change can be
matched to what was running. Headless Chrome's clipboard is in-memory: hundreds of copies moved the count zero times
inside the capture windows.

## Recapturing the web fixtures

```
cd tool/paste_fixtures/headless
npm install                                   # puppeteer-core only; node_modules is git-ignored
npx @puppeteer/browsers install chrome-headless-shell@stable --path "$HOME/.capy/work/paste-fixtures"
export FIXROOT=$PWD/../../../test/fixtures/paste PASTE_FIXTURE_SCRATCH=$HOME/.capy/work/paste-fixtures
node capture.mjs specs/wikipedia.mjs          # also: web.mjs chatgpt.mjs gemini-perplexity.mjs  [caseFilter]
./run_google.sh                               # Google Docs / Sheets editors
node apply_notes.mjs $FIXROOT                 # notes.json is the source of truth for the notes
```

`scan.mjs` scores candidate share links (ChatGPT, Gemini, Perplexity) by math / tables / code / lists. The links came from
Hacker News (Algolia API: `hn.algolia.com/api/v1/search?query="chatgpt.com/share"`). Shared conversations are deleted and
change over time, so a recapture can differ; that is expected. Scripts pin which assistant turn to use where it mattered.

## What could not be captured, and why

* **claude.ai/share**: Cloudflare "Just a moment" challenge for headless Chrome, still there after 20 s. No Claude web fixture;
  the Claude Mac app one is a guess.
* **stackoverflow.com**: the same Cloudflare challenge. `stackexchange/askubuntu-answer-code-blocks` (Ask Ubuntu, same
  markup, not challenged) stands in.
* **Perplexity copy button**: clicking the answer's "Copy" button made no clipboard API call in headless Chrome, so only
  selection captures exist.
* **Gemini copy button**: the signed-out share page has only "Copy prompt" on the user turns; selection captures only.
* **Notion (notion.site)**: most of 38 sampled public pages returned the Cloudflare challenge; the two that loaded had one
  image or two code blocks and no toggles/to-dos/callouts. No Notion fixture yet: capturing one also needs headless copy, which I paused after the system pasteboard counter moved (see the report).
* **Windows and Android/iOS** payloads can only be synthesized here; there is no Windows capture script.
