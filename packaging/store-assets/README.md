# Store screenshot artwork

`../store_screenshots.mjs` turns authentic captures into a bold, flat-color
store story using the final Kapy mascot system. Product UI and all numbers
stay untouched. Short benefit copy is added to every App Store and Play
canvas, with a dedicated top band on tablet art. Every export is an opaque PNG
at the corresponding upload size.

The renderer trims transparent padding from each mascot in memory and anchors
the visible feet to the device edge. Phone compositions use a controlled corner
overlap, while tablet compositions stay nearly flush so system chrome remains
clear.

## What comes from the kapynotes repository

The mascot PNGs (`design/mascot/final/png`) and the website's `playwright` and
`sharp` live in the kapybara-org/kapynotes repository, not in this one.
`store_screenshots.mjs` and `play_graphics.mjs` look for a kapynotes clone in
this order and use the first one that has all three:

1. the folder named by `KAPYNOTES_REPO_ROOT`
2. a sibling folder named `kapynotes`
3. a sibling folder named `KapyNotes`

Install the website dependencies in that clone first:

```sh
cd ../kapynotes
npm install
```

To use a clone somewhere else, point the scripts at it:

```sh
export KAPYNOTES_REPO_ROOT=/path/to/kapynotes
```

The mascot web exports and the contact sheets are rebuilt from that clone with
`design/mascot/prepare_mascot_assets.mjs`; nothing in this repository does it.

## Capturing

Run everything below from the root of this repository.

Generate the raw iPhone and iPad captures first:

```sh
packaging/screenshots.sh all
```

The renderer also expects Android captures in these folders:

- `build/screenshots/android-phone`
- `build/screenshots/android-tablet-7`
- `build/screenshots/android-tablet-10`

With a debug APK and Android emulator available, regenerate those captures
with:

```sh
packaging/android_screenshots.sh
```

## Rendering

Then render every upload-ready set:

```sh
node packaging/store_screenshots.mjs
```

Final files and a machine-readable dimension/alpha/alt-text manifest are
written to `build/store-listing/`.
