#!/bin/zsh
# Text sharpness after motion: scrolls a 12 pt text page on the virtual display, waits $1 s after
# it stops, then compares the tablet's screen with the Mac's own capture of the virtual display.
cd "$(dirname $0)"
WAIT=${1:-1.0}
adb shell am start -n com.alexgwyn.tabdisplay/.MainActivity --ez hud false >/dev/null 2>&1
swift -e 'import CoreGraphics; CGWarpMouseCursorPosition(CGPoint(x: 700, y: 400))' 2>/dev/null
./build/textpage > /tmp/tp.out 2>&1 & PID=$!
for i in {1..100}; do grep -q stopped /tmp/tp.out && break; sleep 0.05; done
sleep $WAIT
adb exec-out screencap -p > /tmp/tab_text.png
screencapture -x -D 2 /tmp/mac_text.png
kill $PID
sips -g pixelWidth -g pixelHeight /tmp/tab_text.png /tmp/mac_text.png | grep pixel | tr '\n' ' '; echo
./build/imagediff /tmp/tab_text.png /tmp/mac_text.png 100 100 2360 1400
