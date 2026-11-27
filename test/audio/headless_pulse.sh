#!/bin/bash
# A sound server for the Linux voice tests on a machine with no sound card:
# PulseAudio, with a speaker nobody hears and a microphone that hears a
# 440 Hz tone, as the defaults, and a second microphone that hears nothing
# at all, as a muted one does.
#
#   bash test/audio/headless_pulse.sh
#   flutter test test/audio/linux_voice_test.dart
#
# Needs pulseaudio, pulseaudio-utils and ffmpeg. The microphone is a pipe
# source that ffmpeg feeds in real time, with a reader keeping it running so
# that nothing piles up in the pipe between recordings: each one starts from
# now, as it does from a microphone. PulseAudio's own test sources will not
# do. module-sine-source hands out two seconds at a time, so a stop lands up
# to two seconds out, and the monitor of an idle null sink hands ffmpeg gaps,
# which it skips.
set -euo pipefail

if ! pactl info >/dev/null 2>&1; then
  pulseaudio --start --exit-idle-time=-1
  for _ in $(seq 50); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done
fi

fifo="${XDG_RUNTIME_DIR:-/tmp}/kapy-test-mic"
silent_fifo="${XDG_RUNTIME_DIR:-/tmp}/kapy-silent-mic"
if ! pactl list short sinks | grep -q kapy_test_speaker; then
  pactl load-module module-null-sink sink_name=kapy_test_speaker >/dev/null
fi
if ! pactl list short sources | grep -q kapy_test_mic; then
  rm -f "$fifo"
  pactl load-module module-pipe-source source_name=kapy_test_mic \
    file="$fifo" format=s16le rate=16000 channels=1 >/dev/null
fi
if ! pactl list short sources | grep -q kapy_silent_mic; then
  rm -f "$silent_fifo"
  pactl load-module module-pipe-source source_name=kapy_silent_mic \
    file="$silent_fifo" format=s16le rate=16000 channels=1 >/dev/null
fi

pkill -f '^kapy-test-mic-' || true
setsid bash -c "exec -a kapy-test-mic-tone ffmpeg -nostdin -loglevel error \
  -re -f lavfi -i sine=frequency=440:sample_rate=16000 -ac 1 \
  -flush_packets 1 -f s16le -y '$fifo'" </dev/null >/dev/null 2>&1 &
setsid bash -c "exec -a kapy-test-mic-reader pacat --record \
  --device=kapy_test_mic" </dev/null >/dev/null 2>&1 &
setsid bash -c "exec -a kapy-test-mic-silence ffmpeg -nostdin -loglevel error \
  -re -f lavfi -i anullsrc=channel_layout=mono:sample_rate=16000 \
  -flush_packets 1 -f s16le -y '$silent_fifo'" </dev/null >/dev/null 2>&1 &
setsid bash -c "exec -a kapy-test-mic-silent-reader pacat --record \
  --device=kapy_silent_mic" </dev/null >/dev/null 2>&1 &

pactl set-default-sink kapy_test_speaker
pactl set-default-source kapy_test_mic
