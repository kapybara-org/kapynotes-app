// Google Docs / Sheets editor capture over CDP key events (view-only public links).
// node gcapture.mjs <docs|sheets> <url> <source> <case> <mode: all|lines:N|none> [--cell A1:D5]
import {launch, openPage, readClipboard, writeFixture, changeCount} from './lib.mjs';
const [kind, url, source, kase, mode] = process.argv.slice(2, 7);
const c0 = changeCount();
const b = await launch();
const p = await openPage(b, url, {waitUntil:'domcontentloaded', timeout:60000});
await new Promise(r=>setTimeout(r,12000));
const title = await p.title();
const cdp = await p.createCDPSession();
const key = async (key, code, vk, commands, modifiers = 0) => {
  await cdp.send('Input.dispatchKeyEvent', {type:'keyDown', modifiers, key, code, windowsVirtualKeyCode: vk, commands});
  await cdp.send('Input.dispatchKeyEvent', {type:'keyUp', modifiers, key, code, windowsVirtualKeyCode: vk});
  await new Promise(r=>setTimeout(r,150));
};
await p.mouse.click(640, 500);
await new Promise(r=>setTimeout(r,800));
if (mode === 'all') await key('a','KeyA',65,['selectAll'],4);
else if (mode.startsWith('lines:')) {
  await key('Home','Home',36,['moveToBeginningOfDocument'],4);
  const n = parseInt(mode.slice(6), 10);
  for (let i = 0; i < n; i++) await key('ArrowDown','ArrowDown',40,['moveDownAndModifySelection'],8);
} else if (mode.startsWith('cells:')) {
  // sheets: click A1-ish then shift-click via arrow keys: rows:cols
  const [rows, cols] = mode.slice(6).split('x').map(Number);
  await key('Home','Home',36,['moveToBeginningOfDocument'],4);
  for (let i = 0; i < rows - 1; i++) await key('ArrowDown','ArrowDown',40,['moveDownAndModifySelection'],8);
  for (let i = 0; i < cols - 1; i++) await key('ArrowRight','ArrowRight',39,['moveRightAndModifySelection'],8);
}
await key('c','KeyC',67,['copy'],4);
await new Promise(r=>setTimeout(r,1500));
const clip = await readClipboard(p);
console.log(title, clip.map(i=>i.map(r=>r.type+':'+(r.text??r.b64).length).join(' ')).join(' | '));
if (!clip.length || !clip[0].length) { console.log('empty'); }
else if (process.env.WRITE === '1') {
  const res = writeFixture({ source, case: kase, app: (await b.version()).replace('HeadlessChrome','Chrome') + ' (chrome-headless-shell)', platform:'macos', capture:'real',
    how: process.env.HOW, url, notes: process.env.NOTES, clip, sourceUrl: url });
  console.log('wrote', res.dir, res.bytes);
}
await b.close();
const c1 = changeCount();
console.log('changeCount', c0, c1);
if (c0 !== c1) process.exit(9);
