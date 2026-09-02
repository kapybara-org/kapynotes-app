#!/usr/bin/env node

import {
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { chromium } from '../../website/node_modules/playwright/index.mjs';
import sharp from '../../website/node_modules/sharp/dist/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(HERE, '..');
const REPO_ROOT = resolve(APP_ROOT, '..');
const BUILD_ROOT = join(APP_ROOT, 'build');
const RAW_ROOT = join(BUILD_ROOT, 'screenshots');
const OUT_ROOT = join(BUILD_ROOT, 'store-listing');
const MASCOT_ROOT = join(REPO_ROOT, 'design', 'mascot', 'final', 'png');

const scenes = [
  {
    slug: 'live-calculator',
    source: '1-live-calculator.png',
    headline: 'Every Line Is a<br>Live Calculator',
    panel: '#ff9f0a',
    mascot: 'kapy-calculator.png',
    mascotSide: 'right',
    mascotRotation: '0deg',
    mascotScale: 1,
    mascotOverlap: 1,
    alt: 'Lisbon budget note calculating each expense, a complete euro total, and its US dollar conversion.',
  },
  {
    slug: 'capture-notes',
    source: '2-notes.png',
    headline: 'Capture Notes<br>Stay in Flow',
    panel: '#20afe6',
    mascot: 'kapy-notes.png',
    mascotSide: 'left',
    mascotRotation: '-1deg',
    mascotScale: 0.88,
    mascotOverlap: 1.12,
    alt: 'A structured meeting note with headings, key decisions, and next steps.',
  },
  {
    slug: 'thoughts-into-action',
    source: '3-checklist.png',
    headline: 'Turn Thoughts<br>Into Action',
    panel: '#67b95b',
    mascot: 'kapy-checklist.png',
    mascotSide: 'right',
    mascotRotation: '1deg',
    mascotScale: 1.05,
    mascotOverlap: 1.25,
    alt: 'A launch checklist with completed and upcoming tasks.',
  },
  {
    slug: 'calm-reflection',
    source: '4-journal.png',
    headline: 'A Calm Place<br>To Reflect',
    panel: '#bd72e8',
    mascot: 'kapy-journal.png',
    mascotSide: 'left',
    mascotRotation: '-1deg',
    mascotScale: 0.82,
    mascotOverlap: 1.12,
    alt: 'A dated journal entry capturing gratitude, a small win, and an intention for tomorrow.',
  },
  {
    slug: 'scale-recipes',
    source: '5-recipe.png',
    headline: 'Scale Recipes<br>Convert Any Unit',
    panel: '#f25757',
    mascot: 'kapy-recipe.png',
    mascotSide: 'right',
    mascotRotation: '1deg',
    mascotScale: 1.02,
    mascotOverlap: 1.3,
    alt: 'A cookie recipe scaled from twelve to eighteen servings with weight and temperature conversions.',
  },
];

const formats = [
  {
    id: 'app-store-iphone-6.9',
    output: join('app-store', 'iphone-6.9'),
    raw: 'iphone-6.9',
    width: 1320,
    height: 2868,
    cardWidth: 1030,
    cardBottom: 0,
    radius: 78,
    shadow: '0 42px 90px rgba(44, 30, 20, .26), 0 12px 30px rgba(44, 30, 20, .18)',
    copy: true,
    copyX: 90,
    copyY: 90,
    copyWidth: 1140,
    headlineSize: 118,
    mascotWidth: 310,
    mascotOverlap: 38,
    mascotInset: 18,
    contactShadowHeight: 20,
  },
  {
    id: 'app-store-ipad-13',
    output: join('app-store', 'ipad-13'),
    raw: 'ipad-13',
    width: 2064,
    height: 2752,
    cardWidth: 1700,
    cardBottom: 0,
    radius: 62,
    shadow: '0 48px 120px rgba(44, 30, 20, .24), 0 14px 36px rgba(44, 30, 20, .16)',
    copy: true,
    copyX: 160,
    copyY: 78,
    copyWidth: 1744,
    headlineSize: 110,
    mascotWidth: 340,
    mascotOverlap: 4,
    mascotInset: 38,
    contactShadowHeight: 20,
  },
  {
    id: 'play-store-phone',
    output: join('play-store', 'phone'),
    raw: 'android-phone',
    width: 1080,
    height: 1920,
    cardWidth: 900,
    cardBottom: 0,
    radius: 58,
    shadow: '0 34px 78px rgba(44, 30, 20, .27), 0 10px 24px rgba(44, 30, 20, .18)',
    copy: true,
    copyX: 55,
    copyY: 52,
    copyWidth: 970,
    headlineSize: 76,
    mascotWidth: 200,
    mascotOverlap: 16,
    mascotInset: 10,
    contactShadowHeight: 14,
  },
  {
    id: 'play-store-tablet-7',
    output: join('play-store', 'tablet-7'),
    raw: 'android-tablet-7',
    width: 1080,
    height: 1920,
    cardWidth: 1000,
    cardBottom: 50,
    radius: 44,
    shadow: '0 34px 82px rgba(44, 30, 20, .26), 0 10px 25px rgba(44, 30, 20, .17)',
    copy: true,
    copyX: 190,
    copyY: 54,
    copyWidth: 700,
    headlineSize: 58,
    mascotWidth: 200,
    mascotOverlap: 24,
    mascotInset: 10,
    contactShadowHeight: 14,
  },
  {
    id: 'play-store-tablet-10',
    output: join('play-store', 'tablet-10'),
    raw: 'android-tablet-10',
    width: 1080,
    height: 1920,
    cardWidth: 1000,
    cardBottom: 50,
    radius: 44,
    shadow: '0 34px 82px rgba(44, 30, 20, .26), 0 10px 25px rgba(44, 30, 20, .17)',
    copy: true,
    copyX: 190,
    copyY: 54,
    copyWidth: 700,
    headlineSize: 58,
    mascotWidth: 200,
    mascotOverlap: 24,
    mascotInset: 10,
    contactShadowHeight: 14,
  },
];

const dataUriCache = new Map();
const mascotDataUriCache = new Map();

function dataUri(path, mime = 'image/png') {
  if (!dataUriCache.has(path)) {
    dataUriCache.set(path, `data:${mime};base64,${readFileSync(path).toString('base64')}`);
  }
  return dataUriCache.get(path);
}

async function mascotDataUri(path) {
  if (!mascotDataUriCache.has(path)) {
    mascotDataUriCache.set(
      path,
      sharp(path)
        .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 } })
        .png()
        .toBuffer()
        .then((buffer) => `data:image/png;base64,${buffer.toString('base64')}`),
    );
  }
  return mascotDataUriCache.get(path);
}

const figtree = dataUri(
  join(REPO_ROOT, 'website', 'public', 'fonts', 'figtree-latin.woff2'),
  'font/woff2',
);
const odin = dataUri(
  join(APP_ROOT, 'assets', 'fonts', 'OdinRounded-Bold.otf'),
  'font/otf',
);

async function rawDimensions(path) {
  const metadata = await sharp(path).metadata();
  if (!metadata.width || !metadata.height) throw new Error(`Could not read dimensions for ${path}`);
  return metadata;
}

function htmlFor({ format, scene, rawPath, rawWidth, rawHeight, mascotUri }) {
  const cardHeight = Math.round((format.cardWidth * rawHeight) / rawWidth);
  const x = Math.round((format.width - format.cardWidth) / 2);
  const y = format.height - cardHeight - format.cardBottom;
  const outline = Math.max(5, Math.round(format.width / 180));
  const mascotWidth = Math.round(format.mascotWidth * scene.mascotScale);
  const mascotOverlap = Math.round(format.mascotOverlap * scene.mascotOverlap);
  const mascotBottom = format.height - y - mascotOverlap;
  const copy = format.copy
    ? `<section class="copy">
        <h1>${scene.headline}</h1>
      </section>`
    : '';
  const mascotSide = scene.mascotSide === 'left'
    ? `left: ${format.mascotInset}px;`
    : `right: ${format.mascotInset}px;`;

  return `<!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8">
      <style>
        @font-face { font-family: Figtree; src: url('${figtree}') format('woff2'); font-weight: 300 900; }
        @font-face { font-family: Odin; src: url('${odin}') format('opentype'); font-weight: 700; }
        * { box-sizing: border-box; }
        html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
        body { background: ${scene.panel}; font-family: Figtree, sans-serif; }
        .canvas { position: relative; width: ${format.width}px; height: ${format.height}px; overflow: hidden; isolation: isolate; background: ${scene.panel}; }
        .copy { position: absolute; z-index: 4; left: ${format.copyX ?? 0}px; top: ${format.copyY ?? 0}px; width: ${format.copyWidth ?? 0}px; color: white; text-align: center; }
        .copy h1 { margin: 0; font-family: Figtree, sans-serif; font-size: ${format.headlineSize ?? 0}px; font-weight: 850; line-height: .98; letter-spacing: -.035em; text-wrap: balance; }
        .mascot-wrap { position: absolute; z-index: 3; ${mascotSide} bottom: ${mascotBottom}px; width: ${mascotWidth}px; }
        .mascot-wrap::after { content: ''; position: absolute; z-index: -1; left: 22%; bottom: -2px; width: 56%; height: ${format.contactShadowHeight}px; border-radius: 50%; background: rgba(58, 31, 15, .24); filter: blur(${Math.round(format.contactShadowHeight / 3)}px); transform: scaleY(.55); }
        .mascot { position: relative; z-index: 1; display: block; width: 100%; height: auto; transform: rotate(${scene.mascotRotation}); transform-origin: 50% 100%; filter: drop-shadow(0 5px 3px rgba(58, 31, 15, .18)) drop-shadow(0 12px 12px rgba(58, 31, 15, .10)); }
        .product-card { position: absolute; z-index: 2; left: ${x}px; top: ${y}px; width: ${format.cardWidth}px; height: ${cardHeight}px; overflow: hidden; border-radius: ${format.radius}px ${format.radius}px 0 0; background: #fbf5e7; box-shadow: ${format.shadow}; }
        .product-card::after { content: ''; position: absolute; z-index: 2; inset: 0; border-radius: inherit; box-shadow: inset 0 0 0 ${outline}px rgba(255,255,255,.82), inset 0 0 0 ${outline + 2}px rgba(33,31,28,.09); pointer-events: none; }
        .product-card img { display: block; width: 100%; height: 100%; object-fit: fill; }
      </style>
    </head>
    <body>
      <main class="canvas">
        ${copy}
        <div class="mascot-wrap"><img class="mascot" alt="" src="${mascotUri}"></div>
        <div class="product-card"><img alt="${scene.alt}" src="${dataUri(rawPath)}"></div>
      </main>
    </body>
  </html>`;
}

const browser = await chromium.launch({ headless: true });
const manifest = {
  generatedAt: new Date().toISOString(),
  guidance: {
    appStore: 'One to ten PNG or JPEG screenshots, opaque, using accepted device dimensions.',
    playStore: 'Five 9:16 screenshots at 1080 x 1920 per supported device class; opaque 24-bit PNG.',
  },
  files: [],
};

try {
  for (const format of formats) {
    const outputDir = join(OUT_ROOT, format.output);
    rmSync(outputDir, { recursive: true, force: true });
    mkdirSync(outputDir, { recursive: true });

    for (const [index, scene] of scenes.entries()) {
      const rawPath = join(RAW_ROOT, format.raw, scene.source);
      const raw = await rawDimensions(rawPath);
      const mascotUri = await mascotDataUri(join(MASCOT_ROOT, scene.mascot));
      const page = await browser.newPage({
        viewport: { width: format.width, height: format.height },
        deviceScaleFactor: 1,
      });

      await page.setContent(
        htmlFor({
          format,
          scene,
          rawPath,
          rawWidth: raw.width,
          rawHeight: raw.height,
          mascotUri,
        }),
        { waitUntil: 'load' },
      );
      await page.evaluate(async () => {
        await document.fonts.ready;
        await Promise.all(
          [...document.images].map((img) =>
            img.complete ? Promise.resolve() : new Promise((resolve) => img.addEventListener('load', resolve)),
          ),
        );
      });

      const fileName = `${String(index + 1).padStart(2, '0')}-${scene.slug}.png`;
      const outputPath = join(outputDir, fileName);
      const tempPath = `${outputPath}.render.png`;
      await page.screenshot({ path: tempPath, type: 'png', omitBackground: false });
      await page.close();

      await sharp(tempPath)
        .removeAlpha()
        .png({ compressionLevel: 9, adaptiveFiltering: true, palette: false })
        .toFile(outputPath);
      rmSync(tempPath);

      const metadata = await sharp(outputPath).metadata();
      if (
        metadata.width !== format.width ||
        metadata.height !== format.height ||
        metadata.hasAlpha
      ) {
        throw new Error(`Invalid output metadata for ${outputPath}: ${JSON.stringify(metadata)}`);
      }

      manifest.files.push({
        path: outputPath.slice(REPO_ROOT.length + 1),
        platform: format.id,
        width: metadata.width,
        height: metadata.height,
        hasAlpha: metadata.hasAlpha,
        bytes: statSync(outputPath).size,
        headline: format.copy ? scene.headline.replace('<br>', ' ') : null,
        altText: scene.alt,
      });
      process.stdout.write(`Created ${format.output}/${fileName}\n`);
    }
  }
} finally {
  await browser.close();
}

mkdirSync(OUT_ROOT, { recursive: true });
writeFileSync(join(OUT_ROOT, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
process.stdout.write(`\nStore screenshots: ${OUT_ROOT}\n`);
