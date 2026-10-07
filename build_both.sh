#!/bin/bash
set -euo pipefail

# Run from this script's directory (the Flutter project root, main/) so it works
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Every ABI Flutter can build an engine for. x86_64 covers Chromebooks, Intel
# tablets and emulators: no plugin in this project is ARM-only (the only native
# plugin libs, libdartjni.so and libdatastore_shared_counter.so, ship x86_64),
# and flutter_tts/just_audio/audio_service are Java wrappers over platform APIs,
# so nothing about the audio path is architecture-bound.
#
# Keep this list and the packaging.jniLibs filter in android/app/build.gradle.kts
# in step. Narrowing one without the other is what produced an x86_64 slice with
# plugin libs and no Flutter engine — an artifact Play treats as x86_64-capable
# and installs on devices it then crashes on.
#
# 32-bit x86 is deliberately absent: Flutter has no android-x86 target, so it
# could never have an engine. build.gradle.kts filters it out of the packaging.
ABIS="android-arm,android-arm64,android-x64"

set -x
flutter clean
flutter build appbundle --release --flavor store --target-platform "$ABIS"
flutter build apk --release --flavor store --target-platform "$ABIS"
set +x

# Both builds succeeded (set -e would have aborted otherwise) — copy the
# artifacts into release_builds/ with versioned names + checksums. They live in
# .scripts/ (not run directly), with a fallback for when they sit beside this.
HELPERS=".scripts"
[[ -x "$HELPERS/copy_aab.sh" ]] || HELPERS="."
"$HELPERS/copy_aab.sh"
"$HELPERS/copy_release.sh"
