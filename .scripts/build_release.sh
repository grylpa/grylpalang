#!/usr/bin/env bash
# ARM-only: --target-platform drops x86_64 (emulators/ChromeOS), which we don't
# target. Matches build_both.sh.
set -euo pipefail

# Run from the Flutter project root (main/), found by walking up to the nearest
# pubspec.yaml — so this works whether the script sits in main/ or in
# main/.scripts/, and whatever directory it is invoked from.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ "$DIR" != "/" && ! -f "$DIR/pubspec.yaml" ]]; do DIR="$(dirname "$DIR")"; done
cd "$DIR"

set -x
flutter clean
flutter build apk --release --flavor store --target-platform android-arm,android-arm64
set +x
