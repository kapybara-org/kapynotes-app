# Kapy Notes as a Flatpak

`com.kapybara.kapynotes.yml` repackages the portable tarball that
`packaging/linux/package.sh` builds, so the Flatpak runs the same release
build, bundled libraries (tray, X11 shortcut, libsecret) and ffmpeg as the
tar.gz, .deb and AppImage. It runs on the GNOME 51 runtime, which carries
GTK 3.

## Build and install it locally

On Linux, with `flatpak` and `flatpak-builder` installed:

```sh
packaging/release.sh linux
mkdir -p build/flatpak
cp build/release/KapyNotes-*-linux-"$(uname -m)".tar.gz build/flatpak/kapynotes-linux.tar.gz
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak-builder --user --install-deps-from=flathub --install --force-clean \
  --state-dir=build/flatpak/state build/flatpak/app \
  packaging/linux/flatpak/com.kapybara.kapynotes.yml
flatpak run com.kapybara.kapynotes
```

For a single file to install elsewhere, build with
`--repo=build/flatpak/repo` in place of `--install`, then:

```sh
flatpak build-bundle build/flatpak/repo build/flatpak/KapyNotes.flatpak com.kapybara.kapynotes \
  --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user build/flatpak/KapyNotes.flatpak
```

## What the sandbox allows

The window (Wayland, X11 as a fallback, the GPU), PulseAudio for voice notes,
the network for sync and for the MCP server on 127.0.0.1, the
StatusNotifierWatcher for the tray icon, and the Secret Service for the
session and MCP tokens. No host files beyond what the file chooser portal
hands over.

The Secret Service rather than the Secret portal because of the plugin, not
the runtime: libsecret 0.20 and later keep a sandboxed app's secrets in a
keyring file of its own, keyed by the portal, but only through its
`secret_password_*` calls. flutter_secure_storage first unlocks the keyring
through `secret_service_get_sync`, which always goes to the Secret Service,
so without `--talk-name=org.freedesktop.secrets` the Flatpak can't keep
anyone signed in. Moving to the portal needs a plugin that sticks to the
`secret_password_*` calls.

The app knows it is the Flatpak from `FLATPAK_ID` or `/.flatpak-info`, and
then leaves updates to Flatpak, hides Open at login, and gives
`flatpak run com.kapybara.kapynotes --new-note` as the command for a system
shortcut on Wayland. Its notes live in `~/.var/app/com.kapybara.kapynotes`,
apart from any tar.gz, .deb or AppImage install; sync carries them across.

## What Flathub still needs

- A `flathub/com.kapybara.kapynotes` repository with this manifest, its
  source changed from the local path to the released tarballs: one
  `type: archive` source per arch with `url`, `sha256` and `only-arches`,
  and `x-checker-data` so Flathub's bot follows new releases.
- Screenshots in the metainfo, which Flathub's linter requires, and a check
  of the build with `flatpak-builder-lint` (manifest and repo).
- Verification of the `com.kapybara` ID, which needs kapybara.com, or a
  move to an ID on a domain Kapybara can verify.
- Open at login through the Background portal, which the Flatpak hides for
  now.
