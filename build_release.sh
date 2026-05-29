#!/bin/bash
set -x
flutter clean
flutter build apk --release
set +x