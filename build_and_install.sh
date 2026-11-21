#!/usr/bin/env bash
#
# Builds all three release artifacts and puts the dev one on a phone:
#
#   1. store App Bundle  (release_builds/*.aab)  — what goes to Play
#   2. store APK         (release_builds/*.apk)  — the sideloadable release
#   3. dev APK           (installed on the device)
#
# Usage: ./build_and_installs.sh [device-serial]
#   device-serial  optional; needed only when more than one device is connected
#                  (see `adb devices`)
#
# This exists because running build_both.sh and install_release.sh back to back
# costs a **full clean you don't need**. build_both.sh opens with `flutter
# clean`, which deletes build/.last_build_pubspec_lock_sha — the stamp
# install_release.sh reads to decide whether a clean is required. With the stamp
# gone, install_release.sh sees "no record of a build" and cleans again, throwing
# away the plugin modules build_both.sh just compiled and turning a ~70s dev
# build into a ~108s one. Whichever order you run them in, one clean is wasted.
#
# Here the clean happens once, inside build_both.sh, and all three builds run on
# that one clean tree. Which is safe for exactly the reason the stamp exists: the
# trap it guards against is a *dependency* change (Gradle keys its per-module
# build directory by plugin name, not version, so a bump silently reuses the
# previous version's classes while the manifest merges fresh). pubspec.lock
# cannot change in the middle of this script, so one clean at the top covers
# every build below it.
#
# Nothing is duplicated from the other two scripts on purpose. The ABI list in
# particular lives in build_both.sh and nowhere else: it has to move in step
# with the packaging.jniLibs filter in android/app/build.gradle.kts, and a second
# copy here is exactly how those two drift apart. Device discovery, the
# multiple-device check and the install itself are likewise install_release.sh's,
# reached with --no-build.

set -euo pipefail

# Run from this script's directory (the Flutter project root, main/) so it works
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERIAL="${1:-}"

# Fail before the long builds rather than after them, since the whole point of
# this script is the install at the end. A missing device after a four-minute
# release build is the one outcome worth spending a check to avoid.
if [[ ! -x "./build_both.sh" || ! -x "./install_release.sh" ]]; then
  echo "build_both.sh and install_release.sh must be present and executable beside this script." >&2
  exit 1
fi

echo "==> 1/3 + 2/3: store App Bundle and store APK (clean build)"
./build_both.sh

echo
echo "==> 3/3: dev APK"
# arm64 only, matching install_release.sh — this build is for the developer's own
# phone, so the 32-bit and x86_64 slices the store artifacts carry would cost
# time and size for devices that are never targeted. Keep this line in step with
# install_release.sh's.
set -x
flutter build apk --release --flavor dev --target-platform android-arm64
set +x

# Record the lock the (successful, post-clean) build was made from, so the next
# plain `./install_release.sh` doesn't clean needlessly. Written here rather than
# in build_both.sh so that script keeps its current behaviour; only after the
# build succeeds, so a failure leaves the stamp stale and the next run cleans —
# the harmless direction.
STAMP="build/.last_build_pubspec_lock_sha"
mkdir -p "$(dirname "$STAMP")"
printf '%s' "$(sha256sum pubspec.lock | cut -d' ' -f1)" > "$STAMP"

echo
echo "==> Installing the dev APK"
# --no-build: the APK was just built above. install_release.sh owns adb
# discovery, the connected-device count and the "pass a serial" guidance, and
# installs the *dev* package only — the store APK is signed with the local
# release key while Play re-signs what it distributes, so putting it on a phone
# makes the Play build un-installable over it.
if [[ -n "$SERIAL" ]]; then
  ./install_release.sh --no-build "$SERIAL"
else
  ./install_release.sh --no-build
fi

echo
echo "Done. Store artifacts are in release_builds/ (with .sha256 checksums); the dev build is on the device."
