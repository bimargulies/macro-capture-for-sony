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
# ExifTool (a Perl script plus its library folder), run by the app with the system Perl.
# Taken from the installed copy (Homebrew layout or the stock distribution layout).
EXIF="$(command -v exiftool || true)"
if [ -z "$EXIF" ]; then echo "exiftool not found; install it (brew install exiftool) so it can be bundled" >&2; exit 1; fi
EXIF_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EXIF")"
EXIF_DIR="$(dirname "$EXIF_REAL")"
# Homebrew's bin/exiftool is a wrapper; the real script and library are under libexec.
for d in "$EXIF_DIR" "$EXIF_DIR/../libexec/bin"; do
    if [ -f "$d/exiftool" ] && [ -d "$d/lib/Image" ]; then EXIF_REAL="$d/exiftool"; EXIF_LIB="$d/lib"; break; fi
    if [ -f "$d/exiftool" ] && [ -d "$d/../lib/perl5/Image" ]; then EXIF_REAL="$d/exiftool"; EXIF_LIB="$d/../lib/perl5"; break; fi
done
if [ -z "${EXIF_LIB:-}" ]; then echo "cannot find ExifTool's script and Image/ library near $EXIF_REAL" >&2; exit 1; fi
mkdir -p "$APP/Contents/Resources/exiftool/lib"
cp "$EXIF_REAL" "$APP/Contents/Resources/exiftool/exiftool"
cp -R "$EXIF_LIB/Image" "$APP/Contents/Resources/exiftool/lib/"
mkdir -p "$APP/Contents/Resources/exiftool/lib/File"
cp "$EXIF_LIB/File/RandomAccess.pm" "$APP/Contents/Resources/exiftool/lib/File/"
cat > "$APP/Contents/Resources/exiftool/NOTICE.txt" <<'NOTICE'
This folder contains ExifTool by Phil Harvey (https://exiftool.org), distributed under the same
terms as Perl itself (the Artistic License or the GNU GPL). It is run by the app, not modified.
NOTICE
# Prove it runs on its own with a clean environment (no Homebrew, no PERL5LIB).
EXIF_VER="$(env -i /usr/bin/perl "$APP/Contents/Resources/exiftool/exiftool" -ver)" || { echo "bundled ExifTool does not run" >&2; exit 1; }
echo "bundled ExifTool $EXIF_VER"

xattr -cr "$APP"   # drop quarantine from the SDK copies
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Viewfinder"
# Sign inside-out: libraries first, then the app.
for f in "$APP"/Contents/Frameworks/CrAdapter/*.dylib "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force --options runtime --sign "$SIGN_ID" "$f"
done
codesign --force --options runtime --entitlements Resources/Viewfinder.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "built and signed: $APP (identity: $SIGN_ID)"
