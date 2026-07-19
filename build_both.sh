#!/bin/bash
set -euo pipefail

# Run from this script's directory (the Flutter project root, main/) so it works
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

set -x
flutter clean
flutter build appbundle --release
flutter build apk --release
set +x

# Both builds succeeded (set -e would have aborted otherwise) — copy the
# artifacts into release_builds/ with versioned names + checksums.
./copy_aab.sh
./copy_release.sh
