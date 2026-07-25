#!/bin/bash
set -euo pipefail

# Run from this script's directory (the Flutter project root, main/) so it works
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ARM-only build: --target-platform drops x86_64 (android-x64) from both the
# .aab (smaller Play upload) and the .apk. The app supports ARM devices only —
# x86_64 is emulators/ChromeOS, which we don't target.
ABIS="android-arm,android-arm64"

set -x
flutter clean
flutter build appbundle --release --target-platform "$ABIS"
flutter build apk --release --target-platform "$ABIS"
set +x

# Both builds succeeded (set -e would have aborted otherwise) — copy the
# artifacts into release_builds/ with versioned names + checksums.
./copy_aab.sh
./copy_release.sh
