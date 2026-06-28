#!/bin/bash
set -x
flutter clean
flutter build appbundle --release
set +x
