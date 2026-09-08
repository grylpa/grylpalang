#!/usr/bin/env bash
#
# Installs a release APK onto a connected Android device via adb.
#
# Usage: ./install_release.sh [--dev|--store] [--build] [device-serial]
#   --dev          the dev flavor: com.grylpa.katalaveno.dev, "Katalaveno Dev",
#                  its own data, installs beside the Play version (default)
#   --store        the store flavor: the published application ID. Only install
#                  this if you are NOT running the Play build on this device —
#                  it is the same package, so it replaces it.
#   --build        build the APK first (build_dev.sh / build_release.sh)
#   device-serial  optional; needed only when more than one device is connected
#                  (see `adb devices`)

set -euo pipefail

# Resolve the directory this script lives in (the Flutter project root, main/),
# so it works regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Parse args: flavor and --build flags, plus an optional device serial.
FLAVOR="dev"
BUILD=0
SERIAL=""
for arg in "$@"; do
  case "$arg" in
    --dev) FLAVOR="dev" ;;
    --store) FLAVOR="store" ;;
    --build) BUILD=1 ;;
    *) SERIAL="$arg" ;;
  esac
done

if [[ "$FLAVOR" == "dev" ]]; then
  PACKAGE="com.grylpa.katalaveno.dev"
  APK="build/app/outputs/flutter-apk/app-dev-release.apk"
  BUILD_SCRIPT="build_dev.sh"
else
  PACKAGE="com.grylpa.katalaveno"
  APK="build/app/outputs/flutter-apk/app-store-release.apk"
  BUILD_SCRIPT="build_release.sh"
fi

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building $FLAVOR release APK ..."
  "$SCRIPT_DIR/$BUILD_SCRIPT"
fi

if [[ ! -f "$APK" ]]; then
  echo "Release APK not found at: $APK" >&2
  echo "Build it first: ./$BUILD_SCRIPT  (or pass --build)" >&2
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
  echo "Multiple devices connected; pass a serial: ./install_release.sh [--dev|--store] [--build] <serial>" >&2
  "$ADB" devices >&2
  exit 1
fi

echo "Installing $APK as $PACKAGE ..."
# -r reinstalls keeping app data. If install fails with a signature mismatch
# (e.g. a debug build is already installed), uninstall it first:
#   adb uninstall $PACKAGE
if [[ -n "$SERIAL" ]]; then
  "$ADB" -s "$SERIAL" install -r "$APK"
else
  "$ADB" install -r "$APK"
fi
echo "Installed."
