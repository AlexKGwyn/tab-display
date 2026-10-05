#!/bin/zsh
# Restarts the tablet app and the Mac app, then prints both logs after $2 seconds.
# Usage: tools/restart.sh [tcp|usb] [seconds]
T=${1:-tcp}; S=${2:-8}
pkill -x TabDisplay; sleep 0.5
: > ~/Library/Logs/TabDisplay.log
adb logcat -c
adb shell am force-stop com.alexgwyn.tabdisplay
adb shell am start -n com.alexgwyn.tabdisplay/.MainActivity --ez hud true >/dev/null
sleep 1.5
open "/Applications/Tab Display.app" --args --transport $T
sleep $S
echo "=== mac"; tail -25 ~/Library/Logs/TabDisplay.log
echo "=== tablet"; adb logcat -d -s TabDisplay TabDisplayHUD | grep -v "beginning of" | tail -25
