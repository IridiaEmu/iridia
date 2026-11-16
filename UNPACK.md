# Unpacking and disc decompression (overnight Nov 12-13, 2026)

Branch release/1.2-wii, Mac and Simulator only. Not pushed.

## Short version

- 7Z (LZMA) unpacks about 1.5x faster in the decoder: 7-Zip's own arm64 assembly decoder was in the source but switched off.
- ZIP unpacks 2.5x (deflate) to 5x (stored) faster: Iridia now reads ZIPs itself with 4 MB reads instead of the Zip library's 4 KB loop.
- gzip unpacks 18x faster and no longer needs the whole file in memory (a 300 MB file took 619 MB extra; now 9 MB).
- Importing an archive shows a progress card (name, percent, time left, Cancel), checks for room against the unpacked size first, cleans up after a cancel or a cut-off, and offers Try Again.
- Custom textures are off by default for new installs and stay on for anyone with a texture pack; the "Preloading '0' custom textures" message is gone.
- Decompression while playing is not a bottleneck: in 60 s of Twilight Princess and Super Mario Galaxy the game waited on the disc for 37 ms and 2 ms in total. No change made there.
- Every unpacked file was checked byte for byte (SHA-256) against the original. All matched.

## Where the 4.5 minutes came from

The 4.5 minute figure for the 3.2 GB Mario Galaxy 7Z was a Debug Simulator build (12 MB/s). The App Store build is compiled with optimization and was already about twice as fast (26 MB/s, about 2.3 minutes). That archive is plain LZMA (`LZMA:26`, one stream), which can only be decoded on one core by any tool, including 7-Zip itself. On this Mac, 7-Zip decodes it at 54 MB/s; that is the ceiling.

Where the time went, before:

| Format | Where the time went |
|---|---|
| 7Z / xz (LZMA) | The LZMA decoder itself (portable C, the arm64 assembly version was compiled but unused). Writes about 13%. |
| 7Z (LZMA2) | Same decoder. The test archives are LZMA2 but PLzmaSDK is built single-threaded (`Z7_ST`). |
| ZIP | The Zip library reads and writes 4 KB at a time and only reports progress after each whole file (a one-file 3 GB ZIP sat at 0% until done). No cancel. |
| gz / bz2 / tar | SWCompression (pure Swift) reads the whole archive into memory first, then the whole result. A multi-GB .gz could get the app closed on an 8 GB phone. |
| Extra copy | The archive is copied to a private folder before unpacking; on the same disk this is an instant APFS clone. Only an archive on another disk is really copied, and the space check now counts that. |

## Before and after

Mac (M4), iPhone 18 Pro Simulator, built with optimization (`-Os`, Swift `-O`, like the App Store build), through the app's own unpack code (`UnpackBenchTests`). Test files are 400 MB slices of real games (Twilight Princess ISO, Super Mario Galaxy RVZ) and 300 MB of ordinary compressible files. Run-to-run noise on the 7Z rows is about 20 to 25% (Simulator daemons were crashing in the background and Time Machine was running), so the decoder change was also timed natively, below.

| Archive | Before | After | Change | Identical | Extra memory |
|---|---|---|---|---|---|
| ZIP, stored (Mario Galaxy RVZ slice) | 3.64 s, 110 MB/s | 0.70 s, 574 MB/s | 5.2x | yes | 4 MB |
| ZIP, deflate (Twilight Princess, mostly incompressible) | 2.92 s, 137 MB/s | 0.82 s, 486 MB/s | 3.6x | yes | 8 MB |
| ZIP, deflate (compressible files) | 3.27 s, 92 MB/s | 1.12 s, 267 MB/s | 2.9x | yes | 12 MB |
| 7Z, LZMA (Twilight Princess) | 15.16 s, 26 MB/s | 11.1 to 13.4 s, 30 to 36 MB/s | 1.15 to 1.35x | yes | 67 MB (the 64 MB dictionary) |
| 7Z, LZMA (compressible files) | 5.45 s, 55 MB/s | 3.75 to 4.5 s, 66 to 80 MB/s | 1.2 to 1.45x | yes | 67 to 81 MB |
| 7Z, LZMA2 (compressible files) | 5.46 s, 55 MB/s | 3.8 to 4.4 s, 68 to 79 MB/s | 1.25 to 1.45x | yes | 17 MB |
| 7Z, LZMA2 (incompressible, stored chunks) | 0.60 s | 0.54 to 0.65 s | same | yes | 67 MB |
| gzip (compressible files, 300 MB) | 20.69 s, 15 MB/s, 619 MB extra memory | 1.15 s, 260 MB/s | 18x | yes | 9 MB |

Debug build, for reference (what the 4.5 minutes was measured on): ZIP stored 2.55 s, ZIP deflate 3.21 s, 7Z LZMA (TP) 33.5 s.

LZMA decoder alone, native on the Mac, same 400 MB stream, two runs each (steady):

| Decoder | Time | Speed |
|---|---|---|
| LZMA SDK C (before) | 10.79 s | 37 MB/s |
| LZMA SDK arm64 assembly (after) | 7.26 s | 55 MB/s |

Estimate for the 3.2 GB Mario Galaxy 7Z in the App Store build: about 2.3 minutes before, about 1.6 to 1.9 minutes after on a recent iPhone. It was not re-run at full size tonight: unpacking it needs 3.6 GB free and the Mac had 1 to 2 GB.

Peak memory stays bounded: ZIP adds two 4 MB buffers; 7Z adds the archive's dictionary (64 MB for these, at most what the archive was made with).

## What changed (commits)

| Commit | Change |
|---|---|
| 18a88818a8 | Use the LZMA SDK's arm64 decoder for 7Z and xz (`Packages/PLzmaSDK/src/C/LzmaDec.c`, arm64 only). |
| ba2729fd85 | Unpack ZIPs with large reads and report progress in bytes (`ZipStreamExtractor.swift`). minizip walks the directory; stored and deflated data are read straight from the archive in 4 MB chunks, inflated with the system zlib, and each file's CRC and size are checked. Encrypted entries are refused. 7Z and xz report progress through PLzmaSDK and can be cancelled. |
| ca71c3af0e, 8c750e00f1 | `UnpackBenchTests`: a timing test that only runs when `UNPACK_BENCH_DIR` is set; checks every file's SHA-256 and that progress moves. |
| df4beff9ca | No custom textures message when a game has none. |
| 92055260ac | Custom textures off by default; an install that already has a folder in Load/Textures keeps them on. |
| c6dcc18b26 | Progress card with Cancel, unpacked-size space check, Try Again after a cut-off. |
| 48169925f7 | Cancel now stops 7Z and xz. Before, the abort was sent from inside PLzmaSDK's progress callback, where it is ignored, so "Cancelling..." showed while the unpack carried on. It is now sent from a separate thread. Checked by cancelling at 20%: 7Z LZMA, 7Z LZMA2, ZIP and gzip all stopped within 2% (`testCancelStopsUnpacking`). |
| 633f171046 | The unpack card sits above the tab bar on iPad (scaled like the shelves), and only the card itself takes taps. |
| 3e0376701f | tar archives over 1 GB and bz2 / tar.bz2 archives over 250 MB are refused before unpacking, because both are unpacked in memory. The message: "Iridia can unpack tar files up to 1 GB. Unpack this one on a computer, or make it a ZIP or 7Z file, and add it again." A .tar.gz is checked once its tar is out. Unit test `testTarAndBzip2OverTheLimitAreRefused`. |
| 24e6b57f23 | gzip unpacked in 4 MB pieces with the system zlib (several gzip members are joined, as gunzip does), with progress and Cancel. .tar.gz goes through a temporary .tar on disk. tar files are mapped instead of read. |

Import experience details:
- The card sits above the tab bar in the tab's look (GameCube glass, Wii and Wii U white) and doesn't block the screen. It shows "Unpacking <name>", a bar, the percent and "about N min left" once there is enough to estimate. Checked in the Simulator.
- Cancel stops the unpack, removes everything it wrote and says "Stopped unpacking <name>." Nothing is added and the archive is left as it was.
- The import asks iOS for extra time in the background. If that runs out, the unpack is stopped cleanly and, back in the app, "Unpacking Stopped" offers Try Again.
- If the app is closed mid-unpack, the leftovers are removed at the next launch and the archive is offered again if it is still there.
- Space check: the unpacked size (read from the ZIP or 7Z directory), plus the archive itself when it has to be copied from another disk, plus 200 MB. The message says how much is needed, how much is free and how much to free up.

New libraries: none. minizip (zlib licence) was already in the app inside the Zip package; zlib is the system's; the LZMA SDK assembly file was already vendored with PLzmaSDK (public domain).

## Decompression while playing

Measured on the Mac runner with fast disc speed on (the iOS default), counting how long the emulation thread waited for the disc thread:

| Game | Format | Reads in 60 s | Data | Total wait | Longest wait |
|---|---|---|---|---|---|
| Twilight Princess | RVZ (GameCube) | 2,114 | 16 MB | 37 ms | 0.55 ms |
| Super Mario Galaxy | RVZ (Wii) | 2,208 | 30 MB | 2 ms | 0.06 ms |

Decoding is already on Dolphin's disc thread, not the emulation thread. Full-disc decode speed (Mac, one pass):

| Format | Speed |
|---|---|
| RVZ zstd, Twilight Princess (GameCube) | 1.46 GB in 1.0 s, one core |
| RVZ zstd, Super Mario Galaxy (Wii, re-encrypted on read) | 4.7 GB in 2.2 s, several cores |
| GCZ, RVZ zstd/LZMA2, ISO (TP slice) | under 0.15 s per 400 MB |
| WIA LZMA (TP slice, no junk detection) | 29 MB/s |
| WIA bzip2 | 35 MB/s |
| WUA (Super Mario 3D World, ZArchive zstd) | 812 to 925 MB/s, one core |
| CISO, WBFS, WUX | no decompression (WUX is deduplicated sectors plus AES, which has hardware support) |

The 1.46 GB RVZ ran 60 s at a steady 60 fps; Mario Galaxy too. No cache or read-ahead change was made because nothing waits.

## For you to decide

1. **WIA with LZMA or bzip2 is slow to decode** (about 30 MB/s on the Mac, so roughly 70 ms per 2 MB block, likely 2 to 3 times that on the phone). It's a rare, older format. Options: leave it; suggest converting to RVZ in the help text; or switch Dolphin's WIA LZMA decoding to the LZMA SDK's assembly decoder (a core change). I'd leave it.
2. **Multi-core 7Z**: only helps LZMA2 archives made with several blocks. The common game downloads are plain LZMA, which can't be split. It needs PLzmaSDK built multi-threaded plus one more LZMA SDK file (MtDec.c, public domain). I'd skip it.
3. **Playing a stored ZIP without unpacking** would save the unpack time and the disk space for ZIPs of RVZ/ISO files. Bigger change (Dolphin would read the ZIP); not started.
4. **Longer background unpacks**: iOS 26's continued processing tasks could let a 2-minute unpack finish in the background with the system's own progress. Needs a new Info.plist entry; not started.
5. **The "custom textures" message** is hidden only when the count is 0; with a pack installed it still says how many were found. Say if you want it gone entirely.
6. The on-screen Cancel test (`test30UnpackCard` in ~/Projects/iridia-uitest) wasn't rerun after the Cancel fix: the Mac ran out of disk. Earlier runs showed the card, a tap through to the tab bar, "Cancelling...", the leftover cleanup ("Unpacking Stopped", Try Again) and the space message. Rerun it once there is about 1 GB free.
7. The older import paths (web upload, the Software folder) still unpack without the card.
8. Done (3e0376701f): tar over 1 GB and bz2 over 250 MB are refused with a clear message, as you approved.

## How to re-run

```sh
# test archives: any folder of .zip/.7z, with expected.sha256 (shasum -a 256 format) one level up
TEST_RUNNER_UNPACK_BENCH_DIR=<folder> xcodebuild ... test -only-testing:iCubeTests/UnpackBenchTests \
  GCC_OPTIMIZATION_LEVEL=s SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
```

The script used tonight is logs12w/bench.sh (not committed). Each line prints time, MB/s, peak and added memory, the identical-file count and how many progress steps showed.
