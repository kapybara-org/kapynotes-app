# Store screenshot artwork

`../store_screenshots.mjs` turns authentic captures into a bold, flat-color
store story using the final Kapy mascot system in
`../../../design/mascot/final/png`. Product UI and all numbers
stay untouched. Short benefit copy is added to every App Store and Play
canvas, with a dedicated top band on tablet art. Every export is an opaque PNG
at the corresponding upload size.

The renderer trims transparent padding from each mascot in memory and anchors
the visible feet to the device edge. Phone compositions use a controlled corner
overlap, while tablet compositions stay nearly flush so system chrome remains
clear.

Generate the raw iPhone and iPad captures first:

```sh
cd app
packaging/screenshots.sh all
```

The renderer also expects Android captures in these folders:

- `build/screenshots/android-phone`
- `build/screenshots/android-tablet-7`
- `build/screenshots/android-tablet-10`

With a debug APK and Android emulator available, regenerate those captures
with:

```sh
cd app
packaging/android_screenshots.sh
```

Then render every upload-ready set from the repository root:

```sh
node app/packaging/store_screenshots.mjs
```

Final files and a machine-readable dimension/alpha/alt-text manifest are
written to `app/build/store-listing/`.
