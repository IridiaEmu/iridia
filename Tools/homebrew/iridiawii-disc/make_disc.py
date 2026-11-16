#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Iridia test Wii disc: packs one of our own Wii programs into a Wii disc, made only from our own
# parts (the Iridia test apploader in source/, a disc header, and a ticket and TMD written here).
#
# The disc is encrypted, like a real Wii disc, but with a TEST common key that this script makes up
# (random, saved next to the output) and that no Wii has. So it tests Iridia's key rules end to end:
#   - the encrypted ISO and WBFS need a keys.bin (here the test one) to play,
#   - the RVZ made from it plays with no key at all.
# No Nintendo key, file or code is used or needed.
#
#   make_disc.py <main.dol> <out dir> [--id DIRB00] [--title "Iridia Wii Test"]
#                [--tool path/to/dolphin-tool]
# Writes <out>/folder (the extracted disc), <out>/keys/Wii/keys.bin (the test key in BootMii dump
# layout), <out>/<id>.iso, .wbfs, .rvz. dolphin-tool doesn't write WBFS, so iso_to_wbfs() below does
# (the single-file layout Dolphin's WbfsBlob.cpp reads).
import argparse, os, shutil, struct, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("dol"); ap.add_argument("out")
ap.add_argument("--id", default="DIRB00"); ap.add_argument("--title", default="Iridia Wii Test")
ap.add_argument("--tool", default=os.path.join(here, "../../../build-mac/Binaries/dolphin-tool"))
a = ap.parse_args()
assert len(a.id) == 6

def aes_cbc_encrypt(key, iv, data):
    return subprocess.run(["openssl", "enc", "-aes-128-cbc", "-nopad", "-K", key.hex(), "-iv", iv.hex()],
                          input=data, capture_output=True, check=True).stdout

def build_apploader():
    b = os.path.join(here, "build"); os.makedirs(b, exist_ok=True)
    env = dict(os.environ, PATH="/opt/devkitpro/devkitPPC/bin:" + os.environ["PATH"])
    run = lambda *c: subprocess.run(c, check=True, env=env)
    run("powerpc-eabi-gcc", "-O2", "-mcpu=750", "-meabi", "-mhard-float", "-mno-sdata", "-ffreestanding",
        "-fno-builtin", "-nostdlib", "-Wall", "-c", os.path.join(here, "source/apploader.c"), "-o", b + "/apploader.o")
    run("powerpc-eabi-ld", "-T", os.path.join(here, "source/apploader.ld"), b + "/apploader.o", "-o", b + "/apploader.elf")
    run("powerpc-eabi-objcopy", "-O", "binary", b + "/apploader.elf", b + "/apploader.raw")
    body = open(b + "/apploader.raw", "rb").read()
    body += b"\0" * (-len(body) % 32)
    # Header: build date (16 bytes), entry point, size, trailer size, padding.
    return b"2026/11/10\0\0\0\0\0\0" + struct.pack(">III", 0x81200000, len(body), 0) + b"\0" * 4 + body

out = os.path.abspath(a.out)
folder = os.path.join(out, "folder"); data = os.path.join(folder, "DATA")
if os.path.exists(folder):
    sys.exit(f"{folder} exists; pick a new output folder")
for d in ("sys", "files", "disc"):
    os.makedirs(os.path.join(data, d))

gid = a.id.encode()
# Disc header (boot.bin): ID, Wii magic, title. Dolphin fills in the DOL and FST offsets.
boot = bytearray(0x440)
boot[0:6] = gid
struct.pack_into(">I", boot, 0x18, 0x5D1C9EA3)
boot[0x20:0x20 + len(a.title)] = a.title.encode()
open(os.path.join(data, "sys/boot.bin"), "wb").write(boot)
bi2 = bytearray(0x2000)
struct.pack_into(">I", bi2, 0x18, 1)  # region: Americas
open(os.path.join(data, "sys/bi2.bin"), "wb").write(bi2)
open(os.path.join(data, "sys/apploader.img"), "wb").write(build_apploader())
shutil.copy(a.dol, os.path.join(data, "sys/main.dol"))
open(os.path.join(data, "files/iridia.txt"), "w").write("Iridia test disc. Original program; no Nintendo content.\n")
open(os.path.join(data, "disc/header.bin"), "wb").write(bytes(boot[:0x100]))
region = bytearray(0x20); struct.pack_into(">I", region, 0, 1); region[0x10:0x20] = b"\x80" * 16
open(os.path.join(data, "disc/region.bin"), "wb").write(region)

title_id = struct.pack(">I", 0x00010000) + gid[:4]
test_common_key = os.urandom(16)
title_key = os.urandom(16)

def signed_header(issuer):
    return struct.pack(">I", 0x00010001) + b"\0" * 0x100 + b"\0" * 0x3C + issuer.encode().ljust(0x40, b"\0")

# Ticket (0x2A4): title key encrypted with the test common key, IV = title ID.
t = bytearray(0x2A4)
t[0:0x180] = signed_header("Root-CA00000001-XS00000003")
t[0x1BF:0x1CF] = aes_cbc_encrypt(test_common_key, title_id + b"\0" * 8, title_key)
t[0x1DC:0x1E4] = title_id
struct.pack_into(">H", t, 0x1E4, 0xFFFF)       # access mask
t[0x1F1] = 0                                     # common key index 0 (retail)
t[0x222:0x262] = b"\xFF" * 0x40                  # every content may be read
open(os.path.join(data, "ticket.bin"), "wb").write(t)

# TMD (0x1E4 header + one content record).
m = bytearray(0x1E4 + 0x24)
m[0:0x180] = signed_header("Root-CA00000001-CP00000004")
struct.pack_into(">Q", m, 0x184, 0x000000010000003A)  # runs on IOS58
m[0x18C:0x194] = title_id
struct.pack_into(">I", m, 0x194, 1)
m[0x198:0x19A] = gid[4:6]
struct.pack_into(">H", m, 0x19C, 1)  # region: Americas
struct.pack_into(">HH", m, 0x1DE, 1, 0)  # one content, boot index 0
struct.pack_into(">IHHQ", m, 0x1E4, 0, 0, 3, 0)
open(os.path.join(data, "tmd.bin"), "wb").write(m)
open(os.path.join(data, "cert.bin"), "wb").write(b"")

# The test key as a BootMii-layout keys.bin (common key at 0x114), for the "with keys" runs.
user = os.path.join(out, "keys"); os.makedirs(os.path.join(user, "Wii"))
keys = bytearray(0x400); keys[0x114:0x124] = test_common_key
open(os.path.join(user, "Wii/keys.bin"), "wb").write(keys)
open(os.path.join(out, "TEST_KEY_ONLY.txt"), "w").write(
    "keys/Wii/keys.bin holds a random test key made by make_disc.py for this test disc only.\n")

def iso_to_wbfs(iso_path, wbfs_path):
    hd_shift, wbfs_shift = 9, 21                      # 512-byte HD sectors, 2 MiB WBFS sectors
    hd, cluster = 1 << hd_shift, 1 << wbfs_shift
    blocks_per_disc = (143432 * 2 * 0x8000 + cluster - 1) // cluster
    iso = open(iso_path, "rb")
    disc_header = iso.read(0x100)
    wlba = [0] * blocks_per_disc
    chunks = []
    i = 0
    while True:
        iso.seek(i * cluster); data = iso.read(cluster)
        if not data: break
        if data.strip(b"\0"):
            chunks.append(data.ljust(cluster, b"\0")); wlba[i] = len(chunks)  # cluster 0 holds the header
        i += 1
    total = (len(chunks) + 1) * cluster
    head = bytearray(cluster)
    head[0:4] = b"WBFS"
    struct.pack_into(">I", head, 4, total // hd)
    head[8], head[9] = hd_shift, wbfs_shift
    head[12] = 1                                       # disc slot 0 used
    head[hd:hd + 0x100] = disc_header
    struct.pack_into(">%dH" % blocks_per_disc, head, hd + 0x100, *wlba)
    with open(wbfs_path, "wb") as f:
        f.write(head)
        for c in chunks: f.write(c)

# Pack it (dolphin-tool needs the test key to encrypt, so it runs with the test user folder).
main_dol = os.path.join(data, "sys/main.dol")
for fmt, ext in (("iso", "iso"), ("wbfs", "wbfs"), ("rvz", "rvz")):
    dst = os.path.join(out, f"{a.id}.{ext}")
    if fmt == "wbfs":
        iso_to_wbfs(os.path.join(out, f"{a.id}.iso"), dst)
        print("wbfs ok", os.path.getsize(dst)); continue
    cmd = [a.tool, "convert", "-u", user, "-i", main_dol, "-o", dst, "-f", fmt]
    if fmt == "rvz":
        cmd += ["-b", "131072", "-c", "zstd", "-l", "5"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(fmt, "ok" if r.returncode == 0 and os.path.exists(dst) else f"FAILED {r.stdout} {r.stderr}",
          os.path.getsize(dst) if os.path.exists(dst) else "")
