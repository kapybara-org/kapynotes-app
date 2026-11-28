# Fonts

## Handwritten font

The Handwritten writing font, Mixed's titles and headings, and the few
friendly moments in the app's chrome that use the handwritten accent style
(`AppFonts.hand`) are set in Shantell Sans by Shantell Martin and Arrow Type.
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

## Interface fonts

The interface is set in Geist by the Geist Project Authors (Vercel), bundled
and the same on every platform, under the SIL Open Font License 1.1. The
Clean writing font and Mixed's body text use it too. The files are the
upstream variable fonts as the `geist` npm package 1.9.2 ships them (Geist
1.900), unmodified, with `wght` from 100 to 900.

Geist has no ⌘, ⌥, ⌃, ⎋, ⏎ or ⌫, no ₩ ₺ ₫ ₦ ₸ ₿, and no Devanagari or other
non-Latin, non-Greek, non-Cyrillic scripts, so those come from the device's
own face (`AppFonts.uiFallback` in `lib/core/theme.dart`).

Code and the Monospace writing font are set in Geist Mono, the upstream
variable font as Google Fonts distributes it, unmodified, with `wght` from
100 to 900. Geist Mono has ⏎ and ⌫ but no ⌘, ⌥, ⌃ or ⎋, so those come from
the platform monospace face (`AppFonts.monoFallback`).

The Pixel writing font is set in Geist Pixel's Square cut, one of the five
static cuts in vercel/geist-pixel-font, converted from the npm package's
WOFF2 to TrueType with fonttools and otherwise unmodified. It has 420
glyphs and no ₹, ☐, ☑ or ✓; Geist draws whatever it lacks.

| File | Source | Size |
| --- | --- | --- |
| `Geist-Variable.ttf` | [`geist`](https://www.npmjs.com/package/geist) 1.9.2, `dist/fonts/geist-sans/Geist-Variable.ttf` | 169 KB |
| `Geist-Italic-Variable.ttf` | `geist` 1.9.2, `dist/fonts/geist-sans/Geist-Italic[wght].ttf` | 175 KB |
| `GeistMono-Variable.ttf` | [`ofl/geistmono/GeistMono[wght].ttf`](https://github.com/google/fonts/tree/main/ofl/geistmono), from [vercel/geist-font](https://github.com/vercel/geist-font) at `77f0563` | 172 KB |
| `GeistPixel-Square.ttf` | `geist` 1.9.2, `dist/fonts/geist-pixel/GeistPixel-Square.woff2`, as TrueType | 94 KB |

Licenses: [`Geist-OFL.txt`](Geist-OFL.txt) (from vercel/geist-font),
[`GeistMono-OFL.txt`](GeistMono-OFL.txt),
[`GeistPixel-OFL.txt`](GeistPixel-OFL.txt) (from
[vercel/geist-pixel-font](https://github.com/vercel/geist-pixel-font))

## Formula fonts

Formulas written in TeX are drawn in KaTeX's fonts, which come with
flutter_math_fork rather than living here: twenty files, about 660 KB in
every install. They are MIT licensed by Khan Academy, and that notice ships
as `packages/flutter_math_fork/katex_fonts/LICENSE`, listed in
`pubspec.yaml`, since the package's own LICENSE does not carry it.

Source: <https://github.com/KaTeX/katex-fonts>

## Brand font

The `Kapy Notes` wordmark uses Odin Rounded Bold by Frank Hemmekam.

Source: <https://www.dafont.com/odin-rounded.font>

The source page labels the font as `100% Free`. The downloaded archive contains
the font and specimen, but no separate license file.
