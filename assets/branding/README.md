# KapyNotes logo variants

- `kapy_notes_logo.png`: canonical in-app soft-corner mark.
- `kapynotes_mark_soft.png`: transparent soft-corner mark master.
- `kapynotes_mark_square.png`: preserved original square mark.
- `kapynotes_app_icon.png`: opaque app-icon master with a soft-corner mark.
- `kapynotes_lockup_light.png`: horizontal `Kapy Notes` lockup for light surfaces.
- `kapynotes_lockup_dark.png`: horizontal `Kapy Notes` lockup for dark surfaces.
- `kapynotes_tray_windows.ico`: notification-area icon, 16 to 48.
- `kapynotes_tray_macos.png`: menu bar icon, a template macOS tints itself.

Regenerate the raster variants and native platform icons from the preserved
square mark with:

```sh
swift tool/generate_brand_assets.swift
```
