#!/bin/zsh
# Simulated unplug/replug loop: switches the tablet's USB function away from accessory mode
# (as an unplug does) and waits for the Mac app to re-run AOA and resume streaming.
# Usage: tools/replug.sh [iterations]
N=${1:-20}; LOG=~/Library/Logs/TabDisplay.log; ok=0
for i in $(seq 1 $N); do
  before=$(grep -c "tablet HELLO" $LOG)
  adb shell svc usb setFunctions mtp >/dev/null 2>&1
  t0=$(date +%s.%N); got=0
  for j in {1..60}; do
    sleep 0.5
    if [ $(grep -c "tablet HELLO" $LOG) -gt $before ]; then got=1; break; fi
  done
  dt=$(printf "%.1f" $(( $(date +%s.%N) - t0 )))
  if [ $got = 1 ]; then ok=$((ok+1)); echo "cycle $i: reconnected in ${dt}s"; else echo "cycle $i: FAILED after ${dt}s"; fi
  adb wait-for-device; sleep 3
done
echo "$ok/$N cycles reconnected"
pgrep -x TabDisplay >/dev/null && echo "Mac app alive" || echo "Mac app DEAD"
