#!/usr/bin/env bash
#
# Builds the ffmpeg that Linux packages ship in libexec/, for the host arch:
#
#   build/linux/ffmpeg/<arch>/ffmpeg               the program
#   build/linux/ffmpeg/<arch>/ffmpeg-LICENSE.md    its licence, source and flags
#
# Why ship one: on Linux, voice notes record, play back and decode for the
# speech model through ffmpeg talking to PulseAudio (lib/audio/linux_*.dart).
# A stock desktop has no ffmpeg installed, and a distro ffmpeg may lack the
# AAC encoder or be GPL-licensed.
#
# What it is: LGPL-2.1-or-later only (no --enable-gpl, no --enable-nonfree),
# ffmpeg's own libraries linked statically, and nothing dynamic but glibc and
# libpulse.so.0, which every PulseAudio or PipeWire desktop has. Only the
# pieces those commands use are enabled:
#
#   capture  ffmpeg -f pulse -sample_rate R -channels C -i default -c:a copy -f s16le pipe:1
#   record   ffmpeg -f s16le -ar R -ac C -i pipe:0 -c:a aac -b:a B -f ipod out.m4a
#   read     ffmpeg -ss S -i in.m4a -map 0:a:0 -af atempo=X -ac 1 -ar 48000 -f s16le pipe:1
#   play     ffmpeg -f s16le -ar 48000 -ac 1 -i pipe:0 -f pulse -buffer_duration 200 "Voice note"
#   decode   ffmpeg -i in.m4a -map 0:a:0 -ac 1 -ar 16000 -c:a pcm_s16le -f s16le out.pcm
#
# The smoke test's check also feeds the encoder from `-`, which is the fd
# protocol below.
#
# Change a flag below and the cache key changes with it: CI keys its cache on
# this file's hash, and a local run rebuilds when the stamp beside the binary
# no longer matches.
#
# Needs a C toolchain, make, pkg-config, xz and libpulse-dev.

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
SCRIPT="$ROOT/packaging/linux/build_ffmpeg.sh"

FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

ARCH="$(uname -m)"
OUT="$ROOT/build/linux/ffmpeg/$ARCH"
WORK="$ROOT/build/linux/ffmpeg/work-$ARCH"
JOBS="${JOBS:-$(nproc)}"
STAMP="$(sha256sum "$SCRIPT" | cut -d' ' -f1)"

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

# Runs every command the app and record_linux use, on generated audio. The
# pulse ones need a PulseAudio server, which a build machine does not have, so
# they are left to packaging/linux/smoke_test.sh and to a desktop.
self_test() {
  local ffmpeg="$1" dir
  dir="$(mktemp -d)"
  # Two seconds of a 440 Hz tone, 48 kHz mono s16le, without lavfi sources.
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 96000; i++) { v = int(8000 * sin(2 * 3.14159265 * 440 * i / 48000)); if (v < 0) v += 65536; printf "%c%c", v % 256, int(v / 256) } }' \
    >"$dir/tone.pcm"
  "$ffmpeg" -nostdin -v error -f s16le -ar 48000 -ac 1 -i - -c:a aac -b:a 48k "$dir/note.m4a" <"$dir/tone.pcm"
  "$ffmpeg" -nostdin -v error -i "$dir/note.m4a" -ac 1 -ar 16000 -f s16le "$dir/speech.pcm"
  "$ffmpeg" -nostdin -v error -ss 0.5 -i "$dir/note.m4a" -af atempo=1.5 -f wav "$dir/fast.wav"
  "$ffmpeg" -nostdin -v error -f s16le -ar 16000 -ac 1 -i - -c:a pcm_s16le -f wav "$dir/note.wav" <"$dir/speech.pcm"
  "$ffmpeg" -nostdin -v error -i "$dir/note.wav" -f s16le - | cmp -s - "$dir/speech.pcm" ||
    { echo "error: WAV round trip changed the samples" >&2; exit 1; }
  local speech_bytes
  speech_bytes="$(stat -c%s "$dir/speech.pcm")"
  # 2 s at 16 kHz mono s16le is 64000 bytes; AAC priming may add a frame.
  if (( speech_bytes < 60000 || speech_bytes > 70000 )); then
    echo "error: decoded $speech_bytes bytes, expected about 64000" >&2
    exit 1
  fi
  head -c 4 "$dir/fast.wav" | grep -q RIFF
  "$ffmpeg" -hide_banner -L 2>/dev/null | grep -q 'GNU Lesser General Public' ||
    { echo "error: $ffmpeg is not LGPL" >&2; exit 1; }
  local devices
  devices="$("$ffmpeg" -hide_banner -devices 2>/dev/null)"
  if ! grep -qE '^ *DE? +pulse ' <<<"$devices" || ! grep -qE '^ *D?E +pulse ' <<<"$devices"; then
    echo "error: $ffmpeg lacks the pulse input or output device" >&2
    exit 1
  fi
  local needed
  needed="$(objdump -p "$ffmpeg" | awk '/NEEDED/ { print $2 }' | sort | tr '\n' ' ')"
  for lib in $needed; do
    case "$lib" in
      libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|libpulse.so.0|ld-linux*) ;;
      *) echo "error: $ffmpeg links $lib; only glibc and libpulse are allowed" >&2; exit 1 ;;
    esac
  done
  rm -rf "$dir"
  echo "  self-test passed; links: $needed"
}

if [[ -x "$OUT/ffmpeg" && "$(cat "$OUT/stamp" 2>/dev/null)" == "$STAMP" ]]; then
  info "ffmpeg $FFMPEG_VERSION ($ARCH) is up to date"
  self_test "$OUT/ffmpeg"
  exit 0
fi

info "Building ffmpeg $FFMPEG_VERSION for $ARCH"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/download" "$OUT"
curl -fsSL --retry 3 -o "$WORK/download/ffmpeg.tar.xz" "$FFMPEG_URL"
echo "$FFMPEG_SHA256  $WORK/download/ffmpeg.tar.xz" | sha256sum -c --quiet
tar -xJf "$WORK/download/ffmpeg.tar.xz" -C "$WORK"
src="$WORK/ffmpeg-$FFMPEG_VERSION"

# The components the commands above use, by configure's names, which are not
# always the names -f takes: raw s16le is the pcm_s16le demuxer and muxer,
# .m4a is written by the ipod muxer, and the ffmpeg program opens an input of
# `-` with the fd protocol but an output of `-` with pipe (fftools/
# ffmpeg_demux.c and ffmpeg_mux_init.c in 9.0.2). `./configure --list-demuxers`
# (and --list-muxers, --list-filters, ...) shows the names. Add to these lists when
# the app starts using another piece of ffmpeg.
protocols=(file pipe fd)
demuxers=(pcm_s16le mov wav)
muxers=(ipod mp4 mov pcm_s16le wav)
decoders=(aac pcm_s16le)
encoders=(aac pcm_s16le)
parsers=(aac)
filters=(aresample aformat anull atempo atrim volume)

list() { local IFS=,; echo "$*"; }

# --disable-autodetect keeps out every library configure would otherwise pick
# up from the build machine (X11, ALSA, zlib, iconv, VA-API, ...), so the
# result links the same on any runner. --toolchain=hardened adds PIE,
# stack protector, FORTIFY_SOURCE and full RELRO. x86 assembly would need
# nasm and buys nothing measurable for speech-sized audio.
config=(
  --disable-everything
  --disable-autodetect
  --disable-doc
  --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --disable-network
  --disable-debug
  --disable-programs
  --enable-ffmpeg
  --disable-shared
  --enable-static
  --disable-swscale
  --disable-x86asm
  --enable-small
  --toolchain=hardened
  --enable-libpulse
  --enable-indev=pulse
  --enable-outdev=pulse
  --enable-protocol="$(list "${protocols[@]}")"
  --enable-demuxer="$(list "${demuxers[@]}")"
  --enable-muxer="$(list "${muxers[@]}")"
  --enable-decoder="$(list "${decoders[@]}")"
  --enable-encoder="$(list "${encoders[@]}")"
  --enable-parser="$(list "${parsers[@]}")"
  --enable-filter="$(list "${filters[@]}")"
)

(
  cd "$src"
  ./configure --prefix="$WORK/prefix" "${config[@]}"
  make -j"$JOBS"
  make install
)
install -m 0755 "$WORK/prefix/bin/ffmpeg" "$OUT/ffmpeg"
strip --strip-unneeded "$OUT/ffmpeg"

{
  echo "# ffmpeg $FFMPEG_VERSION"
  echo
  echo "The \`ffmpeg\` program in this directory is FFmpeg $FFMPEG_VERSION, licensed under"
  echo "the GNU Lesser General Public License, version 2.1 or later. It runs as a"
  echo "separate program; Kapy Notes does not link against it."
  echo
  echo "- Source: $FFMPEG_URL"
  echo "- SHA-256 of that archive: $FFMPEG_SHA256"
  echo "- Built by packaging/linux/build_ffmpeg.sh in"
  echo "  https://github.com/kapybara-org/kapynotes-app with:"
  echo
  echo '  ```'
  echo "  ./configure ${config[*]}"
  echo '  ```'
  echo
  echo "To use a different build, replace this file's \`ffmpeg\` with any ffmpeg that"
  echo "has the AAC encoder and the PulseAudio devices."
  echo
  cat "$src/LICENSE.md"
  echo
  echo "## GNU Lesser General Public License, version 2.1"
  echo
  cat "$src/COPYING.LGPLv2.1"
} >"$OUT/ffmpeg-LICENSE.md"

self_test "$OUT/ffmpeg"
echo "$STAMP" >"$OUT/stamp"
rm -rf "$WORK"
echo "  → $OUT/ffmpeg ($(du -h "$OUT/ffmpeg" | cut -f1))"
