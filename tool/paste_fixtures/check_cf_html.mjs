// Verifies the CF_HTML offsets of every "HTML Format" fixture: node tool/paste_fixtures/check_cf_html.mjs [root]
import fs from 'node:fs';
import path from 'node:path';
const root = process.argv[2] || 'test/fixtures/paste';
let bad = 0, n = 0;
for (const f of fs.readdirSync(root, { recursive: true })) {
  if (!f.endsWith('fixture.json')) continue;
  const dir = path.join(root, path.dirname(f));
  const fx = JSON.parse(fs.readFileSync(path.join(root, f), 'utf8'));
  for (const item of fx.items) for (const r of item.representations) {
    if (r.type !== 'HTML Format') continue;
    n++;
    const buf = fs.readFileSync(path.join(dir, r.file));
    const head = buf.subarray(0, 400).toString('latin1');
    const get = (k) => parseInt(new RegExp(k + ':(\\d+)').exec(head)[1], 10);
    const [sh, eh, sf, ef] = ['StartHTML', 'EndHTML', 'StartFragment', 'EndFragment'].map(get);
    const ok = eh === buf.length && buf.subarray(sf - 20, sf).toString().includes('<!--StartFragment') && buf.subarray(ef, ef + 20).toString().startsWith('<!--EndFragment') && buf.subarray(sh, sh + 5).toString().toLowerCase().startsWith('<html');
    console.log(ok ? 'ok ' : 'BAD', path.join(path.dirname(f)), { sh, eh, sf, ef, len: buf.length });
    if (!ok) bad++;
  }
}
console.log(n + ' HTML Format payloads checked, ' + bad + ' bad');
process.exit(bad ? 1 : 0);
