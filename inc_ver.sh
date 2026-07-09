#!/usr/bin/env bash
#
# Increment the app version in this repo's pubspec.yaml.
#
#   ./inc_ver.sh           patch:  X.Y.Z -> X.Y.(Z+1)
#   ./inc_ver.sh --minor   minor:  X.Y.Z -> X.(Y+1).0
#   ./inc_ver.sh --major   major:  (X+1).0.0
#
# Follows semver: bumping minor resets patch to 0; bumping major resets minor
# and patch to 0. Versions are kept as X.Y.Z (any "+build" suffix is dropped).
set -euo pipefail

cd "$(dirname "$0")"
PUBSPEC="pubspec.yaml"

part="patch"
case "${1:-}" in
  "")      part="patch" ;;
  --minor) part="minor" ;;
  --major) part="major" ;;
  *) echo "Usage: $(basename "$0") [--minor|--major]" >&2; exit 1 ;;
esac

line=$(grep -E '^version:[[:space:]]' "$PUBSPEC" | head -1 || true)
if [ -z "$line" ]; then
  echo "No 'version:' line found in $PUBSPEC" >&2
  exit 1
fi

current=$(echo "$line" | sed -E 's/^version:[[:space:]]*//')
semver="${current%%+*}"                       # 1.2.3 (drop any "+build")

IFS='.' read -r major minor patch <<< "$semver"

case "$part" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac

new="${major}.${minor}.${patch}"

tmp=$(mktemp)
sed -E "s/^version:[[:space:]].*/version: ${new}/" "$PUBSPEC" > "$tmp"
mv "$tmp" "$PUBSPEC"

echo "version: ${current} -> ${new}"
