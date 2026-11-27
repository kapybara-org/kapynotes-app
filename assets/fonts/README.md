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

On a Mac and an iPhone the interface is set in San Francisco, through the
system face: its licence allows it only on Apple's platforms, so it is never
bundled. Windows, Android and Linux get Inter by Rasmus Andersson, the closest
free match, under the SIL Open Font License 1.1. The Clean writing font and
Mixed's body text use the same face.

The app sets interface text at 400 and 600 only, and 700 when the system's
Bold Text is on, so the two files here are instances of Inter 4.1's variable
fonts with the optical size pinned to text (opsz 14) and the weight axis cut
to 400–700: 880 KB + 910 KB became 514 KB + 520 KB. To regenerate them from
the release's InterVariable.ttf and InterVariable-Italic.ttf:

```sh
pip install fonttools
fonttools varLib.instancer -o Inter-Variable.ttf InterVariable.ttf opsz=14 wght=400:700
fonttools varLib.instancer -o Inter-Italic-Variable.ttf InterVariable-Italic.ttf opsz=14 wght=400:700
```

Source: <https://github.com/rsms/inter/releases/tag/v4.1>

Calculation results, keycaps and code are set in Geist Mono by the Geist
Project Authors (Vercel), the upstream variable font as Google Fonts
distributes it, unmodified, with `wght` from 100 to 900, under the SIL Open
Font License 1.1. Geist Mono has no ⌘, ⌥ or ⌃, so a keycap draws those from
the platform monospace face (`AppFonts.monoFallback` in `lib/core/theme.dart`).

| File | Source | Size |
| --- | --- | --- |
| `Inter-Variable.ttf` | Inter 4.1, `InterVariable.ttf`, instanced as above | 514 KB |
| `Inter-Italic-Variable.ttf` | Inter 4.1, `InterVariable-Italic.ttf`, instanced as above | 520 KB |
| `GeistMono-Variable.ttf` | [`ofl/geistmono/GeistMono[wght].ttf`](https://github.com/google/fonts/tree/main/ofl/geistmono), from [vercel/geist-font](https://github.com/vercel/geist-font) at `77f0563` | 172 KB |

Licenses: [`Inter-OFL.txt`](Inter-OFL.txt),
[`GeistMono-OFL.txt`](GeistMono-OFL.txt)

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
