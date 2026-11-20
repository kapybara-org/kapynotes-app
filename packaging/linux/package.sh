#!/usr/bin/env bash
#
# Turns a `flutter build linux --release` bundle into the three Linux
# downloads, for the arch of the machine it runs on:
#
#   KapyNotes-<version>-linux-<arch>.tar.gz   portable bundle in kapynotes/
#   KapyNotes-<version>-<debarch>.deb         installs to /usr/lib/kapynotes
#   KapyNotes-<version>-<arch>.AppImage       portable bundle, static runtime
#
# Usage: packaging/linux/package.sh <bundle-dir> <version> <out-dir>
# packaging/release.sh linux runs it after the Flutter build; it needs the
# ffmpeg that packaging/linux/build_ffmpeg.sh leaves in build/linux/ffmpeg.
#
# Every package carries libexec/ffmpeg beside the app; the runner puts libexec
# first on PATH, which is how voice notes record, play and transcribe without
# ffmpeg installed. See packaging/linux/build_ffmpeg.sh.
#
# The .deb ships the bundle as built and lets dpkg-shlibdeps turn every ELF's
# needs into Depends, so apt installs the rest from the distro.
#
# The tar.gz and the AppImage have no package manager behind them, so their
# "portable" bundle carries whatever a stock GNOME or KDE desktop on Ubuntu,
# Debian or Fedora may not have. The rule, applied by walking DT_NEEDED from
# every ELF in the bundle:
#
#   the host provides  glibc, libstdc++ and libgcc_s; GLib, GTK 3, GDK,
#                      gdk-pixbuf, Pango, cairo, HarfBuzz, ATK and AT-SPI,
#                      epoxy, fontconfig, FreeType; X11, xcb, xkbcommon and
#                      Wayland; GL, EGL, GLES, drm and gbm; libpulse; D-Bus;
#                      zlib and libgcrypt. These are ABI-stable, present on
#                      every desktop, and a copy of them (glibc and GL above
#                      all) breaks on hosts newer or older than ours. The walk
#                      stops at them.
#   the bundle carries everything else the walk reaches, in lib/: in practice
#                      the tray (libayatana-appindicator3 and its indicator,
#                      ido and dbusmenu libraries) and libsecret. Each copy gets
#                      RUNPATH $ORIGIN, as does every .so in lib/ that needs
#                      one of them, so they resolve with no wrapper script and
#                      no LD_LIBRARY_PATH. libapp.so is never touched.
#
# A library that turns up in neither list is bundled and named in the output,
# so a new plugin's needs are visible in the build log, and the build fails
# until bundled_sources.txt beside this script names the Ubuntu source package
# it comes from. The distro copyright file of every bundled library goes into
# share/doc/kapynotes/third-party/.
#
# Some of what ships is GPL or LGPL: those libraries, libexec/ffmpeg, and the
# AppImage's runtime, which links libfuse statically. Every package's
# share/doc/kapynotes/SOURCE names each of them with its version, gives the
# app's source at the release tag, and points to one archive per arch,
#
#   KapyNotes-<version>-linux-<arch>-source.tar
#
# which holds their complete source and is published beside the packages.
# With SOURCE_ARCHIVE=1, which only the release workflow sets, this script
# writes that archive too, from the very package versions it bundled; apt
# then needs deb-src entries for the build machine's mirrors.
#
# Built on Ubuntu 22.04 (glibc 2.35), the oldest LTS Flutter 3.47 supports;
# the highest GLIBC_ symbol version any shipped ELF needs is printed at the
# end, and that is the floor for every host.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <bundle-dir> <version> <out-dir>" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="$(cd "$1" && pwd)"
VERSION="$2"
OUT="$3"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

APP_ID="com.kapybara.kapynotes"
BIN="kapynotes"
MAINTAINER="Kapybara LLC <hello@kapynotes.com>"
HOMEPAGE="https://kapynotes.com"
REPO="https://github.com/kapybara-org/kapynotes-app"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) DEBARCH=amd64 ;;
  aarch64) DEBARCH=arm64 ;;
  *) echo "error: unsupported arch $ARCH" >&2; exit 1 ;;
esac
SOURCE_NAME="KapyNotes-$VERSION-linux-$ARCH-source.tar"

FFMPEG_DIR="${FFMPEG_DIR:-$ROOT/build/linux/ffmpeg/$ARCH}"
# The FFmpeg release build_ffmpeg.sh pins, for the notices and the source.
eval "$(grep -E '^FFMPEG_(VERSION|SHA256|URL)=' "$HERE/build_ffmpeg.sh")"
TOOLS="$ROOT/build/linux/tools"
WORK="$ROOT/build/linux/package-$ARCH"

# The AppImage runtime is the static one, so the AppImage needs no libfuse2
# and starts on Ubuntu 24.04 and Fedora as installed. Both files are pinned
# by release and hash; the runtimes' signatures were checked against
# AppImage's type2-runtime signing key (570C 77AC EA40 C0F1 B758 902C BF96
# CCA5 6490 F695) when these hashes were taken.
RUNTIME_RELEASE="20251108"
APPIMAGETOOL_RELEASE="1.9.1"
# The runtime's source, as the source archive publishes it: the commit that
# release is tagged at, and the libfuse release its
# scripts/common/install-dependencies.sh builds and links in statically.
RUNTIME_COMMIT="dd6cebedcbddde9c82f89b011e8e1d40b6e43868"
LIBFUSE_VERSION="3.15.0"
LIBFUSE_SHA256="70589cfd5e1cff7ccd6ac91c86c01be340b227285c5e200baa284e401eea2ca0"
declare -A PIN=(
  [runtime-x86_64]="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"
  [runtime-aarch64]="00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444"
  [appimagetool-x86_64.AppImage]="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
  [appimagetool-aarch64.AppImage]="f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"
)
declare -A PIN_URL=(
  [runtime-x86_64]="https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_RELEASE/runtime-x86_64"
  [runtime-aarch64]="https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_RELEASE/runtime-aarch64"
  [appimagetool-x86_64.AppImage]="https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_RELEASE/appimagetool-x86_64.AppImage"
  [appimagetool-aarch64.AppImage]="https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_RELEASE/appimagetool-aarch64.AppImage"
)

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
die() { echo "error: $*" >&2; exit 1; }

is_elf() { [[ -f "$1" && ! -L "$1" && "$(head -c 4 "$1" | od -An -c | tr -d ' ')" == '177ELF' ]]; }

elfs_in() { find "$1" -type f | while read -r f; do if is_elf "$f"; then echo "$f"; fi; done | sort; }

needed() { objdump -p "$1" | awk '$1 == "NEEDED" { print $2 }'; }

is_host_lib() {
  case "$1" in
    ld-linux*|libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|libutil.so.*) return 0 ;;
    libstdc++.so.*|libgcc_s.so.*) return 0 ;;
    libglib-2.0.so.*|libgobject-2.0.so.*|libgio-2.0.so.*|libgmodule-2.0.so.*|libgthread-2.0.so.*) return 0 ;;
    libgtk-3.so.*|libgdk-3.so.*|libgdk_pixbuf-2.0.so.*) return 0 ;;
    libpango-1.0.so.*|libpangocairo-1.0.so.*|libpangoft2-1.0.so.*|libcairo.so.*|libcairo-gobject.so.*) return 0 ;;
    libharfbuzz.so.*|libatk-1.0.so.*|libatk-bridge-2.0.so.*|libatspi.so.*|libepoxy.so.*) return 0 ;;
    libfontconfig.so.*|libfreetype.so.*) return 0 ;;
    libX11.so.*|libX11-xcb.so.*|libxcb*.so.*|libXext.so.*|libXi.so.*|libXrandr.so.*|libXfixes.so.*) return 0 ;;
    libXcursor.so.*|libXinerama.so.*|libXcomposite.so.*|libXdamage.so.*|libXrender.so.*|libXau.so.*) return 0 ;;
    libxkbcommon*.so.*|libwayland-*.so.*) return 0 ;;
    libGL.so.*|libGLX.so.*|libOpenGL.so.*|libEGL.so.*|libGLESv2.so.*|libdrm.so.*|libgbm.so.*) return 0 ;;
    libpulse.so.*|libpulse-simple.so.*|libdbus-1.so.*) return 0 ;;
    libz.so.*|libgcrypt.so.*|libgpg-error.so.*) return 0 ;;
  esac
  return 1
}

fetch_pinned() {
  local name="$1" dest="$TOOLS/$1"
  mkdir -p "$TOOLS"
  if ! echo "${PIN[$name]}  $dest" | sha256sum -c --quiet >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$dest.part" "${PIN_URL[$name]}"
    echo "${PIN[$name]}  $dest.part" | sha256sum -c --quiet || die "$name does not match its pinned hash"
    mv "$dest.part" "$dest"
  fi
  chmod 0755 "$dest"
  echo "$dest"
}

# The machine-readable copyright file, for the .deb and the portable bundle
# alike; paths start with */ so they match under either root.
write_copyright() {
  local tree="$1" dest="$2" font family katex
  {
    cat <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Kapy Notes
Upstream-Contact: $MAINTAINER
Source: $REPO/tree/v$VERSION

Files: *
Copyright: 2026 Kapybara LLC
License: Apache-2.0
Comment: "Kapy Notes" and the Kapy mascot are trademarks of Kapybara LLC; the
 licence grants no rights to them. The Flutter engine (lib/libflutter_linux_gtk.so,
 data/icudtl.dat), the Dart packages compiled into lib/libapp.so and the native
 libraries in lib/ each keep their own licences, and all of their notices ship
 in data/flutter_assets/NOTICES.Z, which the app shows under Licenses.

Files: */libexec/ffmpeg */libexec/ffmpeg-LICENSE.md
Copyright: the FFmpeg developers
License: LGPL-2.1+
Comment: FFmpeg, built unmodified from the source archive and with the
 configure flags named in libexec/ffmpeg-LICENSE.md, by
 packaging/linux/build_ffmpeg.sh in the source repository above.
EOF
    for font in "$tree"/data/flutter_assets/assets/fonts/*-OFL.txt; do
      [[ -e "$font" ]] || continue
      family="${font##*/}"
      family="${family%-OFL.txt}"
      printf '\nFiles: */data/flutter_assets/assets/fonts/%s-*\nCopyright: %s\nLicense: OFL-1.1\n' \
        "$family" "$(grep -m1 '^Copyright' "$font" | sed 's/^Copyright //')"
    done
    katex="$(find "$tree/data/flutter_assets/packages/flutter_math_fork" -name LICENSE 2>/dev/null | head -1)"
    if [[ -n "$katex" ]]; then
      printf '\nFiles: */data/flutter_assets/packages/flutter_math_fork/*\nCopyright: %s\nLicense: Expat\n' \
        "$(grep -m1 'Copyright' "$katex" | sed 's/^Copyright (c) //; s/^Copyright //')"
    fi
    cat <<'EOF'

License: Apache-2.0
 Licensed under the Apache License, Version 2.0 (the "License"); you may not
 use this file except in compliance with the License. You may obtain a copy of
 the License at
 .
     http://www.apache.org/licenses/LICENSE-2.0
 .
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 License for the specific language governing permissions and limitations under
 the License.
 .
 On Debian systems, the complete text of the Apache License, Version 2.0 can
 be found in "/usr/share/common-licenses/Apache-2.0".

License: LGPL-2.1+
 This library is free software; you can redistribute it and/or modify it under
 the terms of the GNU Lesser General Public License as published by the Free
 Software Foundation; either version 2.1 of the License, or (at your option)
 any later version.
 .
 This library is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more
 details.
 .
 On Debian systems, the complete text of the GNU Lesser General Public License
 version 2.1 can be found in "/usr/share/common-licenses/LGPL-2.1". The full
 text also ships beside this file, in LGPL-2.1.
EOF
    if [[ -n "$katex" ]]; then
      printf '\nLicense: Expat\n'
      sed -n '/^Permission is hereby granted/,$p' "$katex" | sed 's/[[:space:]]*$//; s/^$/./; s/^/ /'
    fi
    font="$(find "$tree/data/flutter_assets/assets/fonts" -name '*-OFL.txt' 2>/dev/null | sort | head -1)"
    if [[ -n "$font" ]]; then
      printf '\nLicense: OFL-1.1\n'
      sed -n '/^SIL OPEN FONT LICENSE/,$p' "$font" | sed 's/[[:space:]]*$//; s/^$/./; s/^/ /'
    fi
  } >"$dest"
}

# SOURCE, and the GPL and LGPL texts beside it: what in the package is GPL or
# LGPL, at which version, and where its source is. A package that bundles a
# GPL-3 library says it is distributed as a whole under the GPL version 3,
# while the app's own code stays Apache-2.0. $1 is the file to write,
# $2 the package's file name, $3 the app's folder inside the package, and the
# rest are the bundled libraries, each "lib/<soname>|<source, version>|<licence>".
write_source_notice() {
  local dest="$1" package="$2" app="$3" entry path what licence gpl3=
  shift 3
  {
    cat <<EOF
Source code for $package

Kapy Notes' own code is licensed under the Apache License, Version 2.0. This
build is of the v$VERSION tag of its repository:

  $REPO/tree/v$VERSION

The package also contains the programs and libraries below, which are
licensed under the GNU General Public License (GPL) or the GNU Lesser General
Public License (LGPL). Their complete corresponding source, at the versions
built into this package and with the scripts and flags that built them, is
one archive published beside the package, at either of these addresses:

  https://dl.kapynotes.com/downloads/$SOURCE_NAME
  $REPO/releases/download/v$VERSION/$SOURCE_NAME

EOF
    for entry in "$@" "libexec/ffmpeg|FFmpeg $FFMPEG_VERSION|LGPL-2.1+"; do
      IFS='|' read -r path what licence <<<"$entry"
      printf '  %s%s\n      %s; %s\n' "$app" "$path" "$what" "$licence"
      if [[ "$licence" == GPL-3* ]]; then gpl3=1; fi
    done
    if [[ "$package" == *.AppImage ]]; then
      printf '  the runtime at the start of the AppImage\n      %s; %s\n' \
        "AppImage's type2-runtime $RUNTIME_RELEASE, which links libfuse $LIBFUSE_VERSION statically" \
        "MIT, and LGPL-2.1 for libfuse"
    fi
    if [[ -n "$gpl3" ]]; then
      cat <<'EOF'

Because of the libraries above marked GPL-3, the tar.gz, the AppImage and the
Flatpak made from the tar.gz are each distributed, as a whole, under the terms
of the GNU GPL version 3. Kapy Notes' own code stays licensed under the Apache
License, Version 2.0. The tag above pins the rest of the whole's source: its
pubspec.lock the Dart packages compiled into lib/libapp.so, and its release
workflow the Flutter version whose engine is lib/libflutter_linux_gtk.so.
EOF
    fi
    cat <<'EOF'

The GNU GPL version 3 and the GNU LGPL versions 2.1 and 3 are in GPL-3,
LGPL-2.1 and LGPL-3 beside this file.
EOF
  } >"$dest"
  cp /usr/share/common-licenses/{GPL-3,LGPL-2.1,LGPL-3} "$(dirname "$dest")/"
}

# ---------------------------------------------------------------------------

[[ -x "$BUNDLE/$BIN" ]] || die "$BUNDLE/$BIN missing; is this a Flutter Linux bundle?"
[[ -f "$BUNDLE/lib/libapp.so" ]] || die "$BUNDLE/lib/libapp.so missing; build with --release"
[[ -f "$BUNDLE/share/applications/$APP_ID.desktop" ]] || die "$BUNDLE/share/applications/$APP_ID.desktop missing"
[[ -f "$BUNDLE/share/metainfo/$APP_ID.metainfo.xml" ]] || die "$BUNDLE/share/metainfo/$APP_ID.metainfo.xml missing"
[[ -f "$BUNDLE/share/icons/hicolor/256x256/apps/$APP_ID.png" ]] || die "the 256 px icon is missing from $BUNDLE/share"
[[ ! -e "$BUNDLE/lib/libdartjni.so" ]] || die "$BUNDLE/lib/libdartjni.so is Android-only (it links libjvm.so) and must not ship"
[[ -x "$FFMPEG_DIR/ffmpeg" ]] || die "$FFMPEG_DIR/ffmpeg missing; run packaging/linux/build_ffmpeg.sh"
# The notices name the FFmpeg release build_ffmpeg.sh pins, so the binary has
# to be the one that script built.
[[ "$(cat "$FFMPEG_DIR/stamp" 2>/dev/null)" == "$(sha256sum "$HERE/build_ffmpeg.sh" | cut -d' ' -f1)" ]] ||
  die "$FFMPEG_DIR/ffmpeg was not built by the current build_ffmpeg.sh; run packaging/linux/build_ffmpeg.sh"
# An ELF that calls into glibc's private ABI ties the .deb to one exact glibc
# release, which dpkg-shlibdeps then writes into Depends, and can stop loading
# on any other.
while read -r elf; do
  [[ "$(objdump -T "$elf" 2>/dev/null | grep -c GLIBC_PRIVATE || true)" == 0 ]] ||
    die "${elf#"$BUNDLE"/} uses glibc's private ABI (GLIBC_PRIVATE) and must not ship"
done < <(find "$BUNDLE/$BIN" "$BUNDLE/lib" "$FFMPEG_DIR/ffmpeg" -type f)

rm -rf "$WORK"
mkdir -p "$WORK"

info "Staging the bundle with its libexec helpers"
PLAIN="$WORK/plain"
cp -a "$BUNDLE" "$PLAIN"
mkdir -p "$PLAIN/libexec"
install -m 0755 "$FFMPEG_DIR/ffmpeg" "$PLAIN/libexec/ffmpeg"
install -m 0644 "$FFMPEG_DIR/ffmpeg-LICENSE.md" "$PLAIN/libexec/ffmpeg-LICENSE.md"
# Debug information has no business in a download. The Dart snapshot's is
# already split out by --split-debug-info, and stripping it would break it.
while read -r elf; do
  [[ "${elf##*/}" == libapp.so ]] && continue
  if objdump -h "$elf" | grep -q '\.debug_'; then
    strip --strip-unneeded "$elf"
  fi
done < <(elfs_in "$PLAIN")
# Flutter installs plugin libraries as plain files, so they keep the RUNPATH
# of the build tree (.../linux/flutter/ephemeral): on a user's machine the
# loader would search a path that does not exist, or one someone else
# created. Every library in lib/ looks only beside itself instead.
while read -r elf; do
  [[ "${elf##*/}" == libapp.so ]] && continue
  rpath="$(patchelf --print-rpath "$elf")"
  [[ -z "$rpath" || "$rpath" == "\$ORIGIN" ]] && continue
  # shellcheck disable=SC2016 # a literal $ORIGIN, for the dynamic loader
  patchelf --set-rpath '$ORIGIN' "$elf"
done < <(elfs_in "$PLAIN/lib")
find "$PLAIN" -type d -exec chmod 0755 {} +
find "$PLAIN" -type f -exec chmod 0644 {} +
chmod 0755 "$PLAIN/$BIN" "$PLAIN/libexec/ffmpeg"

# ---------------------------------------------------------------------------

info "Building the portable bundle"
PORTABLE_ROOT="$WORK/portable"
PORTABLE="$PORTABLE_ROOT/kapynotes"
mkdir -p "$PORTABLE_ROOT"
cp -a "$PLAIN" "$PORTABLE"
DOC="$PORTABLE/share/doc/kapynotes"
mkdir -p "$DOC/third-party"

declare -A seen=() debsrc=()
queue=()
while read -r elf; do queue+=("$elf"); done < <(elfs_in "$PORTABLE")
bundled=()
bundled_notice=()
while ((${#queue[@]})); do
  elf="${queue[0]}"
  queue=("${queue[@]:1}")
  resolved="$(ldd "$elf" 2>/dev/null || true)"
  while read -r soname; do
    [[ -n "$soname" && -z "${seen[$soname]:-}" ]] || continue
    seen[$soname]=1
    [[ -e "$PORTABLE/lib/$soname" ]] && continue
    is_host_lib "$soname" && continue
    path="$(awk -v s="$soname" '$1 == s && $3 ~ /^\// { print $3; exit }' <<<"$resolved")"
    [[ -n "$path" ]] || die "$elf needs $soname, which this build machine cannot resolve"
    real="$(readlink -f "$path")"
    install -m 0644 "$real" "$PORTABLE/lib/$soname"
    bundled+=("$soname")
    queue+=("$PORTABLE/lib/$soname")
    pkg="$(dpkg -S "$real" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    [[ -n "$pkg" ]] || pkg="$(dpkg -S "$path" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    [[ -n "$pkg" && -f "/usr/share/doc/$pkg/copyright" ]] || die "no copyright file found for $soname ($real)"
    cp "/usr/share/doc/$pkg/copyright" "$DOC/third-party/$pkg.copyright"
    entry="$(awk -v s="$soname" '$1 == s { print; exit }' "$HERE/bundled_sources.txt")"
    [[ -n "$entry" ]] ||
      die "$soname (from $pkg) would be bundled, but packaging/linux/bundled_sources.txt has no line for it; a release publishes the source of everything it bundles, so add one"
    read -r _ src licence <<<"$entry"
    # shellcheck disable=SC2016 # dpkg-query's own field names
    read -r built_from src_version <<<"$(dpkg-query -W -f='${source:Package} ${source:Version}' "$pkg:$DEBARCH")"
    [[ "$built_from" == "$src" ]] ||
      die "bundled_sources.txt says $soname is built from $src, but $pkg:$DEBARCH is built from '$built_from'"
    debsrc["$src=$src_version"]=1
    bundled_notice+=("lib/$soname|Ubuntu's $src $src_version|$licence")
    echo "  bundled $soname from $pkg, source $src $src_version"
  done < <(needed "$elf")
done

# RUNPATH $ORIGIN on every library in lib/ that needs another one there.
while read -r elf; do
  [[ "${elf##*/}" == libapp.so ]] && continue
  local_need=
  while read -r soname; do
    if [[ -e "$PORTABLE/lib/$soname" ]]; then local_need=1; fi
  done < <(needed "$elf")
  [[ -n "$local_need" ]] || continue
  # shellcheck disable=SC2016 # a literal $ORIGIN, for the dynamic loader
  patchelf --set-rpath '$ORIGIN' "$elf"
done < <(elfs_in "$PORTABLE/lib")

missing="$(elfs_in "$PORTABLE" | while read -r elf; do ldd "$elf" 2>&1 | grep 'not found' | sed "s|^|${elf#"$PORTABLE"/}: |"; done || true)"
[[ -z "$missing" ]] || die "unresolved libraries in the portable bundle:"$'\n'"$missing"

write_copyright "$PORTABLE" "$DOC/copyright"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$DOC/"
write_source_notice "$DOC/SOURCE" "KapyNotes-$VERSION-linux-$ARCH.tar.gz" kapynotes/ "${bundled_notice[@]}"
find "$PORTABLE" -type d -exec chmod 0755 {} +
find "$DOC" -type f -exec chmod 0644 {} +

TARBALL="$OUT/KapyNotes-$VERSION-linux-$ARCH.tar.gz"
rm -f "$TARBALL"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$PORTABLE_ROOT" -cf - kapynotes | gzip -9n >"$TARBALL"
echo "  → $TARBALL"

# ---------------------------------------------------------------------------

info "Building the .deb"
# The debhelper layout, so dpkg-shlibdeps treats the private libraries in
# /usr/lib/kapynotes/lib as part of the package being built.
DEBROOT="$WORK/deb"
PKG="$DEBROOT/debian/kapynotes"
mkdir -p "$PKG/usr/lib" "$PKG/usr/bin" "$PKG/usr/share/doc/kapynotes" "$PKG/DEBIAN"
cp -a "$PLAIN" "$PKG/usr/lib/kapynotes"
cp -a "$PKG/usr/lib/kapynotes/share/." "$PKG/usr/share/"
rm -rf "$PKG/usr/lib/kapynotes/share"
# The bundle keeps its own share/ path, so the runner finds its icon the same
# way in every package.
ln -s ../../share "$PKG/usr/lib/kapynotes/share"
ln -s ../lib/kapynotes/$BIN "$PKG/usr/bin/$BIN"
write_copyright "$PKG/usr/lib/kapynotes" "$PKG/usr/share/doc/kapynotes/copyright"
write_source_notice "$PKG/usr/share/doc/kapynotes/SOURCE" "KapyNotes-$VERSION-$DEBARCH.deb" /usr/lib/kapynotes/
{
  echo "kapynotes ($VERSION) unstable; urgency=medium"
  echo
  echo "  * Kapy Notes $VERSION. Release notes: $HOMEPAGE"
  echo
  echo " -- $MAINTAINER  $(date -R -u -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}")"
} | gzip -9n >"$PKG/usr/share/doc/kapynotes/changelog.gz"
find "$PKG" -type d -exec chmod 0755 {} +
chmod 0644 "$PKG/usr/share/doc/kapynotes/"*

printf 'Source: kapynotes\n\nPackage: kapynotes\nArchitecture: %s\n' "$DEBARCH" >"$DEBROOT/debian/control"
mapfile -t deb_elfs < <(elfs_in "$PKG")
depends="$(cd "$DEBROOT" && dpkg-shlibdeps -O -l"$PKG/usr/lib/kapynotes/lib" "${deb_elfs[@]}" 2>"$WORK/shlibdeps.log" |
  sed -n 's/^shlibs:Depends=//p')" || { cat "$WORK/shlibdeps.log" >&2; die "dpkg-shlibdeps failed"; }
grep -v 'is not used by any binary\|was not linked against\|could avoid a useless dependency' "$WORK/shlibdeps.log" >&2 || true
[[ -n "$depends" ]] || die "dpkg-shlibdeps produced no Depends"
# The tray plugin links libayatana-appindicator3 at build time, and the
# loader will not start the app without it, so that dependency stays a
# Depends. dpkg-shlibdeps also lists libayatana-ido3 and
# libayatana-indicator3 because the plugin's link line pulls them in; the
# appindicator package depends on them too. Do not move any of the three to
# Recommends.
#
# gnome-keyring is what provides the keyring on Debian 13, including on KDE:
# kwallet6 6.13 does not. libpam-gnome-keyring starts the daemon at login.
# Installing either package is not enough if the daemon is not running.
# GTK and the Flutter engine draw through libepoxy, which dlopens libGL (GTK's
# GLX context on X11), libEGL and libGLESv2 (the engine's own context) instead
# of linking them, so dpkg-shlibdeps sees none of the three.
for lib in libgl1 libegl1 libgles2; do
  re=", $lib( |,)"
  [[ ", $depends," =~ $re ]] || depends="$depends, $lib"
done

cat >"$PKG/DEBIAN/control" <<EOF
Package: kapynotes
Version: $VERSION
Architecture: $DEBARCH
Maintainer: $MAINTAINER
Installed-Size: $(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
Depends: $depends
Recommends: gnome-keyring, libpam-gnome-keyring
Section: editors
Priority: optional
Homepage: $HOMEPAGE
Description: notes where every line is a live calculator
 Kapy Notes is a fast, private notebook with a calculator built into every
 line. Type a calculation and the result appears beside it: arithmetic,
 percentages, running totals, units, time and currencies.
 .
 Notes are Markdown with checklists, tags, tables, drawings and voice notes
 transcribed on the device. They stay on this computer and work offline;
 sync between devices is optional and end-to-end encrypted.
 .
 Staying signed in needs a keyring running on this computer, GNOME Keyring
 or KWallet. Without one, sign-in lasts until you quit.
EOF
(cd "$PKG" && find usr -type f -print0 | sort -z | xargs -0 md5sum) >"$PKG/DEBIAN/md5sums"
chmod 0644 "$PKG/DEBIAN/control" "$PKG/DEBIAN/md5sums"

DEB="$OUT/KapyNotes-$VERSION-$DEBARCH.deb"
rm -f "$DEB"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB" >/dev/null
echo "  Depends: $depends"
echo "  → $DEB"

# ---------------------------------------------------------------------------

info "Building the AppImage"
APPDIR="$WORK/AppDir"
mkdir -p "$APPDIR/usr/lib"
cp -a "$PORTABLE" "$APPDIR/usr/lib/kapynotes"
cp -a "$APPDIR/usr/lib/kapynotes/share" "$APPDIR/usr/share"
rm -rf "$APPDIR/usr/lib/kapynotes/share"
ln -s ../../share "$APPDIR/usr/lib/kapynotes/share"
# A symlink, not a script: the binary finds data/, lib/ and libexec/ through
# /proc/self/exe, which resolves to the real file inside the mount.
ln -s usr/lib/kapynotes/$BIN "$APPDIR/AppRun"
cp "$APPDIR/usr/share/applications/$APP_ID.desktop" "$APPDIR/$APP_ID.desktop"
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_ID.png" "$APPDIR/$APP_ID.png"
ln -s "$APP_ID.png" "$APPDIR/.DirIcon"
write_source_notice "$APPDIR/usr/share/doc/kapynotes/SOURCE" "KapyNotes-$VERSION-$ARCH.AppImage" usr/lib/kapynotes/ "${bundled_notice[@]}"

runtime="$(fetch_pinned "runtime-$ARCH")"
appimagetool="$(fetch_pinned "appimagetool-$ARCH.AppImage")"
APPIMAGE="$OUT/KapyNotes-$VERSION-$ARCH.AppImage"
rm -f "$APPIMAGE"
# Build machines and containers often have no FUSE, and the tool is an
# AppImage itself, so it unpacks instead of mounting. The metainfo is
# validated by CI with appstreamcli, so the tool need not do it again.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" VERSION="$VERSION" \
  "$appimagetool" --no-appstream --runtime-file "$runtime" "$APPDIR" "$APPIMAGE" >"$WORK/appimagetool.log" 2>&1 ||
  { cat "$WORK/appimagetool.log" >&2; die "appimagetool failed"; }
chmod 0755 "$APPIMAGE"
echo "  → $APPIMAGE"

# ---------------------------------------------------------------------------

if [[ "${SOURCE_ARCHIVE:-}" == 1 ]]; then
  info "Collecting the source of the GPL and LGPL parts"
  SRC="$WORK/source/${SOURCE_NAME%.tar}"
  mkdir -p "$SRC/ubuntu" "$SRC/ffmpeg" "$SRC/appimage-runtime"
  # apt checks every file against the signed Sources index.
  for spec in $(printf '%s\n' "${!debsrc[@]}" | sort); do
    (cd "$SRC/ubuntu" && apt-get -qq source --download-only "$spec") ||
      die "apt-get could not fetch the source of $spec; it needs deb-src entries for the mirrors the build machine installed from"
  done
  curl -fsSL --retry 3 -o "$SRC/ffmpeg/${FFMPEG_URL##*/}" "$FFMPEG_URL"
  echo "$FFMPEG_SHA256  $SRC/ffmpeg/${FFMPEG_URL##*/}" | sha256sum -c --quiet || die "the FFmpeg archive does not match its pinned hash"
  cp "$HERE/build_ffmpeg.sh" "$FFMPEG_DIR/ffmpeg-LICENSE.md" "$SRC/ffmpeg/"
  git init -q "$WORK/type2-runtime"
  git -C "$WORK/type2-runtime" fetch -q --depth 1 https://github.com/AppImage/type2-runtime "$RUNTIME_COMMIT"
  [[ "$(git -C "$WORK/type2-runtime" rev-parse FETCH_HEAD)" == "$RUNTIME_COMMIT" ]] || die "fetched the wrong type2-runtime commit"
  git -C "$WORK/type2-runtime" show FETCH_HEAD:scripts/common/install-dependencies.sh | grep -q "$LIBFUSE_SHA256" ||
    die "type2-runtime $RUNTIME_RELEASE does not build with libfuse $LIBFUSE_VERSION; pin the libfuse its scripts/common/install-dependencies.sh fetches"
  git -C "$WORK/type2-runtime" archive --prefix="type2-runtime-$RUNTIME_RELEASE/" FETCH_HEAD |
    gzip -9n >"$SRC/appimage-runtime/type2-runtime-$RUNTIME_RELEASE.tar.gz"
  curl -fsSL --retry 3 -o "$SRC/appimage-runtime/fuse-$LIBFUSE_VERSION.tar.xz" \
    "https://github.com/libfuse/libfuse/releases/download/fuse-$LIBFUSE_VERSION/fuse-$LIBFUSE_VERSION.tar.xz"
  echo "$LIBFUSE_SHA256  $SRC/appimage-runtime/fuse-$LIBFUSE_VERSION.tar.xz" | sha256sum -c --quiet || die "the libfuse archive does not match its pinned hash"
  cat >"$SRC/README" <<EOF
The complete corresponding source of the GPL- and LGPL-licensed parts of
KapyNotes-$VERSION-linux-$ARCH.tar.gz, KapyNotes-$VERSION-$DEBARCH.deb and
KapyNotes-$VERSION-$ARCH.AppImage. The share/doc/kapynotes/SOURCE file in
each package lists those parts. Kapy Notes itself is the v$VERSION tag of
$REPO.

ubuntu/
  The Ubuntu source packages of the libraries the tar.gz and the AppImage
  carry in lib/, at the versions they carry. \`dpkg-source -x\` on a .dsc
  unpacks one, and its debian/rules builds it.

ffmpeg/
  ${FFMPEG_URL##*/}, the FFmpeg release libexec/ffmpeg is built from;
  build_ffmpeg.sh, the script that built it, which holds every configure
  flag; and ffmpeg-LICENSE.md, which ships beside the program.

appimage-runtime/
  type2-runtime-$RUNTIME_RELEASE.tar.gz, AppImage's type2-runtime at commit
  $RUNTIME_COMMIT, from which its release
  $RUNTIME_RELEASE, the runtime the AppImage starts with, was built by
  scripts/chroot/chroot_build.sh; and fuse-$LIBFUSE_VERSION.tar.xz, the libfuse
  that runtime links statically, with the runtime's
  patches/libfuse/mount.c.diff applied.
EOF
  rm -f "$OUT/$SOURCE_NAME"
  tar --sort=name --owner=0 --group=0 --numeric-owner -C "$WORK/source" -cf "$OUT/$SOURCE_NAME" "${SOURCE_NAME%.tar}"
  tar -tvf "$OUT/$SOURCE_NAME" | sed 's/^/  /'
  echo "  → $OUT/$SOURCE_NAME"
fi

# ---------------------------------------------------------------------------

info "Shipped ELFs: highest GLIBC symbol version needed, and size"
floor="0"
while read -r elf; do
  v="$(objdump -T "$elf" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)"
  printf '  %-6s %6s  %s\n' "${v:--}" "$(du -h "$elf" | cut -f1)" "${elf#"$PORTABLE"/}"
  [[ -z "$v" ]] || floor="$(printf '%s\n%s\n' "$floor" "$v" | sort -V | tail -1)"
done < <(elfs_in "$PORTABLE")
echo "  glibc floor: $floor"
echo "  bundled in the portable packages: ${bundled[*]:-none}"

rm -rf "$WORK"
