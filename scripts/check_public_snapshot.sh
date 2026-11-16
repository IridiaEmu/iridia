#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# check_public_snapshot.sh: the release gate for the public source. Fails (exit 1) if a Nintendo Wii key
# is anywhere in what would be published.
#
#   scripts/check_public_snapshot.sh <snapshot repo>    # the one-commit repo that will be pushed
#   scripts/check_public_snapshot.sh --tree <git ref>   # dry run on a ref of this repo (no history check)
#   scripts/check_public_snapshot.sh --push <base>..<ref>   # before every push, e.g. origin/main..main
#
# --push runs scripts/check_private_files.py on every commit in the range (signing files, API keys,
# passwords, key files, game files and images, home paths, other emails, large files), then the Wii key
# check on <ref>'s files. The key check applies from version 1.2 on: 1.1.x shipped with Dolphin's keys
# in IOSC.cpp, and its published source has to match the app.
#
# The public source is one clean snapshot commit, never our private history (old commits hold the keys).
# For a snapshot repo this checks:
#   1. exactly one commit is reachable from every branch and tag (no private history comes along);
#   2. the working tree matches that commit (what is checked is what is pushed);
#   3. every file in the commit, with scripts/verify_no_wii_keys.py --strict: no folders skipped, no size
#      limit, base64 decoded, zip/tar/gzip/bzip2/xz opened and checked inside;
#   4. checked-out submodules too, if any (they are listed so you can see what else is published).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/verify_no_wii_keys.py"

# Prints the app version (MARKETING_VERSION) at a ref, and succeeds if it is 1.2 or later.
keys_checked_from_1_2() {
  local version
  version=$(git -C "$1" show "$2:Source/iOS/App/Project.swift" 2>/dev/null \
    | sed -n 's/.*"MARKETING_VERSION": "\([0-9.]*\)".*/\1/p' | head -1)
  echo "app version at $2: ${version:-unknown}"
  [ -z "$version" ] && return 0
  local major minor
  IFS=. read -r major minor _ <<< "$version"
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "${minor:-0}" -ge 2 ]; }
}

if [ "${1:-}" = "--tree" ]; then
  ref="${2:?usage: $0 --tree <git ref>}"
  if ! keys_checked_from_1_2 "$here/.." "$ref"; then
    echo "skipped: the Wii key check applies from 1.2 on"
    exit 0
  fi
  echo "== files in $ref (dry run, history not checked)"
  git -C "$here/.." archive --format=tar "$ref" | python3 -I "$check" --strict -
  exit $?
fi

if [ "${1:-}" = "--push" ]; then
  span="${2:?usage: $0 --push <base>..<ref>}"
  ref="${span#*..}"
  fail=0
  echo "== private files in $span"
  python3 -I "$here/check_private_files.py" "$span" || fail=1
  echo "== Wii keys in $ref"
  if keys_checked_from_1_2 . "$ref"; then
    git archive --format=tar "$ref" | python3 -I "$check" --strict - || fail=1
  else
    echo "skipped: the Wii key check applies from 1.2 on"
  fi
  echo
  if [ "$fail" = 0 ]; then echo "RESULT: PASS (safe to push)"; else echo "RESULT: FAIL (don't push)"; fi
  exit $fail
fi

repo="${1:?usage: $0 <snapshot repo> | --tree <git ref>}"
fail=0
echo "== history"
commits=$(git -C "$repo" rev-list --all | wc -l | tr -d ' ')
if [ "$commits" != "1" ]; then
  echo "FAIL: $commits commits are reachable from the branches and tags; the snapshot must have exactly 1"
  fail=1
else
  echo "ok: one commit ($(git -C "$repo" rev-parse --short HEAD))"
fi
echo "== working tree"
if [ -n "$(git -C "$repo" status --porcelain --ignored=no)" ]; then
  echo "FAIL: the working tree has changes that are not in the commit"
  git -C "$repo" status --short | head -20
  fail=1
else
  echo "ok: clean"
fi
echo "== files in the commit"
git -C "$repo" archive --format=tar HEAD | python3 -I "$check" --strict - || fail=1
if [ -f "$repo/.gitmodules" ]; then
  echo "== submodules (published from their own repos)"
  git -C "$repo" submodule status || true
  while read -r path; do
    [ -d "$repo/$path" ] && { python3 -I "$check" --strict "$repo/$path" || fail=1; }
  done < <(git -C "$repo" config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}')
fi
echo
if [ "$fail" = 0 ]; then echo "RESULT: PASS (snapshot has no Wii keys)"; else echo "RESULT: FAIL"; fi
exit $fail
