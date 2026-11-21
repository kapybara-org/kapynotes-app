# In-app mascot assets

`kapy_cursor_peek.webp` is the compact runtime crop for the cursor-peek
animation. It comes from the approved `kapy-hero-peek` production master in
the Kapy Notes brand repository. The crop is 136 x 256 with transparency and
is kept at 7 KB so occasional editor moments do not add a meaningful startup
or memory cost. The editor plays it once after five seconds without typing or
caret activity. It peeks from the caret's right side. Its 1.6-second compositor
timeline includes two blinks and a full return behind the caret; checklist
completion remains confetti-only.

The same crop is Kapy at the editor page's bottom-right edge. It stays out of
sight until the window has had no pointer or key input for a minute, slides in
for about three seconds, and comes back every two to five minutes while the
window stays idle (`lib/ui/kapy_page_peek.dart`).

The motion and cursor are rendered by
`lib/ui/kapy_cursor_peek.dart`. Keeping the source pose static and moving it
with Flutter means the same animation runs on macOS, Windows, iOS, and Android
without a Lottie or SVG runtime dependency.
