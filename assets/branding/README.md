# KapyNotes logo variants

The mark is the v5-4 Fold: a capybara head whose folded corner and two eyes
are cut out of one solid shape, cream (#FBF1E3) on orange (#E8772E).

Drawn by `tool/generate_brand_assets.swift` from the mark's vector geometry:

- `kapy_notes_logo.png`: canonical in-app mark, the rounded tile.
- `kapynotes_mark_soft.png`: transparent rounded-tile master.
- `kapynotes_app_icon.png`: opaque, full-bleed app-icon master, safe for every
  system mask.
- `kapynotes_lockup_light.png`: horizontal `Kapy Notes` lockup for light surfaces.
- `kapynotes_lockup_dark.png`: horizontal `Kapy Notes` lockup for dark surfaces.
- `kapynotes_tray_windows.ico`: notification-area icon, 16 to 48.
- `kapynotes_tray_macos.png`: menu bar icon, a template macOS tints itself.
- `kapynotes_tray_linux.png`: Linux panel indicator, the 64 px app icon from
  `linux/runner/resources/icons/`.

```sh
swift tool/generate_brand_assets.swift
```

The generator also writes the iOS launch image. The app icons themselves are
the designer's production pack, copied in as delivered because its 16 and
32 px sizes are tuned to whole pixels: the macOS and iOS asset catalogs, the
Android mipmaps (adaptive foreground, monochrome themed layer, legacy circle)
and `windows/runner/resources/app_icon.ico`. The iOS Any icon is flattened
to drop its alpha channel (`tool/flatten_png.swift`), which the App Store
rejects.

The header animation, the disk image and the Windows installer carry the mark
too; redraw them after a brand change with
`tool/generate_kapy_header_atlases.swift`,
`tool/generate_dmg_background.swift` and
`tool/generate_windows_installer_art.swift`.
