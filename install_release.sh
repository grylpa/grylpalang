#!/usr/bin/env bash
#
# Installs the release APK onto a connected Android device via adb.
#
# Usage: ./install_release.sh [--build] [device-serial]
#   --build        build the release APK first (runs ./build_release.sh)
#   device-serial  optional; needed only when more than one device is connected
#                  (see `adb devices`)

set -euo pipefail

# Resolve the directory this script lives in (the Flutter project root, dlom/),
# so it works regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE="com.dlom.dlom"
APK="build/app/outputs/flutter-apk/app-release.apk"

# Parse args: --build flag plus an optional device serial.
BUILD=0
SERIAL=""
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;;
    *) SERIAL="$arg" ;;
  esac
done

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building release APK ..."
  "$SCRIPT_DIR/build_release.sh"
fi

if [[ ! -f "$APK" ]]; then
  echo "Release APK not found at: $APK" >&2
  echo "Build it first: ./build_release.sh  (or pass --build)" >&2
  exit 1
fi

# Locate adb: PATH first, then the common Android SDK location.
ADB="$(command -v adb || true)"
if [[ -z "$ADB" && -x "$HOME/Android/Sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Android/Sdk/platform-tools/adb"
fi
if [[ -z "$ADB" ]]; then
  echo "adb not found. Install Android platform-tools or add adb to PATH." >&2
  exit 1
fi

# Count connected devices (state == "device").
device_count=$("$ADB" devices | awk 'NR>1 && $2=="device"' | wc -l)
if [[ "$device_count" -eq 0 ]]; then
  echo "No connected device found. Plug one in / start an emulator:" >&2
  "$ADB" devices >&2
  exit 1
fi
if [[ "$device_count" -gt 1 && -z "$SERIAL" ]]; then
  echo "Multiple devices connected; pass a serial: ./install_release.sh [--build] <serial>" >&2
  "$ADB" devices >&2
  exit 1
fi

echo "Installing $APK ..."
# -r reinstalls keeping app data. If install fails with a signature mismatch
# (e.g. a debug build is already installed), uninstall it first:
#   adb uninstall $PACKAGE
if [[ -n "$SERIAL" ]]; then
  "$ADB" -s "$SERIAL" install -r "$APK"
else
  "$ADB" install -r "$APK"
fi
echo "Installed."
