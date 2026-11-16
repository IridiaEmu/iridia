#!/usr/bin/env python3
# gc-emu: check that no Nintendo Wii key is in a binary, an app bundle or a source tree.
#   scripts/verify_no_wii_keys.py [--strict] <file or folder>...
#   git archive --format=tar HEAD | scripts/verify_no_wii_keys.py --strict -    (a tar stream on stdin)
# --strict (the public source snapshot, scripts/check_public_snapshot.sh): no folder is skipped, no size
# limit, base64 runs are decoded too, and .zip/.tar/.gz/.tgz/.bz2/.xz files are opened and checked inside.
# Looks for each key as raw bytes, as a hex string and as a C byte list ("0xeb, 0xe4, ..."). The keys
# themselves are not in this script: only a 4-byte prefix and a SHA-256 of each, enough to recognise
# them. Exit 1 if any is found.
import base64, bz2, gzip, hashlib, io, lzma, os, re, sys, tarfile, zipfile

KEYS = [
    ("retail common key", "ebe42a22", 16, "de38aeab4fe0c36d828a47e6fd315100e7ce234d3b00aa25e6ad6f5ff2824af8"),
    ("Korean common key", "63b82bb4", 16, "b9f42ca27a1e178f0f14ebf1a05d486fa8db8d08875336c4e6e8dfae29f2901c"),
    ("RVT common key", "a1604a6a", 16, "5d8ab8193c88627d542cb1130d729e632222011c851ae390976ad7fe237c3a6a"),
    ("SD key", "ab01b9d8", 16, "02c596910cebf5af0a03fe6ab0b36c5ba2a4f2ff49abbf387998c5d31e350666"),
    ("Dolphin default console private key", "00abeec1", 30, "b384bcfe645af50df4f86f6340f484c6ade2a9256810ba2aa7a496c5a84ba0fd"),
]
SKIP_DIRS = {".git", "build", "build-mac", "DerivedData", ".trash"}
C_LIST = re.compile(rb"(?:0x[0-9a-fA-F]{2}\s*,\s*){15,}0x[0-9a-fA-F]{2}")
HEX_RUN = re.compile(rb"[0-9a-fA-F]{32,}")
B64_RUN = re.compile(rb"[A-Za-z0-9+/]{22,}={0,2}")
STRICT = "--strict" in sys.argv
ARGS = [a for a in sys.argv[1:] if a != "--strict"]
if STRICT: SKIP_DIRS = set()

def candidates(data):
    yield data
    for m in C_LIST.finditer(data):
        yield bytes(int(x, 16) for x in re.findall(rb"0x([0-9a-fA-F]{2})", m.group(0)))
    for m in HEX_RUN.finditer(data):
        h = m.group(0)
        if len(h) % 2: h = h[:-1]
        yield bytes.fromhex(h.decode())
    if STRICT:
        for m in B64_RUN.finditer(data):
            for shift in range(4):   # the key may start mid-run; decode from each alignment
                chunk = m.group(0)[shift:]
                chunk = chunk[:len(chunk) - len(chunk) % 4]
                try: yield base64.b64decode(chunk)
                except Exception: pass

def members(path, data, depth=0):
    """(name, bytes) for the file and, in --strict, for everything inside archives it is."""
    yield path, data
    if not STRICT or depth > 3: return
    inner = []
    try:
        if zipfile.is_zipfile(io.BytesIO(data)):
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                inner = [(f"{path}!{i.filename}", z.read(i)) for i in z.infolist() if not i.is_dir()]
        elif data[:2] == b"\x1f\x8b": inner = [(f"{path}!gunzip", gzip.decompress(data))]
        elif data[:3] == b"BZh": inner = [(f"{path}!bunzip2", bz2.decompress(data))]
        elif data[:6] == b"\xfd7zXZ\x00": inner = [(f"{path}!unxz", lzma.decompress(data))]
        elif len(data) > 262 and data[257:262] == b"ustar":
            with tarfile.open(fileobj=io.BytesIO(data)) as t:
                inner = [(f"{path}!{m.name}", t.extractfile(m).read()) for m in t.getmembers() if m.isfile()]
    except Exception as e:
        print(f"WARNING: couldn't open {path} ({e}); its contents were not checked"); global unreadable; unreadable += 1
    for name, blob in inner:
        yield from members(name, blob, depth + 1)

def scan(path, data):
    found = []
    for blob in candidates(data):
        for name, prefix, size, digest in KEYS:
            p = bytes.fromhex(prefix); i = blob.find(p)
            while i != -1:
                if hashlib.sha256(blob[i:i + size]).hexdigest() == digest:
                    found.append(name); break
                i = blob.find(p, i + 1)
    return sorted(set(found))

bad = 0; files = 0; unreadable = 0
if ARGS == ["-"]:
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as stream:
        for m in stream:
            if not m.isfile(): continue
            for name, blob in members(m.name, stream.extractfile(m).read()):
                files += 1
                hits = scan(name, blob)
                if hits:
                    bad += 1; print(f"FOUND in {name}: {', '.join(hits)}")
    ARGS = []
for root in ARGS:
    walk = [(root, [], [os.path.basename(root)])] if os.path.isfile(root) else os.walk(root)
    for d, dirs, names in walk:
        if os.path.isfile(root): d = os.path.dirname(root) or "."
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for n in names:
            p = os.path.join(d, n)
            try:
                if os.path.islink(p): continue
                if not STRICT and os.path.getsize(p) > 512 * 1024 * 1024: continue
                data = open(p, "rb").read()
            except OSError:
                continue
            for name, blob in members(p, data):
                files += 1
                hits = scan(name, blob)
                if hits:
                    bad += 1; print(f"FOUND in {name}: {', '.join(hits)}")
if STRICT and unreadable: bad += unreadable   # an archive we couldn't open is a failure in --strict
print(f"checked {files} files: {'FAIL' if bad else 'PASS (no Wii keys)'}")
sys.exit(1 if bad else 0)
