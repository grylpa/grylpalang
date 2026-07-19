#!/bin/bash
set -x
flutter clean
flutter build appbundle --release
flutter build apk --release
set +x
