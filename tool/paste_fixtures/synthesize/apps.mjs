// Slack, Gmail, VS Code, ChatGPT/Claude desktop apps and Finder clipboard payloads, synthesized.
import { writeFixture, webCustomData, samplePng } from './common.mjs';

const META = "<meta charset='utf-8'>";

// ---------------- Slack desktop (Electron/Chromium: HTML goes through ClipboardMac, so it carries the meta prefix) ----------------
const slackHtml = META + `<div class="p-rich_text_block" dir="auto" style="box-sizing: inherit;"><div class="p-rich_text_section" style="box-sizing: inherit;"><span data-stringify-type="bold" class="c-mrkdwn__bold" style="box-sizing: inherit; font-weight: 900;"><b data-stringify-text="*Release 2.4 is out*" style="box-sizing: inherit;">Release 2.4 is out</b></span> <span class="c-emoji c-emoji__medium c-emoji__single" data-stringify-type="emoji" data-stringify-emoji=":tada:" style="box-sizing: inherit;"><img class="c-emoji__img" alt=":tada:" title=":tada:" src="https://a.slack-edge.com/production-standard-emoji-assets/14.0/apple-medium/1f389@2x.png" style="box-sizing: inherit;" /></span> <span data-stringify-type="italic" class="c-mrkdwn__italic" style="box-sizing: inherit;"><i data-stringify-text="_thanks to everyone_" style="box-sizing: inherit;">thanks to everyone</i></span> and <span data-stringify-type="strike" class="c-mrkdwn__strike"><strike data-stringify-text="~old plan~">old plan</strike></span>, details in <a class="c-link" data-stringify-link="https://example.com/release/2.4" delay="150" data-sk="tooltip_parent" href="https://example.com/release/2.4" rel="noopener noreferrer" target="_blank" style="box-sizing: inherit; color: rgb(18, 100, 163);">the changelog</a>. Run <code data-stringify-type="code" class="c-mrkdwn__code" style="box-sizing: inherit; font-size: 12px; padding: 2px 3px 1px; color: rgb(224, 30, 90); background-color: rgba(29, 28, 29, 0.04); border: 1px solid rgba(29, 28, 29, 0.13); border-radius: 3px;">kapy sync --force</code> if you see conflicts. <img class="c-emoji__img" alt=":kapy-party:" title=":kapy-party:" src="https://emoji.slack-edge.com/T0SAMPLE00/kapy-party/5c8f1b2e3d4a6f70.png" data-stringify-emoji=":kapy-party:" style="box-sizing: inherit; width: 22px; height: 22px;" /></div><ul data-stringify-type="unordered-list" data-list-tree="true" class="p-rich_text_list p-rich_text_list__bullet" style="box-sizing: inherit; list-style-type: disc;"><li data-stringify-indent="0" data-stringify-border="0" style="box-sizing: inherit;">Faster sync</li><li data-stringify-indent="0" data-stringify-border="0" style="box-sizing: inherit;">New importer<ul data-stringify-type="unordered-list" data-list-tree="true" class="p-rich_text_list p-rich_text_list__bullet" style="list-style-type: circle;"><li data-stringify-indent="1" data-stringify-border="0">Word</li><li data-stringify-indent="1" data-stringify-border="0">Excel</li></ul></li></ul><div class="p-rich_text_section"></div><blockquote data-stringify-type="quote" class="c-mrkdwn__quote" style="box-sizing: inherit; position: relative; padding-left: 12px; margin: 4px 0px;"><div class="p-rich_text_section">Ship it on Friday.</div></blockquote><pre data-stringify-type="pre" class="c-mrkdwn__pre" style="box-sizing: inherit; margin: 4px 0px; padding: 8px; background: rgba(29, 28, 29, 0.04); border: 1px solid rgba(29, 28, 29, 0.13); border-radius: 4px; font-size: 12px; white-space: pre-wrap;">const total = items.reduce((a, b) => a + b.price, 0);\nconsole.log(total);</pre></div>`;
const slackPlain = 'Release 2.4 is out 🎉 thanks to everyone and old plan, details in the changelog. Run kapy sync --force if you see conflicts. :kapy-party:\n• Faster sync\n• New importer\n    ◦ Word\n    ◦ Excel\n\n> Ship it on Friday.\n\nconst total = items.reduce((a, b) => a + b.price, 0);\nconsole.log(total);';
writeFixture({
  source: 'slack', case: 'message-formatting-emoji-code', app: 'Slack desktop 4.x for macOS (synthesized)', platform: 'macos',
  how: 'Synthesized: one Slack message (bold, italic, strikethrough, link, inline code, a standard :tada: emoji, a workspace custom emoji, a nested bullet list, a quote and a code block) selected and copied in Slack desktop.',
  notes: 'SYNTHESIZED from the markup Slack renders (c-mrkdwn__* classes, data-stringify-* attributes). Key traps: custom emoji arrive as <img alt=":kapy-party:" data-stringify-emoji=":kapy-party:"> (alt is the colon-name), standard emoji as <span class="c-emoji"><img alt=":tada:"> (the plain text has the Unicode glyph), code block is <pre class="c-mrkdwn__pre">, quote is <blockquote class="c-mrkdwn__quote">, lists are <ul class="p-rich_text_list p-rich_text_list__bullet">. Slack desktop is Electron, so HTML carries Chrome\'s <meta charset=\'utf-8\'> prefix. Slack also writes a private "slack/texty" entry (JSON of rich-text ops) into org.chromium.web-custom-data that is not reproduced. Unsure about the exact plain-text rendering of nested bullets (this uses • and ◦ with indentation).',
  items: [[
    ['public.html', slackHtml],
    ['public.utf8-plain-text', slackPlain],
  ]],
});

// ---------------- Gmail (web, copied in Chrome: Chrome-serialized selection + source-url) ----------------
const gmailHtml = META + `<div dir="ltr" style="color: rgb(34, 34, 34); font-family: Arial, Helvetica, sans-serif; font-size: small; font-style: normal; font-variant-ligatures: normal; font-variant-caps: normal; font-weight: 400; letter-spacing: normal; orphans: 2; text-align: start; text-indent: 0px; text-transform: none; white-space: normal; widows: 2; word-spacing: 0px; background-color: rgb(255, 255, 255); text-decoration-thickness: initial; text-decoration-style: initial; text-decoration-color: initial;"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="border-collapse: collapse; background-color: rgb(244, 244, 244);"><tbody><tr><td align="center" style="padding: 20px 0px;"><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" style="border-collapse: collapse; background-color: rgb(255, 255, 255);"><tbody><tr><td style="padding: 24px; font-family: Arial, sans-serif; font-size: 14px; line-height: 20px;"><h1 style="margin: 0px 0px 12px; font-size: 20px;">Your October summary</h1><p style="margin: 0px 0px 12px;">Hi Sam, here is where things stand. <a href="https://www.google.com/url?q=https://example.com/report&amp;source=gmail&amp;ust=1760000000000000&amp;usg=AOvVaw0abc" target="_blank" style="color: rgb(17, 85, 204);">Open the full report</a>.</p><table cellspacing="0" cellpadding="6" border="1" style="border-collapse: collapse; border: 1px solid rgb(204, 204, 204); width: 100%;"><thead><tr style="background-color: rgb(240, 240, 240);"><th align="left" style="border: 1px solid rgb(204, 204, 204);">Metric</th><th align="right" style="border: 1px solid rgb(204, 204, 204);">Oct</th><th align="right" style="border: 1px solid rgb(204, 204, 204);">Sep</th></tr></thead><tbody><tr><td style="border: 1px solid rgb(204, 204, 204);">Notes created</td><td align="right" style="border: 1px solid rgb(204, 204, 204);">1,204</td><td align="right" style="border: 1px solid rgb(204, 204, 204);">987</td></tr><tr><td style="border: 1px solid rgb(204, 204, 204);">Synced devices</td><td align="right" style="border: 1px solid rgb(204, 204, 204);">3</td><td align="right" style="border: 1px solid rgb(204, 204, 204);">2</td></tr></tbody></table></td></tr></tbody></table></td></tr></tbody></table><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, 3 Nov 2025 at 09:14, Asha Rao &lt;<a href="mailto:asha@example.com" target="_blank">asha@example.com</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin: 0px 0px 0px 0.8ex; border-left: 1px solid rgb(204, 204, 204); padding-left: 1ex;"><div dir="ltr">Can you send the numbers?<div><br></div><div>Thanks!</div></div></blockquote></div><div><br clear="all"></div><div><span class="gmail_signature_prefix">-- </span><br></div><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature"><div dir="ltr"><div>Sam Sample<br>Product, Example Co.<br><a href="https://example.com" target="_blank">example.com</a></div></div></div></div>`;
writeFixture({
  source: 'gmail', case: 'html-email-layout-tables-quote-signature', app: 'Chrome (Gmail web UI) (synthesized)', platform: 'macos',
  how: 'Synthesized: selecting an HTML email in the Gmail web UI in Chrome (layout tables, a data table, a link, a quoted reply and the signature) and copying with Cmd+C.',
  notes: 'SYNTHESIZED in the shape of a real Chrome selection copy of Gmail (computed styles inlined on the root, <meta charset=\'utf-8\'> prefix, org.chromium.source-url = the Gmail URL). Traps: layout tables with role="presentation" that are not data tables, a real data table with <thead>/<th>, links rewritten through https://www.google.com/url?q=..., <div class="gmail_quote"> + <blockquote class="gmail_quote">, the signature as <div class="gmail_signature" data-smartmail="gmail_signature"> preceded by "-- ", <br clear="all"> spacers.',
  items: [[
    ['public.html', gmailHtml],
    ['public.utf8-plain-text', 'Your October summary\n\nHi Sam, here is where things stand. Open the full report.\n\nMetric\tOct\tSep\nNotes created\t1,204\t987\nSynced devices\t3\t2\n\nOn Mon, 3 Nov 2025 at 09:14, Asha Rao <asha@example.com> wrote:\n\nCan you send the numbers?\n\nThanks!\n\n\n-- \nSam Sample\nProduct, Example Co.\nexample.com'],
    ['org.chromium.source-url', 'https://mail.google.com/mail/u/0/#inbox/FMfcgzQXKWgSampleMessageId'],
  ]],
});

// ---------------- VS Code ----------------
const span = (c, t) => `<span style="color: ${c};">${t}</span>`;
const line = (inner) => `<div>${inner}</div>`;
const BR = '<div><br></div>';
const pyLines = [
  line(span('#c586c0', 'from') + span('#cccccc', ' dataclasses ') + span('#c586c0', 'import') + span('#cccccc', ' dataclass')),
  BR,
  line(span('#dcdcaa', '@dataclass')),
  line(span('#569cd6', 'class') + span('#cccccc', ' ') + span('#4ec9b0', 'Note') + span('#cccccc', ':')),
  line(span('#cccccc', '    title: ') + span('#4ec9b0', 'str')),
  line(span('#cccccc', '    pinned: ') + span('#4ec9b0', 'bool') + span('#cccccc', ' = ') + span('#569cd6', 'False')),
  BR,
  line(span('#569cd6', 'def') + span('#cccccc', ' ') + span('#dcdcaa', 'summary') + span('#cccccc', '(note: ') + span('#4ec9b0', 'Note') + span('#cccccc', ') -> ') + span('#4ec9b0', 'str') + span('#cccccc', ':')),
  line(span('#cccccc', '    ') + span('#c586c0', 'return') + span('#cccccc', ' ') + span('#569cd6', 'f') + span('#ce9178', '"{note.title}: {') + span('#ce9178', "'pinned'") + span('#cccccc', ' ') + span('#c586c0', 'if') + span('#cccccc', ' note.pinned ') + span('#c586c0', 'else') + span('#cccccc', ' ') + span('#ce9178', "'normal'") + span('#ce9178', '}"')),
];
const wrapVs = (lines) => META + `<div style="color: #cccccc;background-color: #1f1f1f;font-family: Menlo, Monaco, 'Courier New', monospace;font-weight: normal;font-size: 12px;line-height: 18px;white-space: pre;">` + lines.join('') + '</div>';
const pyPlain = 'from dataclasses import dataclass\n\n@dataclass\nclass Note:\n    title: str\n    pinned: bool = False\n\ndef summary(note: Note) -> str:\n    return f"{note.title}: {\'pinned\' if note.pinned else \'normal\'}"';
const vsEntries = (mode, text) => [['vscode-editor-data', JSON.stringify({ version: 1, isFromEmptySelection: false, multicursorText: null, mode })]];
writeFixture({
  source: 'vscode', case: 'python-selection', app: 'Visual Studio Code 1.9x for macOS (synthesized)', platform: 'macos',
  how: 'Synthesized: selecting a Python dataclass in VS Code (Dark Modern theme) and pressing Cmd+C.',
  notes: 'SYNTHESIZED. VS Code is Electron and sets its data in the copy event through DataTransfer, so on the macOS pasteboard Chromium stores the custom "vscode-editor-data" JSON inside the pickled org.chromium.web-custom-data entry (included here, real binary pickle layout: uint32 size, uint32 count, then UTF-16 type/data string pairs). The same JSON is also stored as a separate "vscode-editor-data" representation so tests can read it directly; a real macOS pasteboard would NOT have that top-level type. HTML is a <div> with the editor font and one <div> per line, tokens as <span style="color:#rrggbb;">, blank lines as <div><br></div>, plus Chrome\'s <meta charset=\'utf-8\'> prefix; colors depend on the active theme. Note "mode" tells you the language of the copied text; isFromEmptySelection is true when a line was copied with no selection.',
  items: [[
    ['public.html', wrapVs(pyLines)],
    ['public.utf8-plain-text', pyPlain],
    ['org.chromium.web-custom-data', webCustomData(vsEntries('python'))],
    ['vscode-editor-data', JSON.stringify({ version: 1, isFromEmptySelection: false, multicursorText: null, mode: 'python' })],
  ]],
});

const tsLines = [
  line(span('#569cd6', 'export') + span('#cccccc', ' ') + span('#569cd6', 'async') + span('#cccccc', ' ') + span('#569cd6', 'function') + span('#cccccc', ' ') + span('#dcdcaa', 'loadNotes') + span('#cccccc', '(') + span('#9cdcfe', 'userId') + span('#cccccc', ': ') + span('#4ec9b0', 'string') + span('#cccccc', '): ') + span('#4ec9b0', 'Promise') + span('#cccccc', '<') + span('#4ec9b0', 'Note') + span('#cccccc', '[]> {')),
  line(span('#cccccc', '  ') + span('#569cd6', 'const') + span('#cccccc', ' ') + span('#4fc1ff', 'res') + span('#cccccc', ' = ') + span('#c586c0', 'await') + span('#cccccc', ' ') + span('#dcdcaa', 'fetch') + span('#cccccc', '(') + span('#ce9178', '`/api/users/${') + span('#9cdcfe', 'userId') + span('#ce9178', '}/notes`') + span('#cccccc', ');')),
  line(span('#cccccc', '  ') + span('#c586c0', 'if') + span('#cccccc', ' (!') + span('#4fc1ff', 'res') + span('#cccccc', '.') + span('#9cdcfe', 'ok') + span('#cccccc', ') ') + span('#c586c0', 'throw') + span('#cccccc', ' ') + span('#569cd6', 'new') + span('#cccccc', ' ') + span('#4ec9b0', 'Error') + span('#cccccc', '(') + span('#ce9178', '"failed"') + span('#cccccc', ');')),
  line(span('#cccccc', '  ') + span('#c586c0', 'return') + span('#cccccc', ' ') + span('#4fc1ff', 'res') + span('#cccccc', '.') + span('#dcdcaa', 'json') + span('#cccccc', '();')),
  line(span('#cccccc', '}')),
];
writeFixture({
  source: 'vscode', case: 'typescript-selection', app: 'Visual Studio Code 1.9x for macOS (synthesized)', platform: 'macos',
  how: 'Synthesized: Selecting a TypeScript function (several lines) in VS Code and pressing Cmd+C.',
  notes: 'SYNTHESIZED. Same structure as the Python fixture with mode "typescript". When VS Code copies a line without a selection it sets isFromEmptySelection to true; this fixture is a multi-line selection.',
  items: [[
    ['public.html', wrapVs(tsLines)],
    ['public.utf8-plain-text', 'export async function loadNotes(userId: string): Promise<Note[]> {\n  const res = await fetch(`/api/users/${userId}/notes`);\n  if (!res.ok) throw new Error("failed");\n  return res.json();\n}'],
    ['org.chromium.web-custom-data', webCustomData(vsEntries('typescript'))],
    ['vscode-editor-data', JSON.stringify({ version: 1, isFromEmptySelection: false, multicursorText: null, mode: 'typescript' })],
  ]],
});

// ---------------- ChatGPT / Claude desktop apps: GUESSES ----------------
const mdAnswer = [
  '## Compound interest',
  '',
  'The future value after **n** years is:',
  '',
  '$$FV = P\\left(1 + \\frac{r}{m}\\right)^{mn}$$',
  '',
  'Where:',
  '',
  '- `P` is the principal',
  '- `r` is the annual rate',
  '  - as a decimal, e.g. `0.05`',
  '- `m` is compounding periods per year',
  '',
  '| Years | Balance |',
  '| --- | --- |',
  '| 1 | 1,050.00 |',
  '| 5 | 1,276.28 |',
  '',
  '```python',
  'def fv(p, r, m, n):',
  '    return p * (1 + r / m) ** (m * n)',
  '```',
  '',
].join('\n');
writeFixture({
  source: 'chatgpt', case: 'mac-app-copy-button-guess', app: 'ChatGPT for macOS (synthesized, GUESS)', platform: 'macos',
  how: 'Synthesized GUESS: the copy button under an answer in the ChatGPT Mac app.',
  notes: 'GUESS, not captured. As far as I know the ChatGPT desktop app\'s copy button writes only the markdown source as plain text (math as $$...$$ or \\[ \\] depending on the answer; this uses $$). Contrast with the web copy button captured under chatgpt/*-copy-button, which also writes text/html. Replace with a real capture via capture_macos.swift.',
  items: [[['public.utf8-plain-text', mdAnswer]]],
});
writeFixture({
  source: 'claude', case: 'mac-app-copy-button-guess', app: 'Claude for macOS (synthesized, GUESS)', platform: 'macos',
  how: 'Synthesized GUESS: the copy button under a reply in the Claude Mac app.',
  notes: 'GUESS, not captured (claude.ai is behind a Cloudflare challenge for headless Chrome, so there is no web capture of Claude either). I believe the desktop app copies the reply as markdown plain text, possibly with a text/html twin; only plain text is included. Math is written as $...$ / $$...$$ in the guess. Replace with a real capture.',
  items: [[['public.utf8-plain-text', mdAnswer.replace('## Compound interest', '# Compound interest')]]],
});

// ---------------- Finder: two files copied ----------------
const noteTxt = 'Sample notes file used by the Finder fixture.\nLine two.\n';
const imgPng = samplePng(160, 100, 2);
const paths = ['/Users/sample/Desktop/kapy-sample-notes.txt', '/Users/sample/Desktop/kapy-sample-chart.png'];
const filenamesPlist = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<array>\n\t<string>' + paths[0] + '</string>\n\t<string>' + paths[1] + '</string>\n</array>\n</plist>\n';
writeFixture({
  source: 'finder', case: 'two-files-copied', app: 'Finder (macOS 15) (synthesized)', platform: 'macos',
  how: 'Synthesized: selecting kapy-sample-notes.txt and kapy-sample-chart.png on the Desktop in Finder and pressing Cmd+C.',
  notes: 'SYNTHESIZED. Finder writes one pasteboard item per file, each with public.file-url (percent-encoded file:// URL, no trailing slash for files) and public.utf8-plain-text (the file NAME only, not the path); the legacy NSFilenamesPboardType property list (array of absolute paths) is exposed on the first item. The two files live beside this fixture.json as sidecars named like the basenames, so a test can resolve a file URL by basename. Real Finder also adds com.apple.finder.node and icon types (not reproduced) and the paths are of course the copier\'s own.',
  items: [
    [['public.file-url', 'file://' + paths[0]], ['public.utf8-plain-text', 'kapy-sample-notes.txt'], ['NSFilenamesPboardType', filenamesPlist]],
    [['public.file-url', 'file://' + paths[1]], ['public.utf8-plain-text', 'kapy-sample-chart.png']],
  ],
  sidecars: { 'kapy-sample-notes.txt': Buffer.from(noteTxt), 'kapy-sample-chart.png': imgPng },
});
