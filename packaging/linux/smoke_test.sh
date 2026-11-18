#!/usr/bin/env bash
#
# Starts a built Linux package on a bare machine and checks it comes up.
#
#   smoke_test.sh baseline                      install the desktop baseline
#   smoke_test.sh deb      <file.deb>      <out-dir>
#   smoke_test.sh tar      <file.tar.gz>   <out-dir>
#   smoke_test.sh appimage <file.AppImage> <out-dir>
#   smoke_test.sh all      <dist-dir>      <out-dir>   every package found,
#                                                      .deb only where apt is
#
# CI runs it as root in clean ubuntu:22.04, ubuntu:24.04, debian:12 and
# fedora containers (desktop-ci.yml, linux-smoke). It runs the same on any
# machine with the baseline, so a failure there reproduces locally with
#
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash -c \
#     'packaging/linux/smoke_test.sh baseline &&
#      packaging/linux/smoke_test.sh all build/release smoke-out'
#
# "baseline" installs only what every GNOME or KDE desktop has (GTK 3,
# libpulse, Mesa's GL and GLES, a font, Python) plus the test's own tools
# (Xvfb, D-Bus, xwininfo, xwd), and never the libraries the portable packages
# bundle, so a missing one shows up. The .deb is installed with apt and without
# Recommends, which proves its Depends alone are enough.
#
# Each run gets a fresh HOME, its own Xvfb and its own session bus (started
# directly rather than through xvfb-run and dbus-run-session, so the app's own
# process can be signalled), then must:
#   - still be running after SMOKE_SECONDS (20),
#   - have a top-level X window whose WM_CLASS is com.kapybara.kapynotes,
#   - leave no "not found" from ldd for any ELF it ships,
#   - run its libexec/ffmpeg, which voice notes depend on,
#   - log no MissingPluginException, no "not found" and no library that failed
#     to load,
#   - exit 0 within 5 seconds of being asked to quit, half the runner's own
#     deadline, so an app that never answered does not pass: the tarball by
#     closing its window, the way a user does, the others by SIGTERM, the way
#     a logout or `kill` does.
# A screenshot of the screen goes to <out-dir>/<kind>.xwd (and .png when
# ImageMagick is there), the app's output to <out-dir>/<kind>.log.
#
# An AppImage runs with APPIMAGE_EXTRACT_AND_RUN=1, because containers have
# no /dev/fuse; set SMOKE_FUSE=1 to mount it for real instead, as CI does on
# an ubuntu-24.04 host with no libfuse2.

set -euo pipefail

APP_ID="com.kapybara.kapynotes"
SMOKE_SECONDS="${SMOKE_SECONDS:-20}"
display_number=90

# What a run started, so a failure partway does not leave an app, an Xvfb and
# a bus running on the machine.
started=()
cleanup() { if ((${#started[@]})); then kill -KILL "${started[@]}" 2>/dev/null || true; fi; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

install_baseline() {
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends \
      ca-certificates libgtk-3-0 libpulse0 libegl1 libgl1 libgles2 libgl1-mesa-dri fonts-dejavu-core \
      python3 xvfb xauth x11-utils x11-apps dbus
  elif command -v dnf >/dev/null; then
    dnf -y -q install --setopt=install_weak_deps=False \
      gtk3 pulseaudio-libs mesa-dri-drivers mesa-libEGL mesa-libGL libglvnd-gles dejavu-sans-fonts python3 \
      xorg-x11-server-Xvfb /usr/bin/xwininfo /usr/bin/xwd /usr/bin/dbus-daemon /usr/bin/ldd findutils
  else
    fail "no apt-get or dnf here"
  fi
}

is_elf() { [[ -f "$1" && ! -L "$1" && "$(head -c 4 "$1" | od -An -c | tr -d ' ')" == '177ELF' ]]; }

check_libraries() {
  local root="$1" bad=
  while read -r f; do
    if is_elf "$f" && ldd "$f" 2>&1 | grep -q 'not found'; then
      echo "  ${f#"$root"/}:" >&2
      ldd "$f" 2>&1 | grep 'not found' | sed 's/^/    /' >&2
      bad=1
    fi
  done < <(find "$root" -type f)
  [[ -z "$bad" ]] || fail "libraries missing for ELFs under $root"
  echo "  every shipped ELF resolves its libraries"
}

check_ffmpeg() {
  local libexec="$1/libexec" tmp
  tmp="$(mktemp -d)"
  head -c 96000 /dev/zero |
    "$libexec/ffmpeg" -nostdin -v error -f s16le -ar 48000 -ac 1 -i - -c:a aac -b:a 48k "$tmp/note.m4a" ||
    fail "libexec/ffmpeg could not encode a voice note"
  "$libexec/ffmpeg" -nostdin -v error -i "$tmp/note.m4a" -ac 1 -ar 16000 -f s16le "$tmp/speech.pcm" ||
    fail "libexec/ffmpeg could not decode a voice note"
  rm -rf "$tmp"
  echo "  libexec/ffmpeg encodes and decodes"
}

# Closes the app's window the way a window manager's close button does, with a
# WM_DELETE_WINDOW message. Only the mapped window: GDK gives its unmapped
# client-leader window the app's WM_CLASS too.
close_window() {
  local display="$1" tree="$2" id
  for id in $(grep -F "\"$APP_ID\")" <<<"$tree" | awk '{print $1}'); do
    [[ "$(DISPLAY="$display" xwininfo -id "$id")" == *IsViewable* ]] || continue
    DISPLAY="$display" python3 - "$id" <<'PY'
import ctypes
import sys


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("message_type", ctypes.c_ulong),
        ("format", ctypes.c_int),
        ("data", ctypes.c_long * 5),
    ]


class XEvent(ctypes.Union):
    _fields_ = [("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]


x11 = ctypes.CDLL("libX11.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XInternAtom.restype = ctypes.c_ulong
x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x11.XSendEvent.argtypes = [
    ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long,
    ctypes.POINTER(XEvent),
]
x11.XFlush.argtypes = [ctypes.c_void_p]

display = x11.XOpenDisplay(None)
if not display:
    sys.exit("cannot open the display")
window = int(sys.argv[1], 16)
event = XEvent()
event.xclient.type = 33  # ClientMessage
event.xclient.window = window
event.xclient.message_type = x11.XInternAtom(display, b"WM_PROTOCOLS", 0)
event.xclient.format = 32
event.xclient.data[0] = x11.XInternAtom(display, b"WM_DELETE_WINDOW", 0)
if not x11.XSendEvent(display, window, 0, 0, ctypes.byref(event)):
    sys.exit("XSendEvent failed")
x11.XFlush(display)
PY
    return
  done
  fail "no mapped window with WM_CLASS $APP_ID to close"
}

# Every process descended from $1, including itself.
descendants() {
  local -a all=("$1") frontier=("$1") next
  local pid ppid stat p
  while ((${#frontier[@]})); do
    next=()
    for stat in /proc/[0-9]*/stat; do
      pid="${stat#/proc/}"
      pid="${pid%/stat}"
      ppid="$(sed 's/.*) [A-Za-z] \([0-9]*\).*/\1/' "$stat" 2>/dev/null)" || continue
      for p in "${frontier[@]}"; do
        if [[ "$ppid" == "$p" ]]; then next+=("$pid"); fi
      done
    done
    all+=("${next[@]}")
    frontier=("${next[@]}")
  done
  printf '%s\n' "${all[@]}"
}

# The process actually running the kapynotes binary: the launcher itself for
# the .deb, the tarball and a mounted AppImage, a child of the AppImage
# runtime when it extracts and runs.
app_pid() {
  local pid
  for pid in $(descendants "$1"); do
    if [[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" == */kapynotes ]]; then
      echo "$pid"
      return
    fi
  done
}

# run_app <kind> <out-dir> <root-of-shipped-files> <command...>
run_app() {
  local kind="$1" out="$2" root="$3"
  shift 3
  local display=":$display_number"
  display_number=$((display_number + 1))
  local home runtime log="$out/$kind.log"
  home="$(mktemp -d)"
  runtime="$(mktemp -d)"
  chmod 0700 "$runtime"

  Xvfb "$display" -screen 0 1280x800x24 -nolisten tcp >"$out/$kind.xvfb.log" 2>&1 &
  local xvfb=$!
  started+=("$xvfb")
  for _ in $(seq 50); do [[ -S "/tmp/.X11-unix/X${display#:}" ]] && break; sleep 0.1; done
  [[ -S "/tmp/.X11-unix/X${display#:}" ]] || fail "Xvfb did not start on $display"

  dbus-daemon --session --nofork --address="unix:path=$runtime/bus" >/dev/null 2>&1 &
  local bus=$!
  started+=("$bus")
  for _ in $(seq 50); do [[ -S "$runtime/bus" ]] && break; sleep 0.1; done

  say "$kind: starting $*"
  env HOME="$home" XDG_RUNTIME_DIR="$runtime" XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
    DISPLAY="$display" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
    "$@" >"$log" 2>&1 &
  local launcher=$!
  started+=("$launcher")

  local waited=0
  while ((waited < SMOKE_SECONDS)); do
    sleep 1
    waited=$((waited + 1))
    kill -0 "$launcher" 2>/dev/null || { cat "$log" >&2; fail "$kind exited after $waited s"; }
  done
  local pid
  pid="$(app_pid "$launcher")"
  [[ -n "$pid" ]] || { cat "$log" >&2; fail "$kind: no process is running the kapynotes binary"; }
  started+=("$pid")
  echo "  alive after $SMOKE_SECONDS s (pid $pid)"

  local tree
  tree="$(DISPLAY="$display" xwininfo -root -tree)"
  echo "$tree" >"$out/$kind.windows.txt"
  grep -q "\"$APP_ID\")" <<<"$tree" || {
    grep -E '\("[^"]*" "[^"]*"\)' <<<"$tree" | sed 's/^/    /' >&2
    fail "$kind: no window with WM_CLASS $APP_ID"
  }
  echo "  window with WM_CLASS $APP_ID is up"

  DISPLAY="$display" xwd -root -silent >"$out/$kind.xwd"
  if command -v convert >/dev/null; then convert "xwd:$out/$kind.xwd" "$out/$kind.png"; fi

  check_libraries "$root"
  check_ffmpeg "$root"

  local quit=SIGTERM
  if [[ "$kind" == tar ]]; then
    quit="closing the window"
    close_window "$display" "$tree"
  else
    kill -TERM "$pid"
  fi
  local status=
  for _ in $(seq 50); do
    if ! kill -0 "$launcher" 2>/dev/null; then
      status=0
      wait "$launcher" || status=$?
      break
    fi
    sleep 0.1
  done
  if [[ -z "$status" ]]; then
    kill -KILL "$pid" "$launcher" 2>/dev/null || true
    fail "$kind was still running 5 s after $quit"
  fi
  [[ "$status" == 0 ]] || { cat "$log" >&2; fail "$kind exited $status on $quit"; }
  echo "  $quit: clean exit"

  kill "$bus" "$xvfb" 2>/dev/null || true
  wait "$bus" "$xvfb" 2>/dev/null || true
  rm -rf "$home" "$runtime"

  if grep -nE 'MissingPluginException|not found|Failed to load dynamic library' "$log" >&2; then
    fail "$kind logged a missing plugin or library (above; full log in $log)"
  fi
  echo "PASS: $kind"
}

smoke_deb() {
  local deb out="$2"
  deb="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  say "deb: apt-get install $deb"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$deb"
  [[ -x /usr/bin/kapynotes ]] || fail "/usr/bin/kapynotes missing after install"
  run_app deb "$out" /usr/lib/kapynotes /usr/bin/kapynotes
  DEBIAN_FRONTEND=noninteractive apt-get remove -y -q kapynotes >/dev/null
}

smoke_tar() {
  local dir
  dir="$(mktemp -d)"
  tar -xzf "$1" -C "$dir"
  run_app tar "$2" "$dir/kapynotes" "$dir/kapynotes/kapynotes"
  rm -rf "$dir"
}

smoke_appimage() {
  local image dir kind=appimage
  image="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  chmod +x "$image"
  dir="$(mktemp -d)"
  (cd "$dir" && "$image" --appimage-extract >/dev/null)
  if [[ "${SMOKE_FUSE:-0}" == 1 ]]; then
    kind=appimage-fuse
    run_app "$kind" "$2" "$dir/squashfs-root/usr/lib/kapynotes" "$image"
  else
    run_app "$kind" "$2" "$dir/squashfs-root/usr/lib/kapynotes" env APPIMAGE_EXTRACT_AND_RUN=1 "$image"
  fi
  rm -rf "$dir"
}

kind="${1:-}"
case "$kind" in
  baseline)
    install_baseline
    exit 0
    ;;
  deb|tar|appimage|all)
    [[ $# -eq 3 ]] || fail "usage: $0 $kind <package-or-dist-dir> <out-dir>"
    ;;
  *)
    fail "usage: $0 baseline | deb|tar|appimage <package> <out-dir> | all <dist-dir> <out-dir>"
    ;;
esac

mkdir -p "$3"
out="$(cd "$3" && pwd)"
case "$kind" in
  deb) smoke_deb "$2" "$out" ;;
  tar) smoke_tar "$2" "$out" ;;
  appimage) smoke_appimage "$2" "$out" ;;
  all)
    shopt -s nullglob
    debs=("$2"/KapyNotes-*.deb)
    tars=("$2"/KapyNotes-*-linux-*.tar.gz)
    images=("$2"/KapyNotes-*.AppImage)
    ((${#tars[@]} == 1 && ${#images[@]} == 1)) || fail "expected one tar.gz and one AppImage in $2"
    if command -v apt-get >/dev/null; then
      ((${#debs[@]} == 1)) || fail "expected one .deb in $2"
      smoke_deb "${debs[0]}" "$out"
    fi
    smoke_tar "${tars[0]}" "$out"
    smoke_appimage "${images[0]}" "$out"
    ;;
esac
chmod -R a+rwX "$out"
