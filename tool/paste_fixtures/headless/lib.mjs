import puppeteer from 'puppeteer-core';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const SCRATCH = process.env.PASTE_FIXTURE_SCRATCH || path.join(os.homedir(), '.capy/work/paste-fixtures');
export const CHROME = process.env.CHROME_HEADLESS_SHELL || execSync('ls -d ' + SCRATCH + '/chrome-headless-shell/*/chrome-headless-shell-mac-arm64/chrome-headless-shell').toString().trim();
export { SCRATCH };
export const FIXROOT = process.env.FIXROOT;

export function changeCount() {
  return parseInt(execSync(`osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSPasteboard.generalPasteboard.changeCount'`).toString().trim(), 10);
}

export async function launch() {
  return puppeteer.launch({ executablePath: CHROME, headless: 'shell', args: ['--no-sandbox','--window-size=1280,1000','--lang=en-US'], defaultViewport: {width:1280,height:1000} });
}

export async function openPage(browser, url, { waitUntil = 'networkidle2', timeout = 60000, ua } = {}) {
  const origin = new URL(url).origin;
  const ctx = browser.defaultBrowserContext();
  await ctx.overridePermissions(origin, ['clipboard-read','clipboard-write','clipboard-sanitized-write']).catch(()=>{});
  const page = await browser.newPage();
  if (ua) await page.setUserAgent(ua);
  await page.goto(url, { waitUntil, timeout }).catch(e => console.error('goto:', e.message));
  return page;
}

// Reads every item/type the in-page clipboard holds, raw (unsanitized html).
export async function readClipboard(page) {
  return page.evaluate(async () => {
    const out = [];
    const items = await navigator.clipboard.read({ unsanitized: ['text/html'] });
    for (const it of items) {
      const reps = [];
      for (const t of it.types) {
        const b = await it.getType(t);
        if (t.startsWith('text/') || t.includes('json')) reps.push({ type: t, text: await b.text() });
        else { const buf = new Uint8Array(await b.arrayBuffer()); let s=''; for (let i=0;i<buf.length;i+=0x8000) s+=String.fromCharCode.apply(null, buf.subarray(i,i+0x8000)); reps.push({ type: t, b64: btoa(s) }); }
      }
      out.push(reps);
    }
    return out;
  });
}

// Chrome macOS pasteboard type for each web-facing MIME type.
const UTI = { 'text/html': 'public.html', 'text/plain': 'public.utf8-plain-text', 'image/png': 'public.png', 'text/uri-list': 'public.url' };
const EXT = { 'public.html': 'html', 'public.utf8-plain-text': 'txt', 'public.png': 'png', 'org.chromium.source-url': 'txt', 'public.url':'txt' };

export function writeFixture({ source, case: kase, app, platform = 'macos', capture = 'real', how, url, notes, clip, sourceUrl, extraReps = [] }) {
  const dir = path.join(FIXROOT, source, kase);
  fs.mkdirSync(dir, { recursive: true });
  const reps = [];
  const add = (type, buf) => {
    const ext = EXT[type] || 'bin';
    const file = type + '.' + ext;
    fs.writeFileSync(path.join(dir, file), buf);
    reps.push({ type, file });
  };
  for (const r of clip) {
    for (const rep of r) {
      const uti = UTI[rep.type];
      if (!uti) { console.error('unmapped type', rep.type); continue; }
      if (rep.text !== undefined) {
        // Chrome on macOS (ClipboardMac::WriteHTML) prefixes the markup with a charset meta tag.
        const text = uti === 'public.html' ? "<meta charset='utf-8'>" + rep.text : rep.text;
        add(uti, Buffer.from(text, 'utf8'));
      } else add(uti, Buffer.from(rep.b64, 'base64'));
    }
  }
  if (sourceUrl) add('org.chromium.source-url', Buffer.from(sourceUrl, 'utf8'));
  for (const e of extraReps) add(e.type, e.buf);
  const fx = { source, case: kase, app, platform, capture, how, ...(url ? { url } : {}), notes, items: [{ representations: reps }] };
  fs.writeFileSync(path.join(dir, 'fixture.json'), JSON.stringify(fx, null, 2) + '\n');
  return { dir, reps, bytes: reps.map(r => fs.statSync(path.join(dir, r.file)).size) };
}
