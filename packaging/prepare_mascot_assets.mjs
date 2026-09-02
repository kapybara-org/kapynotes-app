#!/usr/bin/env node

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import sharp from '../../website/node_modules/sharp/dist/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const PNG_ROOT = join(REPO_ROOT, 'design', 'mascot', 'final', 'png');
const WEB_ROOT = join(REPO_ROOT, 'website', 'public', 'mascot-v2');
const BOARD_PATH = join(
  REPO_ROOT,
  'design',
  'mascot',
  'final',
  'kapy-final-assets-board.png',
);
const MANIFEST_PATH = join(
  REPO_ROOT,
  'design',
  'mascot',
  'final',
  'manifest.json',
);

const assets = [
  { slug: 'kapy-welcome', label: 'Welcome' },
  { slug: 'kapy-hero-peek', label: 'Hero peek' },
  { slug: 'kapy-calculator', label: 'Calculator' },
  { slug: 'kapy-notes', label: 'Notes' },
  { slug: 'kapy-checklist', label: 'Checklist' },
  { slug: 'kapy-journal', label: 'Journal' },
  { slug: 'kapy-recipe', label: 'Recipe' },
  { slug: 'kapy-security', label: 'Privacy' },
];

mkdirSync(WEB_ROOT, { recursive: true });

const webWidth = 512;
const webHeight = 640;
const boardColumns = 4;
const boardCellWidth = 600;
const boardCellHeight = 700;
const boardWidth = boardColumns * boardCellWidth;
const boardHeight = Math.ceil(assets.length / boardColumns) * boardCellHeight;
const boardLayers = [];
const manifest = [];

for (const [index, asset] of assets.entries()) {
  const pngPath = join(PNG_ROOT, `${asset.slug}.png`);
  const metadata = await sharp(pngPath).metadata();
  if (!metadata.width || !metadata.height || !metadata.hasAlpha) {
    throw new Error(`Expected an alpha PNG: ${pngPath}`);
  }

  const { data, info } = await sharp(pngPath)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const cornerAlpha = [
    data[3],
    data[(info.width - 1) * 4 + 3],
    data[(info.height - 1) * info.width * 4 + 3],
    data[((info.height * info.width) - 1) * 4 + 3],
  ];
  if (cornerAlpha.some((alpha) => alpha > 5)) {
    throw new Error(`Transparent corner validation failed: ${pngPath}`);
  }

  let visiblePixels = 0;
  for (let offset = 3; offset < data.length; offset += 4) {
    if (data[offset] > 12) visiblePixels += 1;
  }
  const coverage = visiblePixels / (info.width * info.height);
  if (coverage < 0.04 || coverage > 0.9) {
    throw new Error(`Implausible subject coverage ${coverage}: ${pngPath}`);
  }

  const trimmed = await sharp(pngPath)
    .trim({
      background: { r: 0, g: 0, b: 0, alpha: 0 },
      threshold: 4,
    })
    .png()
    .toBuffer();

  const webSubject = await sharp(trimmed)
    .resize({ width: 450, height: 570, fit: 'inside' })
    .png()
    .toBuffer();
  const webSubjectMetadata = await sharp(webSubject).metadata();
  const webLeft = Math.round((webWidth - webSubjectMetadata.width) / 2);
  const webTop = webHeight - webSubjectMetadata.height - 18;
  const webPath = join(WEB_ROOT, `${asset.slug}-512.webp`);
  await sharp({
    create: {
      width: webWidth,
      height: webHeight,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: webSubject, left: webLeft, top: webTop }])
    .webp({ quality: 92, alphaQuality: 100, smartSubsample: true })
    .toFile(webPath);

  const boardSubject = await sharp(trimmed)
    .resize({ width: 520, height: 570, fit: 'inside' })
    .png()
    .toBuffer();
  const boardSubjectMetadata = await sharp(boardSubject).metadata();
  const column = index % boardColumns;
  const row = Math.floor(index / boardColumns);
  boardLayers.push({
    input: boardSubject,
    left: column * boardCellWidth + Math.round((boardCellWidth - boardSubjectMetadata.width) / 2),
    top: row * boardCellHeight + 20,
  });

  manifest.push({
    slug: asset.slug,
    label: asset.label,
    png: `design/mascot/final/png/${asset.slug}.png`,
    webp: `website/public/mascot-v2/${asset.slug}-512.webp`,
    width: metadata.width,
    height: metadata.height,
    alpha: true,
    transparentCornerAlpha: cornerAlpha,
    subjectCoverage: Number(coverage.toFixed(4)),
  });
}

const labelSvg = Buffer.from(`
  <svg width="${boardWidth}" height="${boardHeight}" xmlns="http://www.w3.org/2000/svg">
    ${assets.map((asset, index) => {
      const column = index % boardColumns;
      const row = Math.floor(index / boardColumns);
      const x = column * boardCellWidth + boardCellWidth / 2;
      const y = row * boardCellHeight + boardCellHeight - 42;
      return `<text x="${x}" y="${y}" text-anchor="middle" fill="#182433"
        font-family="Arial, Helvetica, sans-serif" font-size="31" font-weight="700">${asset.label}</text>`;
    }).join('\n')}
  </svg>
`);

await sharp({
  create: {
    width: boardWidth,
    height: boardHeight,
    channels: 3,
    background: '#f6f0e5',
  },
})
  .composite([...boardLayers, { input: labelSvg, left: 0, top: 0 }])
  .png({ compressionLevel: 9, adaptiveFiltering: true, palette: false })
  .toFile(BOARD_PATH);

writeFileSync(
  MANIFEST_PATH,
  `${JSON.stringify({ generatedAt: new Date().toISOString(), assets: manifest }, null, 2)}\n`,
);

process.stdout.write(`${BOARD_PATH}\n`);
