#!/bin/bash
# ARM-only: --target-platform drops x86_64 (emulators/ChromeOS), which we don't
# target. Matches build_both.sh.
set -x
flutter clean
flutter build apk --release --target-platform android-arm,android-arm64
set +x
