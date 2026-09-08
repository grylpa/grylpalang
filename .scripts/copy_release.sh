#!/usr/bin/env bash
#
# Copies the built release APK into release_builds/, naming it with the app name
# and version from pubspec.yaml, and writes a matching .sha256 checksum file.
#
# Usage: ./copy_release.sh   (run after `flutter build apk --release`)

set -euo pipefail

# Run from the Flutter project root (main/), found by walking up to the nearest
# pubspec.yaml — so this works whether the script sits in main/ or in
# main/.scripts/, and whatever directory it is invoked from.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ "$DIR" != "/" && ! -f "$DIR/pubspec.yaml" ]]; do DIR="$(dirname "$DIR")"; done
cd "$DIR"

APK="build/app/outputs/flutter-apk/app-store-release.apk"
OUT_DIR="release_builds"

if [[ ! -f "$APK" ]]; then
  echo "Release APK not found at: $APK" >&2
  echo "Build it first with: flutter build apk --release --flavor store" >&2
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

filename="${name}-v${version}.apk"
dest="$OUT_DIR/$filename"

cp -f "$APK" "$dest"

# Write the checksum from inside OUT_DIR so the .sha256 references just the
# filename (makes `sha256sum -c "$filename.sha256"` work from that directory).
( cd "$OUT_DIR" && sha256sum "$filename" > "$filename.sha256" )

echo "Copied: $dest"
echo "SHA256: $(cut -d' ' -f1 < "$dest.sha256")  ($filename.sha256)"
