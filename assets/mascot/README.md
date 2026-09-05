# In-app mascot assets

`kapy_cursor_peek.webp` is the compact runtime crop for the cursor-peek
animation. It comes from the approved `kapy-hero-peek` production master in
the Kapy Notes brand repository. The crop is 136 x 256 with transparency and
is kept at 7 KB so occasional editor moments do not add a meaningful startup
or memory cost.

The motion and cursor are rendered by
`lib/ui/kapy_cursor_peek.dart`. Keeping the source pose static and moving it
with Flutter means the same animation runs on macOS, Windows, iOS, and Android
without a Lottie or SVG runtime dependency.
