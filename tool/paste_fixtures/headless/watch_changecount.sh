#!/bin/bash
# Logs NSPasteboard.general.changeCount (read-only) once a second, only when it changes, plus a heartbeat every 60s.
last=""; n=0
while true; do
  c=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSPasteboard.generalPasteboard.changeCount' 2>/dev/null)
  n=$((n+1))
  if [ "$c" != "$last" ] || [ $((n % 60)) -eq 0 ]; then echo "$(date -u +%FT%TZ) $c" >> ${PASTE_FIXTURE_SCRATCH:-$HOME/.capy/work/paste-fixtures}/watch.log; last="$c"; fi
  sleep 1
done
