#!/usr/bin/env bash
set -euo pipefail
LED=/sys/class/leds/ACT
[ -d "$LED" ] || LED=/sys/class/leds/led0
[ -d "$LED" ] || exec sleep infinity
STATE=/persist/dancam/commissioning.json

while :; do
  state=$(jq -r .state "$STATE" 2>/dev/null || echo failed)
  case "$state" in
    preparing) on=0.15; off=0.85 ;;
    complete) on=1.5; off=0.1 ;;
    *) on=0.15; off=0.15 ;;
  esac
  echo none > "$LED/trigger" 2>/dev/null || true
  echo 1 > "$LED/brightness" 2>/dev/null || true
  sleep "$on"
  echo 0 > "$LED/brightness" 2>/dev/null || true
  sleep "$off"
done
