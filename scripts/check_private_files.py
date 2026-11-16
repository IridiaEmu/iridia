#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Checks the commits about to be pushed for anything private. Exit 1 if something is found.

    scripts/check_private_files.py <base>..<ref>      e.g. origin/main..main

Every commit in the range is checked, including files added and later removed:
  - author and committer emails (only the ones in ALLOWED_EMAILS);
  - file names: signing certificates, provisioning profiles, API keys, key files, game files, saves, archives;
  - files over 2 MB (20 MB inside Externals/, which holds other projects' code);
  - images outside ALLOWED_IMAGE_DIRS (screenshots of games are game images);
  - added lines outside Externals/: private keys, App Store Connect keys, passwords and tokens,
    home folder paths, email addresses.
"""
import re
import subprocess
import sys

ALLOWED_EMAILS = {"iridiadev@gmail.com", "243357431+zaptrem4@users.noreply.github.com"}
ALLOWED_IMAGE_DIRS = ("Source/", "Externals/", "Data/", "Installer/", "Readme", "icon-options/")
VENDORED = "Externals/"

BAD_NAMES = re.compile(
    r"(?i)(\.(p12|pfx|p8|pem|cer|der|key|mobileprovision|provisionprofile|keystore|jks)$"
    r"|(^|/)AuthKey_|(^|/)keys?\.(txt|bin)$|(^|/)otp\.bin$|(^|/)seeprom\.bin$|(^|/)nand\.bin$"
    r"|\.(iso|gcm|rvz|wia|gcz|ciso|wbfs|wad|wua|wux|wud|rpx|elf|dol|nkit|tgc)$"
    r"|\.(7z|zip|rar|gz|xz|bz2|tar)$|\.(gci|sav|dtm|sav2|raw)$)")
IMAGE = re.compile(r"(?i)\.(png|jpe?g|gif|heic|webp|bmp|tiff?|mov|mp4|m4v)$")
CONTENT = {
    "private key or certificate": re.compile(r"-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)-----"),
    "App Store Connect key": re.compile(r"AuthKey_[A-Z0-9]{10}|(?i:issuer_?id)\s*[=:]\s*[\"']?[0-9a-f-]{36}"),
    "password or token": re.compile(r"(?i)\b(password|passwd|api[_-]?key|secret|token)\b\s*[=:]\s*[\"'][^\"'\s]{6,}"),
    "home folder path": re.compile(r"/Users/(?!Shared\b)[A-Za-z][\w.-]*"),
    "email address": re.compile(r"[\w.+-]+@[\w-]+\.[A-Za-z][\w.-]*"),
}
SMALL, LARGE = 2_000_000, 20_000_000


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, errors="replace").stdout


def main():
    if len(sys.argv) != 2 or ".." not in sys.argv[1]:
        sys.exit(__doc__)
    span = sys.argv[1]
    problems = []

    for line in git("log", "--format=%h %ae %ce", span).splitlines():
        commit, *emails = line.split()
        for email in emails:
            if email.lower() not in ALLOWED_EMAILS:
                problems.append(f"{commit}: email {email}")

    added = set(git("log", "--format=", "--name-only", "--diff-filter=AMR", span).split("\n")) - {""}
    for name in sorted(added):
        if BAD_NAMES.search(name):
            problems.append(f"file name: {name}")
        if IMAGE.search(name) and not name.startswith(ALLOWED_IMAGE_DIRS):
            problems.append(f"image outside the allowed folders: {name}")

    objects = git("rev-list", "--objects", span)
    sizes = subprocess.run(["git", "cat-file", "--batch-check=%(objecttype) %(objectsize) %(rest)"],
                           input=objects, check=True, capture_output=True, text=True).stdout
    for line in sizes.splitlines():
        kind, size, *path = line.split(" ", 2)
        if kind != "blob" or not path:
            continue
        limit = LARGE if path[0].startswith(VENDORED) else SMALL
        if int(size) > limit:
            problems.append(f"large file ({int(size) / 1e6:.1f} MB): {path[0]}")

    commit = path = None
    for line in git("log", "-p", "--no-color", "--format=COMMIT %h", span, "--", ".", f":!{VENDORED}").splitlines():
        if line.startswith("COMMIT "):
            commit = line.split()[1]
        elif line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("+") and not line.startswith("+++"):
            for label, pattern in CONTENT.items():
                for match in pattern.finditer(line):
                    text = match.group(0)
                    if label == "email address" and (text.lower() in ALLOWED_EMAILS or IMAGE.search(text)):
                        continue
                    problems.append(f"{commit} {path}: {label}: {text[:60]}")

    commits = len(git("rev-list", span).split())
    print(f"checked {commits} commits, {len(added)} files")
    for problem in dict.fromkeys(problems):
        print("FOUND", problem)
    print("RESULT:", "FAIL" if problems else "PASS (nothing private found)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
