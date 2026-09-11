#!/usr/bin/env bash
#
# Copies the built release App Bundle into release_builds/, naming it with the
# app name and version from pubspec.yaml.
#
# Usage: ./copy_aab.sh   (run after `flutter build appbundle --release`)

set -euo pipefail

# Run from the Flutter project root (main/), found by walking up to the nearest
# pubspec.yaml — so this works whether the script sits in main/ or in
# main/.scripts/, and whatever directory it is invoked from.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ "$DIR" != "/" && ! -f "$DIR/pubspec.yaml" ]]; do DIR="$(dirname "$DIR")"; done
cd "$DIR"

AAB="build/app/outputs/bundle/storeRelease/app-store-release.aab"
OUT_DIR="release_builds"

if [[ ! -f "$AAB" ]]; then
  echo "Release App Bundle not found at: $AAB" >&2
  echo "Build it first with: flutter build appbundle --release --flavor store" >&2
  exit 1
fi

# Read app name and version from pubspec.yaml, dropping the "+<build>" suffix
# (e.g. "1.0.7+7" -> "1.0.7") since a '+' in a filename is awkward.
name=$(grep -E '^name:' pubspec.yaml | head -1 | sed -E 's/^name:[[:space:]]*//' | tr -d '[:space:]"')
version=$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//' | tr -d '[:space:]"')
version="${version%%+*}"

if [[ -z "$name" || -z "$version" ]]; then
  echo "Could not read name/version from pubspec.yaml" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

filename="${name}-v${version}.aab"
dest="$OUT_DIR/$filename"

cp -f "$AAB" "$dest"

# No .sha256 alongside the bundle: the AAB goes straight to Play, which verifies
# and re-signs it. A checksum only earns its keep for the APK, which people
# download by hand from GitHub releases.

echo "Copied: $dest"
