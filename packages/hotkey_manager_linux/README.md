# hotkey_manager_linux

The Linux half of `hotkey_manager`, wired in through `dependency_overrides` in
the app's `pubspec.yaml` in place of the published package.

The published package binds through keybinder, which matches a press by the
key value it produces once the modifiers that produced it are taken away. Shift
turns `x` into `X`, so a binding of Shift and a letter never matches its own
press, and both of the app's default system-wide shortcuts, Alt+Shift+L and
Alt+Shift+N, are bindings of that kind. This one grabs the X key code under the
X modifiers itself and matches presses on exactly those, which also drops
keybinder from the app's runtime dependencies.

A shortcut fires when its key comes back up, once however long it was held.
Until then X holds the keyboard for the grab and GTK counts the app's own
window as unfocused, so a summon fired on the press could only ever show the
window, never put it away.

It speaks the published package's channels, so the Dart side of
`hotkey_manager` is unchanged. A shortcut that another client already holds
is refused, and the app shows that as a shortcut already in use. Wayland lets
no client grab keys at all, and the app never asks there.
