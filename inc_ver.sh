#!/usr/bin/env bash
#
# Increment the app version in this repo's pubspec.yaml.
#
#   ./inc_ver.sh           patch:  X.Y.Z -> X.Y.(Z+1)
#   ./inc_ver.sh --minor   minor:  X.Y.Z -> X.(Y+1).0
#   ./inc_ver.sh --major   major:  (X+1).0.0
#
# Follows semver: bumping minor resets patch to 0; bumping major resets minor
# and patch to 0. The Android version code (the "+build" suffix) is derived from
# the semver as:
#
#   code = max(0, major - 1) * 100000 + minor * 1000 + patch
#
# so the written version is X.Y.Z+<code>. This is required because without a
# "+build" Flutter defaults the version code to 1 and the Play Store rejects the
# upload with "Version code 1 has already been used." The formula is monotonically
# increasing across patch/minor/major bumps (minor < 100, patch < 1000 assumed),
# so every kind of bump yields a higher code than the previous one.
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

major_component=$(( major > 1 ? major - 1 : 0 ))
code=$(( major_component * 100000 + minor * 1000 + patch ))
new="${major}.${minor}.${patch}+${code}"

tmp=$(mktemp)
sed -E "s/^version:[[:space:]].*/version: ${new}/" "$PUBSPEC" > "$tmp"
mv "$tmp" "$PUBSPEC"

echo "version: ${current} -> ${new}"
