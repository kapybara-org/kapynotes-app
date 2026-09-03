#!/usr/bin/env node
//
// Renders the two Play Console graphic assets that are not screenshots.
//
//   node packaging/play_graphics.mjs
//
// Play asks for both before a listing can be submitted, and neither comes out
// of the app build:
//
//   icon-512.png        512 x 512, 32-bit PNG, alpha channel required
//   feature-graphic.png 1024 x 500, 24-bit PNG, no alpha
//
// The icon is the shipped launcher icon downscaled, not a new drawing. The
// Android adaptive icon is a coral squircle on cream (values/colors.xml sets
// ic_launcher_background to #FCF6EA), so keeping the cream frame is what makes
// the store tile match the icon a user sees after installing.
//
// The feature graphic is drawn here rather than exported by hand so a brand
// change is one edit and one rerun, the same arrangement store_screenshots.mjs
// uses for the listing screenshots.

import { mkdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { chromium } from '../../website/node_modules/playwright/index.mjs';
import sharp from '../../website/node_modules/sharp/dist/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(HERE, '..');
const REPO_ROOT = resolve(APP_ROOT, '..');
const OUT_DIR = join(APP_ROOT, 'build', 'store-listing', 'play-store');
const MASCOT = join(REPO_ROOT, 'design', 'mascot', 'final', 'png', 'kapy-calculator.png');
const ICON_SOURCE = join(APP_ROOT, 'assets', 'branding', 'kapynotes_app_icon.png');

// Straight from website/src/styles/global.css, so the listing and the site
// cannot drift apart.
const CORAL = '#ea4718';
const CORAL_DARK = '#c0340e';
const CREAM = '#fdf5e9';

const FEATURE = { width: 1024, height: 500 };

function dataUri(path, mime) {
  return `data:${mime};base64,${readFileSync(path).toString('base64')}`;
}

const figtree = dataUri(
  join(REPO_ROOT, 'website', 'public', 'fonts', 'figtree-latin.woff2'),
  'font/woff2',
);
const odin = dataUri(join(APP_ROOT, 'assets', 'fonts', 'OdinRounded-Bold.otf'), 'font/otf');

// The source PNGs carry transparent padding. Anchoring on the raw canvas would
// leave the mascot hovering, the same bug the screenshot renderer trims out.
const mascot = `data:image/png;base64,${(
  await sharp(MASCOT)
    .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer()
).toString('base64')}`;

// Play crops the feature graphic to several aspect ratios across the store, and
// overlays a play button dead centre when a promo video is attached. Copy stays
// left, the character stays right, and the middle carries nothing but ground.
const featureHtml = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <style>
      @font-face { font-family: Figtree; src: url('${figtree}') format('woff2'); font-weight: 300 900; }
      @font-face { font-family: Odin; src: url('${odin}') format('opentype'); font-weight: 700; }
      * { box-sizing: border-box; }
      html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; }
      body { font-family: Figtree, sans-serif; }

      .canvas {
        position: relative;
        width: ${FEATURE.width}px;
        height: ${FEATURE.height}px;
        overflow: hidden;
        isolation: isolate;
        background:
          radial-gradient(120% 150% at 18% 8%, rgba(255, 190, 120, .30), rgba(255, 190, 120, 0) 58%),
          linear-gradient(158deg, ${CORAL} 0%, ${CORAL} 52%, ${CORAL_DARK} 100%);
      }

      /* The same paper grain the ivory and apricot chapters of the site use. */
      .grain {
        position: absolute;
        inset: 0;
        z-index: 1;
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='220' height='220'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='220' height='220' filter='url(%23n)' opacity='0.055'/%3E%3C/svg%3E");
        mix-blend-mode: overlay;
        opacity: .55;
      }

      .copy { position: absolute; z-index: 3; left: 76px; top: 176px; width: 470px; color: ${CREAM}; }
      .wordmark { margin: 0; font-family: Odin, Figtree, sans-serif; font-weight: 700; font-size: 82px; line-height: .94; letter-spacing: -.012em; }
      .tagline { margin: 20px 0 0; font-size: 31px; font-weight: 750; line-height: 1.24; letter-spacing: -.014em; color: rgba(253, 245, 233, .93); }

      /* A cream ground so the orange character never sits orange-on-coral. */
      .ground {
        position: absolute;
        z-index: 2;
        left: 592px;
        top: 42px;
        width: 416px;
        height: 416px;
        border-radius: 50%;
        background: radial-gradient(circle at 42% 34%, #fffaf2 0%, ${CREAM} 62%, #f3e3cd 100%);
        box-shadow: 0 26px 60px rgba(74, 24, 6, .30), inset 0 -18px 40px rgba(196, 137, 78, .16);
      }

      .mascot-wrap { position: absolute; z-index: 4; left: 654px; bottom: 66px; width: 292px; }
      .mascot-wrap::after {
        content: '';
        position: absolute;
        z-index: -1;
        left: 20%;
        bottom: -6px;
        width: 60%;
        height: 26px;
        border-radius: 50%;
        background: rgba(88, 46, 18, .26);
        filter: blur(9px);
        transform: scaleY(.5);
      }
      .mascot { display: block; width: 100%; height: auto; filter: drop-shadow(0 6px 4px rgba(58, 31, 15, .18)) drop-shadow(0 16px 16px rgba(58, 31, 15, .12)); }
    </style>
  </head>
  <body>
    <main class="canvas">
      <div class="ground"></div>
      <section class="copy">
        <h1 class="wordmark">Kapy Notes</h1>
        <p class="tagline">Every line is a live calculator</p>
      </section>
      <div class="mascot-wrap"><img class="mascot" alt="" src="${mascot}"></div>
      <div class="grain"></div>
    </main>
  </body>
</html>`;

mkdirSync(OUT_DIR, { recursive: true });

const browser = await chromium.launch({ headless: true });
const featurePath = join(OUT_DIR, 'feature-graphic.png');
try {
  const page = await browser.newPage({
    viewport: { width: FEATURE.width, height: FEATURE.height },
    deviceScaleFactor: 1,
  });
  await page.setContent(featureHtml, { waitUntil: 'load' });
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all(
      [...document.images].map((img) =>
        img.complete ? Promise.resolve() : new Promise((done) => img.addEventListener('load', done)),
      ),
    );
  });

  const temp = `${featurePath}.render.png`;
  await page.screenshot({ path: temp, type: 'png', omitBackground: false });
  await page.close();

  // Play rejects a feature graphic that carries an alpha channel.
  await sharp(temp).removeAlpha().png({ compressionLevel: 9 }).toFile(featurePath);
  rmSync(temp);
} finally {
  await browser.close();
}

// Play wants 32-bit here, so the alpha channel stays even though it is opaque.
const iconPath = join(OUT_DIR, 'icon-512.png');
await sharp(ICON_SOURCE)
  .resize(512, 512, { fit: 'cover' })
  .ensureAlpha()
  .png({ compressionLevel: 9 })
  .toFile(iconPath);

for (const [path, want] of [
  [featurePath, { width: 1024, height: 500, alpha: false, maxBytes: 15 * 1024 * 1024 }],
  [iconPath, { width: 512, height: 512, alpha: true, maxBytes: 1024 * 1024 }],
]) {
  const meta = await sharp(path).metadata();
  const bytes = statSync(path).size;
  if (meta.width !== want.width || meta.height !== want.height) {
    throw new Error(`${path}: expected ${want.width}x${want.height}, got ${meta.width}x${meta.height}`);
  }
  if (Boolean(meta.hasAlpha) !== want.alpha) {
    throw new Error(`${path}: expected hasAlpha=${want.alpha}, got ${meta.hasAlpha}`);
  }
  if (bytes > want.maxBytes) {
    throw new Error(`${path}: ${bytes} bytes exceeds the Play limit of ${want.maxBytes}`);
  }
  process.stdout.write(
    `Created ${path.slice(REPO_ROOT.length + 1)} (${meta.width}x${meta.height}, alpha=${Boolean(
      meta.hasAlpha,
    )}, ${Math.round(bytes / 1024)} KB)\n`,
  );
}
