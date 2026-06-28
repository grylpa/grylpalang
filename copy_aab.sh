#!/usr/bin/env bash
#
# Copies the built release App Bundle into release_builds/, naming it with the
# app name and version from pubspec.yaml, and writes a matching .sha256 checksum
# file.
#
# Usage: ./copy_aab.sh   (run after `flutter build appbundle --release`)

set -euo pipefail

# Resolve the directory this script lives in (the Flutter project root, main/),
# so it works regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AAB="build/app/outputs/bundle/release/app-release.aab"
OUT_DIR="release_builds"

if [[ ! -f "$AAB" ]]; then
  echo "Release App Bundle not found at: $AAB" >&2
  echo "Build it first with: flutter build appbundle --release" >&2
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

# Write the checksum from inside OUT_DIR so the .sha256 references just the
# filename (makes `sha256sum -c "$filename.sha256"` work from that directory).
( cd "$OUT_DIR" && sha256sum "$filename" > "$filename.sha256" )

echo "Copied: $dest"
echo "SHA256: $(cut -d' ' -f1 < "$dest.sha256")  ($filename.sha256)"
