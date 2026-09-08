#!/bin/bash
set -x
flutter clean
flutter build appbundle --release --flavor store
set +x
