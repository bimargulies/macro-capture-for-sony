#!/bin/sh
# Build Capture Viewfinder.app (release) into build/.
# Signing identity: SIGN_ID env var (default "-" = ad hoc). Hardened runtime is on.
set -e
cd "$(dirname "$0")"
SIGN_ID="${SIGN_ID:--}"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Viewfinder"
APP="build/Capture Viewfinder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks/CrAdapter"
cp "$BIN" "$APP/Contents/MacOS/Viewfinder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sony SDK libraries: main dylibs in Frameworks, adapters in Frameworks/CrAdapter.
cp sdk/external/crsdk/*.dylib "$APP/Contents/Frameworks/"
cp sdk/external/crsdk/CrAdapter/*.dylib "$APP/Contents/Frameworks/CrAdapter/"
xattr -cr "$APP"   # drop quarantine from the SDK copies
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Viewfinder"
# Sign inside-out: libraries first, then the app.
for f in "$APP"/Contents/Frameworks/CrAdapter/*.dylib "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force --options runtime --sign "$SIGN_ID" "$f"
done
codesign --force --options runtime --entitlements Resources/Viewfinder.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "built and signed: $APP (identity: $SIGN_ID)"
