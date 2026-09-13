# Fonts

## Writing font

The note editor defaults to Shantell Sans by Shantell Martin and Arrow Type.
Its variable axes are configured with low informality and no baseline bounce,
keeping the writing surface human without making longer notes feel busy. The
bundled upright and italic variable fonts are distributed through Google Fonts
under the SIL Open Font License 1.1.

Source: <https://github.com/google/fonts/tree/main/ofl/shantellsans>

The two files here are not the upstream fonts as downloaded. The app pins
three of the four axes to constants (`WritingFontDetails.fontVariations` in
`lib/core/editor_font.dart`: `INFM` 16, `BNCE` 0, `SPAC` 0) and only ever
varies the weight, so those three are baked in and only `wght` is left
variable. Same glyphs, same coverage, identical rendering at the values the
app uses, and half the bytes in every install: 1.28 MB + 1.53 MB became
0.73 MB + 0.74 MB. To regenerate from the upstream variable fonts:

```sh
pip install fonttools
fonttools varLib.instancer -o ShantellSans-Variable.ttf \
  ShantellSans-Variable.ttf INFM=16 BNCE=0 SPAC=0
fonttools varLib.instancer -o ShantellSans-Italic-Variable.ttf \
  ShantellSans-Italic-Variable.ttf INFM=16 BNCE=0 SPAC=0
```

Change the pinned values in `editor_font.dart` and this has to be redone
with the new ones, from the upstream files, or the change will not show.

License: [`ShantellSans-OFL.txt`](ShantellSans-OFL.txt)

## Brand font

The `Kapy Notes` wordmark uses Odin Rounded Bold by Frank Hemmekam.

Source: <https://www.dafont.com/odin-rounded.font>

The source page labels the font as `100% Free`. The downloaded archive contains
the font and specimen, but no separate license file.
