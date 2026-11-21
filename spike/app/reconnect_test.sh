#!/bin/sh
# Waits for the camera to appear on USB, then runs the viewfinder with SDK auto-reconnect on.
cd "$(dirname "$0")"
echo "waiting for camera on USB..."
until ioreg -p IOUSB -w0 | grep -q "ILCE-"; do sleep 1; done
echo "camera present; giving USB 3s to settle"; sleep 3
CAM_RECONNECT=1 ./run.sh --seconds "${1:-300}"
