#!/bin/bash
# Fetches the LiteRT-LM native libraries that flutter_gemma_litertlm's build
# hook would download, with retries, into the cache the hook reads first:
#
#   bash tool/ci/gemma_natives.sh [<platform>...]
#
# <platform> is one of the hook's directory names, such as ios_sim_arm64 or
# macos_arm64; with none, the host's own. Run it after `flutter pub get`.
#
# The hook downloads each archive from GitHub once, with no retry, so a DNS
# or GitHub blip failed a whole build (KAP-320: Phones 45187903654, "Failed
# host lookup: 'github.com'"). Here curl retries for about two minutes. Each
# archive is checked against the sha256 the hook itself pins, and the hook's
# version marker is written last, as the hook does, so the build finds the
# libraries in place and never goes to the network. The version, the release
# and the sums are read from the hook in the pub cache, so they follow
# pubspec.lock.
set -euo pipefail

package=flutter_gemma_litertlm
root=$(jq -r --arg p "$package" '.packages[] | select(.name == $p) | .rootUri' .dart_tool/package_config.json)
root=${root#file://}
[[ $root =~ ^/[A-Za-z]: ]] && root=${root#/}
hook="$root/hook/build.dart"
[[ -f $hook ]] || { echo "gemma_natives.sh: no $package hook at $hook; run flutter pub get first" >&2; exit 1; }

version=$(sed -n "/const _litertlmBundle/,/);/s/^ *version: '\(.*\)',$/\1/p" "$hook")
[[ -n $version ]] || { echo "gemma_natives.sh: no litertlm version in $hook" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) cache="$HOME/Library/Caches/flutter_gemma/native" ;;
  MINGW* | MSYS* | CYGWIN*) cache="$(cygpath -u "$LOCALAPPDATA")/flutter_gemma/native" ;;
  *) cache="$HOME/.cache/flutter_gemma/native" ;;
esac

if (($# == 0)); then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) set -- macos_arm64 ;;
    Linux-x86_64) set -- linux_x86_64 ;;
    Linux-aarch64) set -- linux_arm64 ;;
    MINGW*-x86_64 | MSYS*-x86_64) set -- windows_x86_64 ;;
    *) echo "gemma_natives.sh: name the platform for $(uname -sm)" >&2; exit 1 ;;
  esac
fi

marker="$cache/.flutter_gemma_native_version"
expected="{\"version\":\"$version\",\"owner\":\"$package\"}"
mkdir -p "$cache"
if [[ -f $marker && $(cat "$marker") != "$expected" ]]; then
  echo "gemma_natives.sh: the cache holds another version ($(cat "$marker")); emptying it" >&2
  rm -rf "${cache:?}"/*_* "$marker"
fi

for platform; do
  archive="litertlm-$platform.tar.gz"
  sum=$(grep -A1 "'$archive':" "$hook" | sed -n "s/^ *'\([0-9a-f]\{64\}\)',$/\1/p")
  [[ -n $sum ]] || { echo "gemma_natives.sh: the hook pins no $archive, so it ships nothing for $platform" >&2; exit 1; }
  if [[ -f $marker && -d $cache/$platform ]]; then
    echo "gemma_natives.sh: $platform $version is already in $cache"
    continue
  fi
  url="https://github.com/DenisovAV/flutter_gemma/releases/download/native-v$version/$archive"
  tmp=$(mktemp -d "$cache/.tmp-$platform-XXXX")
  echo "gemma_natives.sh: fetching $url"
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 15 --connect-timeout 20 -o "$tmp/$archive" "$url"
  if command -v sha256sum >/dev/null; then check=(sha256sum -c -); else check=(shasum -a 256 -c -); fi
  echo "$sum  $tmp/$archive" | "${check[@]}" >/dev/null || {
    echo "gemma_natives.sh: $archive does not match the sha256 the hook pins ($sum)" >&2
    rm -rf "$tmp"
    exit 1
  }
  mkdir "$tmp/$platform"
  tar -xzf "$tmp/$archive" -C "$tmp/$platform"
  rm -rf "${cache:?}/$platform"
  mv "$tmp/$platform" "$cache/$platform"
  rm -rf "$tmp"
  echo "gemma_natives.sh: $platform $version is in $cache"
done
printf '%s' "$expected" > "$marker"
