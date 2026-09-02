#!/usr/bin/env node

import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import sharp from '../../website/node_modules/sharp/dist/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const INPUT_ROOT = join(REPO_ROOT, 'design', 'mascot', 'concepts', 'style-board');
const OUTPUT = join(REPO_ROOT, 'design', 'mascot', 'concepts', 'kapy-style-board-12.png');

const files = Array.from(
  { length: 12 },
  (_, index) => `${String(index + 1).padStart(2, '0')}.png`,
);

const columns = 4;
const rows = 3;
const cell = 600;
const gutter = 12;
const width = columns * cell;
const height = rows * cell;

mkdirSync(dirname(OUTPUT), { recursive: true });

const layers = [];
for (const [index, file] of files.entries()) {
  const column = index % columns;
  const row = Math.floor(index / columns);
  const tile = await sharp(join(INPUT_ROOT, file))
    .resize(cell - gutter * 2, cell - gutter * 2, {
      fit: 'cover',
      position: 'centre',
    })
    .png()
    .toBuffer();
  layers.push({
    input: tile,
    left: column * cell + gutter,
    top: row * cell + gutter,
  });
}

const labels = files.map((_, index) => {
  const column = index % columns;
  const row = Math.floor(index / columns);
  const cx = column * cell + 58;
  const cy = row * cell + 58;
  return `<circle cx="${cx}" cy="${cy}" r="34" fill="#182433" />
    <text x="${cx}" y="${cy + 1}" text-anchor="middle" dominant-baseline="middle"
      fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="30"
      font-weight="700">${index + 1}</text>`;
}).join('\n');

const labelOverlay = Buffer.from(`
  <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
    ${labels}
  </svg>
`);

await sharp({
  create: {
    width,
    height,
    channels: 3,
    background: '#eee8dd',
  },
})
  .composite([...layers, { input: labelOverlay, left: 0, top: 0 }])
  .png({ compressionLevel: 9, adaptiveFiltering: true, palette: false })
  .toFile(OUTPUT);

process.stdout.write(`${OUTPUT}\n`);
