#!/bin/zsh
# Runs both apps with the moving test pattern for $2 seconds and prints the last stats lines.
# Extra env for the Mac app via MAC_ENV="A=1 B=2"; extra tablet intent args via TAB_EXTRA. Usage: tools/measure.sh [tcp|usb] [seconds]
T=${1:-tcp}; S=${2:-10}
cd "$(dirname $0)/.."
pkill -x TabDisplay; pkill -f build/testpattern; sleep 0.5
: > ~/Library/Logs/TabDisplay.log
adb logcat -c
adb shell am force-stop com.alexgwyn.tabdisplay
adb shell am start -n com.alexgwyn.tabdisplay/.MainActivity --ez hud true ${TAB_EXTRA:-} >/dev/null
sleep 1.5
ENVARGS=(); for kv in ${=MAC_ENV:-}; do ENVARGS+=(--env $kv); done
open $ENVARGS "/Applications/Tab Display.app" --args --transport $T
for i in {1..30}; do grep -q "capture started" ~/Library/Logs/TabDisplay.log 2>/dev/null && break; sleep 0.3; done
tools/build/testpattern >/dev/null & PAT=$!
sleep $S
grep -E "encoder input|connect failed|error" ~/Library/Logs/TabDisplay.log | head -3
grep stats: ~/Library/Logs/TabDisplay.log | tail -2
kill $PAT
