# In-app mascot assets

`kapy_cursor_peek.webp` is the compact runtime crop for the cursor-peek
animation. It comes from the approved `kapy-hero-peek` production master in
the Kapy Notes brand repository. The crop is 136 x 256 with transparency and
is kept at 7 KB so occasional editor moments do not add a meaningful startup
or memory cost. The editor plays it once after five seconds without typing or
caret activity. It peeks from the caret's right side. Its 1.6-second compositor
timeline includes two blinks and a full return behind the caret; checklist
completion remains confetti-only.

The motion and cursor are rendered by
`lib/ui/kapy_cursor_peek.dart`. Keeping the source pose static and moving it
with Flutter means the same animation runs on macOS, Windows, iOS, and Android
without a Lottie or SVG runtime dependency.

`kapy_header_pose_sheet.png` is the 1536 x 1024 transparent production master
for every header state: standing, counting one, counting two, counting three,
head scratching, and sleeping. The six poses were generated together from the
approved landing-page production board and hero-peek references. This keeps the
face, body proportions, palette, texture, and lighting consistent between
frames. The master is intentionally not declared in `pubspec.yaml`.

`kapy_sleep_lowering_pose_sheet.png` and
`kapy_sleep_settling_pose_sheet.png` are transparent production masters for the
natural sleep transition. They add an upright bend, supported squat, all-fours
stance, tucked rest, and head-lowering pose. The forward sequence lowers Kapy's
weight through the paws and folds the legs under the body instead of rotating
the standing artwork sideways. Wake plays the same supported movement in
reverse.

The individual `kapy_standing`, `kapy_count_1`, `kapy_count_2`,
`kapy_count_3`, `kapy_scratch`, `kapy_sleep_bend`, `kapy_sleep_squat`,
`kapy_sleep_all_fours`, `kapy_sleep_tuck`, `kapy_sleep_head_down`, and
`kapy_sleeping` WebPs are the source poses for the header animation. Only
standing and sleeping are bundled as loading fallbacks. `kapy_sleeping.png`
retains the larger transparent design crop.

The four `kapy_header_*_30fps.webp` files are compact sprite atlases containing
real, opaque animation frames at 30 frames per second:

- emerge: 30 frames over 1 second; hide reuses these frames in reverse
- think: 180 frames over 6 seconds
- sleep: 72 frames over 2.4 seconds; wake reuses these frames in reverse
- sleep loop: 96 frames over 3.2 seconds

Every frame is 64 x 46 physical pixels, twice the 32 x 23 logical display
size. Two transparent gutter pixels surround each atlas cell so bilinear
sampling cannot bleed a neighboring frame into the current one. The four
compressed atlases total about 388 KB.

`lib/ui/kapy_header_mascot.dart` advances the atlases at exactly 30 fps from
Flutter's vsynced animation clock. This provides deterministic pause, reverse,
and interruption behavior without a Lottie dependency or opacity crossfades
between source poses. Only the active atlas is painted, and its `CustomPainter`
does not repaint on duplicate 60 or 120 Hz display ticks.

Regenerate the source PNG atlases and their runtime WebPs from the app root:

```sh
swift tool/generate_kapy_header_atlases.swift
for name in kapy_header_emerge_30fps kapy_header_think_30fps \
  kapy_header_sleep_30fps kapy_header_sleep_loop_30fps; do
  cwebp -quiet -q 90 -alpha_q 100 -m 6 -sharp_yuv -metadata none \
    "build/kapy_header_atlases/$name.png" \
    -o "assets/mascot/$name.webp"
done
```
