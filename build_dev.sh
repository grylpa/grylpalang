#!/bin/bash
# The dev APK: a *release* build (not debug) of the `dev` flavor, so it behaves
# like the shipped app but installs under com.grylpa.katalaveno.dev, beside the
# Play version, with its own data and its own launcher icon labelled
# "KataDev".
#
# ARM-only, matching build_release.sh.
set -x
flutter build apk --release --flavor dev --target-platform android-arm,android-arm64
set +x
