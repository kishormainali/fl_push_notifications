#!/usr/bin/env bash
# Fails unless CHANGELOG.md has a heading for VERSION: "## VERSION" or
# "## [VERSION]" (the same forms the release-notes step extracts).
# Usage: tool/check_changelog.sh VERSION   (run from anywhere)
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

version="$1"
changelog="$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md"

if [ ! -f "$changelog" ]; then
  echo "CHANGELOG.md not found at $changelog" >&2
  exit 1
fi

# Fixed-string, whole-line match (no regex, so dots in the version are literal).
if grep -Fxq "## $version" "$changelog" || grep -Fxq "## [$version]" "$changelog"; then
  echo "CHANGELOG.md has an entry for $version"
else
  echo "CHANGELOG.md has no '## $version' (or '## [$version]') heading; add one before tagging v$version" >&2
  exit 1
fi
