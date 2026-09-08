#!/usr/bin/env bash
#
# Builds the dev APK and installs it on a connected Android device via adb.
#
# Usage: ./install_release.sh [--no-build] [device-serial]
#   --no-build     skip the build, install whatever was built last
#   device-serial  optional; needed only when more than one device is connected
#                  (see `adb devices`)
#
# The dev flavor is a *release* build under com.grylpa.katalaveno.dev, labelled
# "KataDev", with its own data — so it sits beside the Play version instead of
# replacing it.
#
# arm64 only: this build is for the developer's own phone, not for users, so
# there is no reason to carry the 32-bit slice that build_release.sh ships for
# older devices. It builds faster and installs smaller.
#
# Dev only, deliberately. The store APK built here is signed with the local
# release key while Play re-signs what it distributes, so installing it would
# make the Play version un-installable over it — the only way out being an
# uninstall, which takes the app's data with it. If you ever genuinely need to
# check the store artifact, `adb install` it by hand on a phone you don't mind
# wiping.

set -euo pipefail

# Resolve the directory this script lives in (the Flutter project root, main/),
# so it works regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE="com.grylpa.katalaveno.dev"
APK="build/app/outputs/flutter-apk/app-dev-release.apk"

# Parse args: --no-build flag plus an optional device serial.
BUILD=1
SERIAL=""
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *) SERIAL="$arg" ;;
  esac
done

if [[ "$BUILD" -eq 1 ]]; then
  set -x
  flutter build apk --release --flavor dev --target-platform android-arm64
  set +x
fi

if [[ ! -f "$APK" ]]; then
  echo "Dev APK not found at: $APK" >&2
  echo "Run without --no-build to build it first." >&2
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
  echo "Multiple devices connected; pass a serial: ./install_release.sh [--no-build] <serial>" >&2
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
