#!/bin/bash
# The release_check job of .github/workflows/phones.yml, on a booted Android
# emulator with a google_apis image, whose adb can run as root:
#
#   bash tool/ci/android_release_check.sh <device id> <dir>
#
# <dir> holds app.apks and probe.apks, made by bundletool build-apks
# --local-testing from the release app bundle and from the same bundle built
# with tool/live_release_probe.dart as its entrypoint. Local testing stands in
# for Google Play: on-demand modules wait on the device's storage until the
# app asks for them. Logs, dumpsys output and screenshots go to <dir>/evidence.
#
# (a) The app with live translation off launches and stays up with no crash,
#     and translation_runtime isn't installed.
# (b) The probe turns live translation on for Spanish to English: prepare
#     installs translation_runtime, and a short phrase translates. Where the
#     emulator's recogniser can't hear Spanish, which the probe shows by the
#     languages it lists, it does the same for English to Spanish, and says
#     so with a warning.
# (c) After the probe's live session stops, with the app still running, none
#     of the app's services runs, no recording of its is active, the file has
#     stopped growing, and no session is left.
#
# Every check runs, and the script exits 1 if any failed.
set -uo pipefail

device=$1
dir=$2
pkg=com.kapybara.kapynotes
data=/data/user/0/$pkg
out=$dir/evidence
probe_minutes=${PROBE_MINUTES:-20}
status=0
mkdir -p "$out"

adb() { command adb -s "$device" "$@"; }
pass() { echo "PASS: $1"; }
fail() {
  echo "::error::$1"
  status=1
}
running() { adb shell pidof "$pkg" | tr -d '\r'; }
splits() { adb shell "find $data/files/splitcompat 2>/dev/null" | tr -d '\r'; }
crashes() { adb logcat -d -b crash | grep -F "$pkg"; }

# The app's active recordings in dumpsys audio's RecordActivityMonitor, one
# line each: a "riid N; active? true" entry whose configuration names the
# app. The section ends where its log of past events begins.
recordings() {
  awk -v uid="uid:$uid " -v pack="pack:$pkg" '
    /RecordActivityMonitor dump time/ { on = 1; next }
    on && /[Ee]vents? log/ { on = 0 }
    on && /^ *riid/ { active = /active\?? true/; next }
    on && active && (index($0, uid) || index($0, pack)) { print }
  ' "$1"
}

snapshot() {
  adb shell dumpsys activity services "$pkg" > "$out/$1-services.txt"
  adb shell dumpsys audio > "$out/$1-audio.txt"
  adb shell dumpsys media.audio_flinger > "$out/$1-audio-flinger.txt"
  adb exec-out screencap -p > "$out/$1.png"
}

adb root >/dev/null
adb wait-for-device
until [[ $(adb shell getprop sys.boot_completed | tr -d '\r') == 1 ]]; do sleep 2; done

# What this image has for an on-device recogniser and translator, which is
# what availability, prepare and a session ask for first.
{
  echo "## android.speech.RecognitionService"
  adb shell cmd package query-services -a android.speech.RecognitionService
  echo "## android.service.translation.TranslationService"
  adb shell cmd package query-services -a android.service.translation.TranslationService
  echo "## packages"
  adb shell pm list packages
} > "$out/image.txt" 2>&1

echo "::group::(a) the release app, live translation off"
if java -jar "$BUNDLETOOL" install-apks --apks "$dir/app.apks" --device-id "$device"; then
  pass "bundletool installed the release app"
else
  fail "bundletool could not install the release app"
fi
uid=$(adb shell cmd package list packages -U "$pkg" | tr -d '\r' | sed -n 's/.* uid:\([0-9]*\).*/\1/p' | head -1)
echo "uid $uid"
adb shell pm path "$pkg" | tr -d '\r' > "$out/a-pm-path.txt"
adb shell "ls -lR /sdcard/Android/data/$pkg/files/local_testing" | tr -d '\r' > "$out/a-local-testing.txt"
cat "$out/a-pm-path.txt" "$out/a-local-testing.txt"
if grep -q translation_runtime "$out/a-local-testing.txt"; then
  pass "local testing holds translation_runtime for an on-demand install"
else
  fail "bundletool's local testing put no translation_runtime split on the device"
fi

adb logcat -c
adb logcat -b crash -c
adb shell am start -W -n "$pkg/.MainActivity" | tr -d '\r'
sleep 20
pid=$(running)
if [[ -n $pid ]]; then pass "the app is running, pid $pid, 20 s after launch"; else fail "the app isn't running 20 s after launch"; fi
top=$(adb shell dumpsys activity activities | tr -d '\r' | grep -m1 -E 'topResumedActivity|mResumedActivity')
echo "$top"
if [[ $top == *"$pkg/.MainActivity"* ]]; then pass "MainActivity is in front"; else fail "MainActivity isn't the resumed activity"; fi
adb exec-out screencap -p > "$out/a-launched.png"
adb logcat -d > "$out/a-logcat.txt"
if crashes > "$out/a-crash.txt" || grep -q "ANR in $pkg" "$out/a-logcat.txt"; then
  fail "the app crashed or stopped answering: see a-crash.txt"
  cat "$out/a-crash.txt"
else
  pass "no crash or ANR for $pkg in logcat"
fi
splits > "$out/a-splitcompat.txt"
cat "$out/a-splitcompat.txt"
if grep -q translation_runtime "$out/a-splitcompat.txt" "$out/a-pm-path.txt"; then
  fail "translation_runtime is installed with live translation off"
else
  pass "translation_runtime isn't installed: nothing under $data/files/splitcompat or pm path names it"
fi
echo "LiveTranslation asked for the module $(grep -c 'translation runtime not loadable' "$out/a-logcat.txt") times"
echo "::endgroup::"

echo "::group::(b) the probe turns live translation on"
adb shell am force-stop "$pkg"
if java -jar "$BUNDLETOOL" install-apks --apks "$dir/probe.apks" --device-id "$device"; then
  pass "bundletool installed the probe over the app"
else
  fail "bundletool could not install the probe"
fi
adb shell pm grant "$pkg" android.permission.RECORD_AUDIO
adb logcat -c
adb logcat -b crash -c
adb shell am start -W -n "$pkg/.MainActivity" | tr -d '\r'
during=false
deadline=$(( SECONDS + probe_minutes * 60 ))
while (( SECONDS < deadline )); do
  adb logcat -d -s flutter:I | tr -d '\r' | grep -o 'LIVE_PROBE .*' > "$out/probe.txt"
  if ! $during && grep -q 'live=started' "$out/probe.txt"; then
    sleep 3
    snapshot during
    during=true
  fi
  grep -q 'LIVE_PROBE done' "$out/probe.txt" && break
  if [[ -z $(running) ]]; then
    fail "the probe's process is gone"
    break
  fi
  sleep 3
done
cat "$out/probe.txt"
grep -q 'LIVE_PROBE done' "$out/probe.txt" || fail "the probe didn't finish within $probe_minutes minutes"
adb logcat -d > "$out/b-logcat.txt"
adb exec-out screencap -p > "$out/b-probe.png"

value() { sed -n "s/^LIVE_PROBE $1=\([^ ]*\).*/\1/p" "$out/probe.txt" | head -1; }
spoken=$(value spoken)
echo "the recogniser hears: ${spoken:-nothing}"
pair=es-en
prepared=$(value "es-en prepare")
if [[ $prepared == ready ]]; then
  pass "prepare('es', 'en') answered ready"
elif [[ $prepared == unsupported && ,$spoken, != *,es,* ]]; then
  echo "::warning::prepare('es', 'en') answered unsupported because this emulator's recogniser can't hear Spanish (it hears ${spoken:-nothing}); checking English to Spanish instead"
  pair=en-es
  prepared=$(value "en-es prepare")
  if [[ $prepared == ready ]]; then pass "prepare('en', 'es') answered ready"; else fail "prepare('en', 'es') answered ${prepared:-nothing}"; fi
else
  fail "prepare('es', 'en') answered ${prepared:-nothing}, with the recogniser hearing ${spoken:-nothing}"
fi
splits > "$out/b-splitcompat.txt"
cat "$out/b-splitcompat.txt"
if grep -q translation_runtime "$out/b-splitcompat.txt"; then
  pass "translation_runtime is installed under $data/files/splitcompat"
else
  fail "translation_runtime isn't installed after prepare"
fi
translated=$(value "$pair translate")
if [[ $translated == ok ]]; then pass "the $pair test phrase translated"; else fail "$pair translate answered ${translated:-nothing}"; fi
echo "::endgroup::"

echo "::group::(c) after the live session stops"
live=$(grep -o '^LIVE_PROBE live=[^ ]*' "$out/probe.txt" | grep -v started | head -1 | cut -d' ' -f2)
echo "session: $(grep 'LIVE_PROBE live=' "$out/probe.txt" | tr '\n' ' ')"
pid=$(running)
if [[ -n $pid ]]; then
  pass "the probe is still running, pid $pid, so what follows is checked with the app alive"
else
  fail "the probe isn't running, so nothing left running proves nothing"
fi
if [[ $live == live=stopped ]]; then pass "the session started and stopped"; else fail "the live session ended as ${live:-nothing}"; fi
echo "the session's own stop events: $(grep -o 'live_stop=[^ ]*' "$out/probe.txt" | tr '\n' ' ')"
snapshot after
sed -n '/RecordActivityMonitor dump time/,/[Ee]vents\{0,1\} log/p' "$out/during-audio.txt" "$out/after-audio.txt"
if $during; then
  if [[ -n $(recordings "$out/during-audio.txt") ]]; then
    pass "during the session dumpsys audio showed the app recording"
  else
    fail "dumpsys audio showed no recording of the app's during the session, so the check after it proves nothing"
  fi
else
  fail "the session never started, so there was nothing to compare with"
fi
if [[ -n $(recordings "$out/after-audio.txt") ]]; then
  fail "after stop dumpsys audio still shows the app recording"
  recordings "$out/after-audio.txt"
else
  pass "after stop dumpsys audio shows no recording of the app's"
fi
if grep -q ServiceRecord "$out/after-services.txt"; then
  fail "a service of the app's is running after stop"
  cat "$out/after-services.txt"
else
  pass "no service of the app's runs after stop"
fi
file=$data/files/live_probe.aac
first=$(adb shell stat -c %s "$file" 2>/dev/null | tr -d '\r')
sleep 5
second=$(adb shell stat -c %s "$file" 2>/dev/null | tr -d '\r')
if [[ -n $first && $first == "$second" ]]; then
  pass "the session's file stays at $first bytes"
else
  fail "the session's file went from ${first:-nothing} to ${second:-nothing} bytes after stop"
fi
leftover=$(value second_stop)
if [[ $leftover == idle ]]; then pass "a second stop finds no session"; else fail "a second stop answered ${leftover:-nothing}"; fi
if crashes > "$out/b-crash.txt"; then
  fail "the probe crashed: see b-crash.txt"
  cat "$out/b-crash.txt"
else
  pass "no crash for $pkg in logcat"
fi
echo "::endgroup::"

exit $status
