#!/bin/zsh
# Builds dist/TabDisplay.app (release). Options:
#   --install  also replace /Applications/Tab Display.app (quits the running app first)
#   --skip-apk don't (re)build the Android app; reuse the last APK if there is one
# The Android release APK is bundled as Contents/Resources/TabDisplay.apk so the menu can install
# it on a tablet with USB debugging on.
#   --dmg      also build dist/TabDisplay-<version>.dmg
#
# Signing:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  → hardened runtime + timestamp (distribution)
#   else the local self-signed "TabDisplay Dev" identity in signing/dev.keychain-db (development;
#   stable across rebuilds so Screen Recording / Accessibility grants persist); else ad-hoc.
# Notarization (needs SIGN_IDENTITY and --dmg):
#   xcrun notarytool store-credentials tabdisplay --apple-id you@example.com --team-id TEAMID
#   NOTARY_PROFILE=tabdisplay ./build.sh --dmg
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat ../VERSION)
BUILD=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
MAKE_DMG=0; INSTALL=0; SKIP_APK=0
for arg in "$@"; do
    case $arg in
        --dmg) MAKE_DMG=1 ;;
        --install) INSTALL=1 ;;
        --skip-apk) SKIP_APK=1 ;;
        *) echo "unknown option $arg"; exit 1 ;;
    esac
done

python3 ../protocol/gen.py >/dev/null
APK=../android/app/build/outputs/apk/release/app-release.apk
if [[ $SKIP_APK == 0 ]]; then
    export JAVA_HOME=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}
    if (cd ../android && ./gradlew -q assembleRelease); then echo "built Android APK"
    else echo "warning: Android build failed; bundling the previous APK if any"; fi
fi
swift build -c release
APP=dist/TabDisplay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/TabDisplay "$APP/Contents/MacOS/TabDisplay"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Vendor/libusb/libusb-1.0.0.dylib "$APP/Contents/Frameworks/"
if [[ -f $APK ]]; then cp "$APK" "$APP/Contents/Resources/TabDisplay.apk"
else echo "warning: no Android APK; the menu won't offer to install the tablet app"; fi
{
    echo "Tab Display includes libusb 1.0.29 (https://libusb.info), dynamically linked as"
    echo "Contents/Frameworks/libusb-1.0.0.dylib. You may replace it with a compatible build."
    echo "Source: https://github.com/libusb/libusb/releases/tag/v1.0.29"
    echo
    cat Vendor/libusb/COPYING
} > "$APP/Contents/Resources/Acknowledgements.txt"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.alexgwyn.tabdisplay.mac</string>
    <key>CFBundleName</key><string>Tab Display</string>
    <key>CFBundleDisplayName</key><string>Tab Display</string>
    <key>CFBundleExecutable</key><string>TabDisplay</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Tab Display contributors</string>
    <key>NSScreenCaptureUsageDescription</key><string>Tab Display streams its virtual display to your tablet.</string>
</dict>
</plist>
PLIST

sign() {  # sign <path> [extra codesign args]
    local target=$1; shift
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$@" "$target"
    elif [[ -n "${DEV_HASH:-}" ]]; then
        codesign --force --keychain "$KC" -s "$DEV_HASH" "$@" "$target"
    else
        codesign --force -s - "$@" "$target"
    fi
}

KC="$PWD/signing/dev.keychain-db"
if [[ -z "${SIGN_IDENTITY:-}" && -f "$KC" ]]; then
    # codesign only searches keychains on the user's search list: add ours for the duration.
    ORIG=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
    security list-keychains -d user -s "${ORIG[@]}" "$KC"
    trap 'security list-keychains -d user -s "${ORIG[@]}"' EXIT
    security unlock-keychain -p tabdisplay "$KC"
    DEV_HASH=$(security find-identity -p codesigning "$KC" | awk '/TabDisplay Dev/{print $2; exit}')
fi
sign "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
sign "$APP"
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^Authority|Signature=|flags" | head -3 || true
echo "built $APP ($VERSION build $BUILD)"

if [[ $INSTALL == 1 ]]; then
    pkill -x TabDisplay && sleep 1 || true
    rm -rf "/Applications/Tab Display.app"
    ditto "$APP" "/Applications/Tab Display.app"
    echo "installed /Applications/Tab Display.app"
fi

[[ $MAKE_DMG == 1 ]] || exit 0

notarize() {  # notarize <file>
    [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]] || return 0
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
    ditto -c -k --keepParent "$APP" dist/TabDisplay.zip
    notarize dist/TabDisplay.zip && xcrun stapler staple "$APP"
    rm -f dist/TabDisplay.zip
fi
DMG="dist/TabDisplay-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Tab Display" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
sign "$DMG"
if notarize "$DMG" && [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then xcrun stapler staple "$DMG"; fi
echo "built $DMG"
[[ -n "${NOTARY_PROFILE:-}" ]] || echo "note: not notarized (set SIGN_IDENTITY and NOTARY_PROFILE for a distributable build)"
