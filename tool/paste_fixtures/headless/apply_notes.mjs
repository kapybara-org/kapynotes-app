// Rewrites the "notes" field of every captured fixture.json from notes.json (keyed "<source>/<case>").
// node tool/paste_fixtures/headless/apply_notes.mjs [fixtureRoot]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = process.argv[2] || 'test/fixtures/paste';
const notes = JSON.parse(fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'notes.json'), 'utf8'));
let n = 0;
for (const [key, text] of Object.entries(notes)) {
  const f = path.join(root, key, 'fixture.json');
  if (!fs.existsSync(f)) { console.log('missing', key); continue; }
  const fx = JSON.parse(fs.readFileSync(f, 'utf8'));
  fx.notes = text;
  fs.writeFileSync(f, JSON.stringify(fx, null, 2) + '\n');
  n++;
}
console.log('updated notes of', n, 'fixtures');
