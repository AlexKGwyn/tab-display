#!/bin/zsh
# Accepts Android's "open/allow Tab Display for this accessory" prompt if it's showing: ticks
# "Always …" and taps OK, finding both by their on-screen text (works on any screen size).
for i in {1..10}; do
  adb shell dumpsys activity activities | grep -qE "UsbPermissionActivity|UsbConfirmActivity" || { sleep 0.5; continue; }
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  X=$(adb shell cat /sdcard/ui.xml)
  center() { echo "$X" | tr '>' '\n' | grep -E "$1" | head -1 | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+' | tr '\n' ' ' | awk '{print int(($1+$3)/2), int(($2+$4)/2)}'; }
  A=$(center 'text="Always'); O=$(center 'text="OK"|text="Allow"')
  [ -n "$A" ] && adb shell input tap ${=A}
  sleep 0.3
  [ -n "$O" ] && adb shell input tap ${=O} && { echo "accepted USB prompt"; exit 0; }
  sleep 0.5
done
exit 1
