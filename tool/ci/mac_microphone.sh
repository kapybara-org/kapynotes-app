#!/bin/bash
# A microphone for the voice tests on a macOS runner, which has no audio
# device: the BlackHole loopback driver as the only input and the output,
# the app allowed to use it, and speech played into it for as long as the
# job runs, so a recording has sound in it.
#
#   bash tool/ci/mac_microphone.sh
#
# The runner's SIP is off, as GitHub's images set it up, which is what lets
# this write the microphone grant into TCC's database. Like mac_tests.sh it
# refuses to run anywhere but CI.
set -euo pipefail

if [[ ${CI:-} != true ]]; then
  echo 'mac_microphone.sh is for CI runners: it installs an audio driver.' >&2
  exit 2
fi

brew install --cask blackhole-2ch
brew install switchaudio-osx
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
for _ in $(seq 30); do
  SwitchAudioSource -a -t input | grep -q 'BlackHole 2ch' && break
  sleep 1
done
echo 'Inputs:'
SwitchAudioSource -a -t input
SwitchAudioSource -t input -s 'BlackHole 2ch'
SwitchAudioSource -t output -s 'BlackHole 2ch'

grant="INSERT OR REPLACE INTO access
  (service, client, client_type, auth_value, auth_reason, auth_version)
  VALUES ('kTCCServiceMicrophone', 'com.kapybara.kapynotes', 0, 2, 4, 1);"
# The system's database always exists. The user's only once something has
# asked it a question, which on a fresh runner nothing has.
sudo sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' "$grant"
user_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [[ -f $user_db ]]; then sqlite3 "$user_db" "$grant"; fi

nohup bash -c "while true; do
  say -a 'BlackHole 2ch' 'Kapy Notes is listening to this test.'
done" >/dev/null 2>&1 &
disown
