// Usage (from this directory, after npm install): FIXROOT=<repo>/test/fixtures/paste node capture.mjs specs/<file>.mjs [caseFilter]
// Aborts with exit code 9 the moment NSPasteboard.general.changeCount differs between the start and end of a fixture.
import { launch, openPage, readClipboard, writeFixture, changeCount, SCRATCH } from './lib.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const notes = JSON.parse(fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'notes.json'), 'utf8'));

const specFile = process.argv[2];
const filter = process.argv[3];
const specs = (await import(new URL(specFile, 'file://' + process.cwd() + '/').href)).default;
const log = [];
let browser = await launch();
const chrome = (await browser.version()).replace('HeadlessChrome', 'Chrome');

for (const s of specs) {
  if (filter && !s.case.includes(filter)) continue;
  const before = changeCount();
  let page;
  await browser.close().catch(() => {});
  browser = await launch();
  try {
    page = await openPage(browser, s.url, s.open || {});
    if (s.prepare) await s.prepare(page);
    if (s.selectPage) {
      const ok = await s.selectPage(page);
      if (!ok) throw new Error('selectPage returned falsy');
      await page.evaluate(() => document.execCommand('copy'));
    }
    if (s.select) {
      const ok = await page.evaluate(s.select, s.selectArg);
      if (!ok) throw new Error('selection helper returned falsy: ' + JSON.stringify(ok));
      await page.evaluate(() => document.execCommand('copy'));
    }
    if (s.action) {
      await s.action(page);
      await new Promise(r => setTimeout(r, s.clickWait ?? 1500));
    }
    if (s.click) {
      await page.click(s.click);
      await new Promise(r => setTimeout(r, s.clickWait ?? 1500));
    }
    const clip = await readClipboard(page);
    if (!clip.length || !clip[0].length) throw new Error('clipboard empty after action');
    const text = (clip[0] || []).map(r => r.type + ':' + ((r.text ?? r.b64).length)).join(' ');
    const res = writeFixture({
      source: s.source, case: s.case, app: chrome + ' (chrome-headless-shell)', platform: 'macos', capture: 'real',
      how: s.how, url: s.pageUrl || page.url(), notes: notes[s.source + '/' + s.case] ?? s.notes,
      clip, sourceUrl: (s.click || s.action) ? undefined : (s.pageUrl || page.url()),
    });
    console.log('OK ', s.source + '/' + s.case, text);
  } catch (e) {
    console.log('ERR', s.source + '/' + s.case, e.message.split('\n')[0]);
  } finally {
    const after = changeCount();
    log.push({ case: s.source + '/' + s.case, before, after });
    if (before !== after) { console.log('!!! GENERAL PASTEBOARD CHANGED', before, after); await browser.close(); process.exit(9); }
    if (page) await page.close().catch(() => {});
  }
}
await browser.close();
fs.appendFileSync(path.join(SCRATCH, 'changecount.log'), new Date().toISOString() + ' ' + specFile + ' ' + JSON.stringify(log.map(l => [l.before, l.after])) + '\n');
