#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Pack the complete corresponding source of the current commit for a release (GPL v2 §3(b) written
# offer). Run it for every build you ship and keep each archive for at least three years.
#   scripts/make_source_bundle.sh [out-dir]     (default: ~/Projects/iridia-source-releases)
# Includes every tracked file of the repo and all submodules (git ls-files --recurse-submodules),
# so build scripts, Tuist project, vendored packages and the PGO profile are in it. Untracked and
# ignored files (your games, saves, build output) never are. Refuses to run with uncommitted
# changes, so the archive always matches a commit.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HOME/Projects/iridia-source-releases}"
cd "$ROOT"

if [[ -n "$(git status --porcelain --ignore-submodules=none -uno)" ]]; then
  echo "Uncommitted changes: commit first so the archive matches a commit." >&2
  exit 1
fi
git lfs pull >/dev/null 2>&1 || true   # make sure LFS files (pgo/icube.profdata) are real content

COMMIT="$(git rev-parse --short=12 HEAD)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Source/iOS/App/DolphiniOS/Info.plist 2>/dev/null || echo unknown)"
case "$VERSION" in *'$('*) VERSION="$(grep -m1 -E '^MARKETING_VERSION *=' -r Source/iOS/App/Project/Config 2>/dev/null | sed 's/.*= *//' || echo unknown)";; esac
NAME="iridia-${VERSION:-unknown}-${COMMIT}-source"
mkdir -p "$OUT"
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT

git ls-files --recurse-submodules -z > "$LIST"
cat > "$OUT/$NAME.README.txt" <<EOF
Iridia complete corresponding source code
Commit: $(git rev-parse HEAD)
Version: $VERSION
Licence: GNU GPL v2 or later (see COPYING and LICENSES/ inside the archive).
Build instructions: BUILDING.md inside the archive.
EOF

tar --null -T "$LIST" -cf - | xz -T0 -6 > "$OUT/$NAME.tar.xz"
shasum -a 256 "$OUT/$NAME.tar.xz" > "$OUT/$NAME.tar.xz.sha256"
echo "wrote $OUT/$NAME.tar.xz ($(du -h "$OUT/$NAME.tar.xz" | cut -f1))"
