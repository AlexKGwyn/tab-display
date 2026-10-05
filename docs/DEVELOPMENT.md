# Development

```
protocol/   spec.md + gen.py (generates Swift, C++ and Kotlin constants)
mac/        SwiftPM menu bar app: virtual display, capture, encode, USB/TCP transport, input, ADB, UI
android/    Gradle project: Kotlin UI + C++ transport/decoder/presenter (app/src/main/cpp)
probes/     feasibility probes (virtual display, VideoToolbox, ScreenCaptureKit)
tools/      test pattern, inspectors, demo scene, measurement and replug scripts
store/      store artwork (1024 px Mac icon, 512 px Play icon)
docs/       results, development notes, README images
```

## Building

Requirements: Xcode Command Line Tools (full Xcode not needed), Android SDK with platform 36, NDK 26.1
and CMake 3.22.1, JDK 17 (Android Studio's works:
`export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`). Both apps take their
version from `VERSION`.

```sh
python3 protocol/gen.py                   # after changing protocol constants
cd mac && ./build.sh --install            # builds the Android APK, bundles it, builds and installs the Mac app
                                          # --skip-apk reuses the last APK; --dmg also builds a DMG
cd android && ./gradlew assembleDebug     # debug APK (includes the adb dev transport)
cd android && ./gradlew bundleRelease     # → app/build/outputs/bundle/release/app-release.aab
```

`build.sh` signs with `SIGN_IDENTITY` if set (Developer ID, hardened runtime). Otherwise it uses a local
self-signed identity in `mac/signing/dev.keychain-db` (not committed), which keeps Screen Recording and
Accessibility grants valid across rebuilds. If neither is present it signs ad-hoc.

## Publishing

**Mac (direct download, Developer ID):**

```sh
xcrun notarytool store-credentials tabdisplay --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tabdisplay ./mac/build.sh --dmg
```

This signs with the hardened runtime, notarizes and staples both the app and the DMG. The private
`CGVirtualDisplay` API rules out the Mac App Store.

**Android (Google Play):** release builds are signed with the upload key in `android/keystore/upload.jks`,
configured through `android/keystore.properties` (neither is committed: back both up). Enroll in Play
App Signing and upload `app-release.aab`. Listing icon: `store/play-icon-512.png`. Privacy policy:
[`PRIVACY.md`](../PRIVACY.md). Set `mac_app_url` in `android/app/src/main/res/values/strings.xml` so the
tablet's setup screen links to the Mac app download.

**Licenses:** libusb (LGPL-2.1) ships as a separate, replaceable dylib in `Contents/Frameworks`, with its
license in `Contents/Resources/Acknowledgements.txt`.

## Installing the tablet app from the Mac (ADB)

The Mac app bundles the Android APK and contains a small ADB client (`mac/Sources/TabDisplay/ADB/`), not
Google's `adb` binary, which can't be redistributed. It uses a running adb server when there is one, and
otherwise speaks the adb protocol to the tablet over USB with its own RSA key
(`~/Library/Application Support/Tab Display/adbkey.der`). The tablet asks "Allow USB debugging?" once.
It only lists devices, reads the installed version and stream-installs the bundled APK. USB control
work (device probing, the accessory handshake, adb commands) is serialized, because interleaving them
on one device breaks the adb stream.

## Tools

Scripts assume a tablet connected with USB debugging on and a debug build installed.

| Command | What it does |
| --- | --- |
| `tools/measure.sh usb 15` | Restart both apps, run the moving test pattern, print stage latencies |
| `tools/replug.sh 20` | Simulated unplug/replug loop |
| `tools/tablet_accept_usb.sh` | Accepts the tablet's "open Tab Display for this accessory" prompt |
| `tools/textquality.sh 1.0` | Scroll a 12 pt text page; compare the tablet's screen with the Mac's capture |
| `tools/build/testpattern [--screen NAME]` | Moving bar and ms clock on the virtual display (camera latency test) |
| `tools/build/inputinspector` | Logs every mouse/tablet/scroll event arriving on the virtual display |
| `tools/build/levelspage` | Solid black/white halves for checking black and white levels |
| `tools/build/sketchdemo` | Demo scene (covers the display) with a pen-pressure sketch window, used for the README image |
| `tools/build/makeicons DIR` | Re-renders the app icon artwork |

Build a tool with `swiftc -O tools/<Name>.swift -o tools/build/<name>`. Logs: Mac
`~/Library/Logs/TabDisplay.log` (stats line every 2 s); tablet `adb logcat -s TabDisplay TabDisplayHUD`.

Development hooks in the Mac app:
- `--snapshot DIR` renders the menu and menu bar icon to PNGs.
- `--adb list|install|authorize` runs the menu's tablet-app actions and logs the results.
- `--transport tcp` uses the `adb forward` dev link.
- Distributed notifications `com.alexgwyn.tabdisplay.connect` (click Connect for the first tablet), `com.alexgwyn.tabdisplay.reloadSettings` (re-apply settings written with
  `defaults write`) and `com.alexgwyn.tabdisplay.showMenu` (open the menu).

Experiment switches:
- Mac env (`open --env K=V …`): `TD_LLRC`, `TD_INFLIGHT`, `TD_THROUGHPUT_MB`, `TD_YSTATS`, `TD_VERIFY`,
  `TD_VIDEORANGE`, `TD_REFINE_QP1/2`, `TD_REALTIME`, `TD_EXPECTED_FPS`, `TD_CODEC=hevc|h264`
  (`TD_LLRC=0` turns off H.264 low-latency rate control).
- Tablet: `adb shell setprop debug.tabdisplay.<rate|ll|eop|nonubwc|range|transfer|nocolor> <int>`.
