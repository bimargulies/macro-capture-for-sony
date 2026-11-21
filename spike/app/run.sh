#!/bin/sh
# Build and run the viewfinder spike. Extra args go to the app (e.g. --seconds 15).
set -e
cd "$(dirname "$0")"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
# The SDK expects its dylibs next to the executable and adapters in Contents/Frameworks/CrAdapter.
cp -R sdk/external/crsdk/. "$BIN/"
mkdir -p "$BIN/Contents/Frameworks/CrAdapter"
cp -R sdk/external/crsdk/CrAdapter/. "$BIN/Contents/Frameworks/CrAdapter/"
exec "$BIN/Viewfinder" "$@"
