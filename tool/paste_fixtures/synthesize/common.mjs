// Shared helpers for the synthesized (non-capturable) fixtures. Node built-ins only.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

export const ROOT = process.env.FIXROOT || path.resolve(process.cwd(), 'test/fixtures/paste');

const EXT = {
  'public.html': 'html', 'public.utf8-plain-text': 'txt', 'public.rtf': 'rtf', 'public.png': 'png', 'public.tiff': 'tiff',
  'public.jpeg': 'jpg', 'public.file-url': 'txt', 'org.chromium.source-url': 'txt', 'vscode-editor-data': 'json',
  'org.chromium.web-custom-data': 'bin', 'com.apple.flat-rtfd': 'rtfd', 'com.apple.webarchive': 'webarchive',
  'HTML Format': 'html', 'CF_UNICODETEXT': 'txt', 'Rich Text Format': 'rtf', 'PNG': 'png', 'Csv': 'csv',
  'NSFilenamesPboardType': 'plist', 'text/html': 'html', 'text/plain': 'txt',
};

// items: [[ [type, Buffer|string], ... ], ...]; sidecars: { filename: Buffer } stored beside the representations (not clipboard types).
export function writeFixture({ source, case: kase, app, platform, how, url, notes, items, sidecars = {} }) {
  const dir = path.join(ROOT, source, kase);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const jsonItems = items.map((reps, i) => ({
    representations: reps.map(([type, data]) => {
      const file = (i ? 'item' + i + '.' : '') + type.replace(/[^A-Za-z0-9._-]/g, '_') + '.' + (EXT[type] || 'bin');
      fs.writeFileSync(path.join(dir, file), typeof data === 'string' ? Buffer.from(data, 'utf8') : data);
      return { type, file };
    }),
  }));
  for (const [name, buf] of Object.entries(sidecars)) fs.writeFileSync(path.join(dir, name), buf);
  const fx = { source, case: kase, app, platform, capture: 'synthesized', how, ...(url ? { url } : {}), notes, items: jsonItems };
  if (Object.keys(sidecars).length) fx.sidecars = Object.keys(sidecars);
  fs.writeFileSync(path.join(dir, 'fixture.json'), JSON.stringify(fx, null, 2) + '\n');
  console.log('wrote', source + '/' + kase, jsonItems.flatMap(i => i.representations).map(r => r.type).join(', '));
}

// CF_HTML: Version/StartHTML/EndHTML/StartFragment/EndFragment with 10-digit zero padded byte offsets, CRLF header.
export function cfHtml(html, { sourceUrl, version = '1.0' } = {}) {
  const startMarker = '<!--StartFragment-->', endMarker = '<!--EndFragment-->';
  const mk = (sh, eh, sf, ef) => 'Version:' + version + '\r\nStartHTML:' + String(sh).padStart(10, '0') + '\r\nEndHTML:' + String(eh).padStart(10, '0') +
    '\r\nStartFragment:' + String(sf).padStart(10, '0') + '\r\nEndFragment:' + String(ef).padStart(10, '0') + (sourceUrl ? '\r\nSourceURL:' + sourceUrl : '') + '\r\n';
  const len = (s) => Buffer.byteLength(s, 'utf8');
  const hdrLen = len(mk(0, 0, 0, 0));
  const si = html.indexOf(startMarker), ei = html.indexOf(endMarker);
  if (si < 0 || ei < 0) throw new Error('html needs StartFragment/EndFragment markers');
  const startHtml = hdrLen;
  const startFragment = startHtml + len(html.slice(0, si + startMarker.length));
  const endFragment = startHtml + len(html.slice(0, ei));
  const endHtml = startHtml + len(html);
  return mk(startHtml, endHtml, startFragment, endFragment) + html;
}

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};

// A small RGBA PNG: white card, coloured bars (a stand-in chart / screenshot).
export function samplePng(w = 240, h = 140, seed = 0) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  const bars = [0.35, 0.6, 0.45, 0.85, 0.7].map((v, i) => (v + seed * 0.05 * (i % 2)) % 1);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      let r = 250, g = 250, b = 252;
      if (y < 3 || y >= h - 3 || x < 3 || x >= w - 3) { r = 200; g = 205; b = 215; }
      const bi = Math.floor((x - 20) / ((w - 40) / bars.length));
      if (bi >= 0 && bi < bars.length && (x - 20) % Math.floor((w - 40) / bars.length) < Math.floor((w - 40) / bars.length) - 8) {
        const top = Math.floor(h - 12 - bars[bi] * (h - 30));
        if (y >= top && y < h - 12) { r = 60 + bi * 30; g = 110 + bi * 15; b = 220 - bi * 20; }
      }
      const o = y * (w * 4 + 1) + 1 + x * 4;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b; raw[o + 3] = 255;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

// Chromium's pickle used for org.chromium.web-custom-data: uint32 payload size, uint32 entry count,
// then per entry two string16 (uint32 char count + UTF-16LE data padded to 4 bytes): MIME type, then data.
export function webCustomData(entries) {
  const parts = [];
  const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b; };
  const s16 = (s) => { const d = Buffer.from(s, 'utf16le'); const pad = (4 - (d.length % 4)) % 4; return Buffer.concat([u32(s.length), d, Buffer.alloc(pad)]); };
  parts.push(u32(entries.length));
  for (const [k, v] of Object.entries(entries.length ? Object.fromEntries(entries) : {})) { parts.push(s16(k), s16(v)); }
  const payload = Buffer.concat(parts);
  return Buffer.concat([u32(payload.length), payload]);
}
