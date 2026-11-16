// Validates every fixture and (with --index) prints a markdown table of them.
//   node tool/paste_fixtures/validate.mjs [fixtureRoot] [--index]
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
const root = args.find(a => !a.startsWith('--')) || 'test/fixtures/paste';
const rows = [];
let errors = 0;
const fail = (dir, msg) => { console.error('FAIL', dir, msg); errors++; };
for (const f of fs.readdirSync(root, { recursive: true }).filter(f => f.endsWith('fixture.json')).sort()) {
  const dir = path.dirname(f);
  const fx = JSON.parse(fs.readFileSync(path.join(root, f), 'utf8'));
  for (const k of ['source', 'case', 'app', 'platform', 'capture', 'how', 'notes', 'items']) if (fx[k] === undefined || fx[k] === '') fail(dir, 'missing ' + k);
  if (dir !== fx.source + '/' + fx.case) fail(dir, 'directory does not match source/case');
  if (!['macos', 'windows', 'android', 'ios'].includes(fx.platform)) fail(dir, 'bad platform');
  if (!['real', 'synthesized'].includes(fx.capture)) fail(dir, 'bad capture');
  if (/TODO/.test(JSON.stringify(fx))) fail(dir, 'TODO left in fixture.json');
  const referenced = new Set(['fixture.json', 'macos-snapshot.json', 'expected.md', 'expected.plain.txt', ...(fx.sidecars || [])]);
  const types = [];
  fx.items.forEach((item, i) => {
    if (!item.representations.length) fail(dir, 'item ' + i + ' has no representations');
    for (const r of item.representations) {
      if (!r.type || !r.file) fail(dir, 'representation without type/file');
      else if (!fs.existsSync(path.join(root, dir, r.file))) fail(dir, 'missing file ' + r.file);
      else if (fs.statSync(path.join(root, dir, r.file)).size === 0) fail(dir, 'empty file ' + r.file);
      referenced.add(r.file);
      if (!types.includes(r.type)) types.push(r.type);
    }
  });
  for (const file of fs.readdirSync(path.join(root, dir))) if (!referenced.has(file)) fail(dir, 'unreferenced file ' + file);
  const kb = Math.round(fs.readdirSync(path.join(root, dir)).reduce((a, n) => a + fs.statSync(path.join(root, dir, n)).size, 0) / 1024);
  rows.push({ dir, capture: fx.capture, platform: fx.platform, types, items: fx.items.length, kb });
}
if (args.includes('--index')) {
  console.log('| fixture | capture | platform | items | representations | size |');
  console.log('| --- | --- | --- | --- | --- | --- |');
  for (const r of rows) console.log('| ' + r.dir + ' | ' + r.capture + ' | ' + r.platform + ' | ' + r.items + ' | ' + r.types.join(', ') + ' | ' + (r.kb >= 1024 ? (r.kb / 1024).toFixed(1) + ' MB' : r.kb + ' KB') + ' |');
}
console.error(rows.length + ' fixtures, ' + errors + ' errors');
process.exit(errors ? 1 : 0);
