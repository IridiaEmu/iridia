# Wii support for Iridia 1.2: plan

Branch `release/1.2-wii` in `~/Projects/gc-emu-wii`, started from the shipped 1.1 (commit `524f1be383`,
local tag `iridia-1.1-build15`; the 1.1.0 (15) archive was built three minutes after it and contains
its last change). Version 1.2.0 (16). Nothing is pushed; `main` and the 1.1 tag are not touched.

1.2 = GameCube + Wii U (from 1.1) + Wii. The older `release/wii-support` branch holds the same first
two commits from the same base and is kept until the move is confirmed.

## 1. What state Wii is in today

Wii was never removed from the core. Only parts of the UI were taken out in Phase 7 (commit `1867568fb7`).

| Part | State in 1.1 | What to do |
|---|---|---|
| Dolphin's Wii mode (Broadway CPU at 729 MHz, MEM2, Hollywood, IPC) | Built in and working | Nothing; tested on the Mac (section 6) |
| Dolphin's built-in Wii system (HLE IOS: ES, FS, DI, STM, USB/BT, SD, net) | Built in | Turn off what goes online (section 4) |
| Virtual NAND (saves) | Built in, at `Library/Application Support/Iridia/Wii` | Keep; it's inside the hidden user folder, which the device backup already includes |
| Wii disc formats (ISO, WBFS, WIA, RVZ, CISO, GCZ, NKit-as-ISO) and DOL/ELF homebrew | Built in | Show them; key rule below |
| WAD (WiiWare/channels) | Built in (needs install into the NAND) | Later, if at all: install needs the key, and channels pull in system titles |
| Wii Remote, Nunchuk, Classic emulation; touch pointer, gyro pointer, recenter, tilt | Built in (iCube base, rebuilt touch overlay) | Wire into the new Wii section; add the missing parts (section 3) |
| Library | One Dolphin list that would show Wii games on the GameCube shelf | Split: GameCube shelf shows GameCube only, new Wii section shows Wii |
| Settings | Phase 7 removed the Wii section, Wii System Update, BootMii NAND import | Bring back a short Wii section; system update and NAND import stay out |
| **Wii keys** | **Still compiled in** (`Core/IOS/IOSC.cpp`: retail, Korean and dev common keys; SD key) | **Remove** (section 2) |

### Finding: the shipped app contains the Wii keys
RESEARCH.md decided "strip Wii support and the Wii common key", and STATUS.md lists it as done, but
`IOSC.cpp` still holds the retail, Korean and RVT common keys and the SD key in plain bytes. They are in
the 1.0 and 1.1 binaries. The 1.2 branch removes them. Whether to also ship a key-free GameCube/Wii U
build before 1.2 is the owner's call (listed in WII_DONE.md).

## 2. Keys, disc formats and system files (hard rules)

- **No keys in the app.** IOSC gets zeros for the common keys and the SD key. The app has no way to
  add keys and never mentions them (owner's decision, Nov 11).
- **What works:** RVZ and WIA keep Wii partitions decrypted, so they play without any key (`VolumeWii`
  reads them through `ReadWiiDecrypted`). Homebrew DOL/ELF too.
- **Not supported:** encrypted Wii disc images (ISO, WBFS, CISO, GCZ) and WAD files. The game shows on
  the shelf with "Encrypted Wii disc image. Not supported.", and Play says encrypted Wii disc images
  aren't supported and which file types work. It never fails silently.
- **No Wii system files.** Discs boot with Dolphin's built-in Wii system (no Wii Menu). Dolphin makes its
  own SYSCONF and setting.txt. If a game asks for something only a real Wii has (the Wii Menu, a
  channel), the game stops with a message and the progress saved by the game stays. Nothing is
  downloaded.
- **Online off (done, `IOS/Network/IridiaOffline.h`):** the network devices stay so games find them, but
  NCD reports no link, IP/Top and SSL refuse every request (the same answer Dolphin gives during
  netplay), WiiConnect24 requests fail with "network error", and none of the network threads start.
  No Wii System Update, no online play. Checked with `iridiawii-net` (our test program calling
  `net_init`, a DNS lookup and `socket`): 1.1 reached the internet (DNS found); 1.2 gets -7 / none /
  -6 and keeps running at full speed.

## 3. Controls

| Feature | Exists in the base | Work |
|---|---|---|
| On-screen Wii Remote (A, B, 1, 2, +, -, HOME, D-pad) | Yes (touch overlay; upright and sideways) | Restyle to our own look (no Wii Remote images) |
| Pointer by touching or dragging on the game picture | Yes (Follow and Drag modes) | Keep; default Drag |
| Pointer by gyro, with recenter | Yes (`PointerModeController .gyro`, Recenter Pointer) | Add a Recenter button on screen while gyro aims |
| Shake button | No (only shake input IDs exist) | Add a Shake button; it pulses Wii Remote shake for a short burst |
| Real phone shake | Partly (`TCDeviceMotion` shake detection) | Setting "Shake the phone to shake", off by default |
| Tilt from the phone's motion | Yes (accelerometer to Wii Remote) | Setting "Tilt with the phone", off by default; motion sensors only on when needed (keeps GameCube's no-CoreMotion win) |
| Nunchuk and Classic Controller layouts | Yes | Quick switch (below) |
| Quick switch | No | One on-screen button (44x44 pt or bigger) plus a pause-menu row; choice remembered per game |
| Physical controllers to Wii Remote + Nunchuk / Classic | Partly (mapping engine) | Ship defaults: left stick = Nunchuk stick, right stick = pointer (or gyro on controllers that have one), a button for shake; Classic maps 1:1 |
| GameCube controller in Wii games that take one | Yes (GameCube ports stay active in Wii mode) | Keep the existing GameCube touch pad; switchable |
| Real Wii Remotes over Bluetooth | No | iOS gives apps no Bluetooth Classic HID access (CoreBluetooth is Bluetooth LE only, GameController covers MFi/Xbox/PlayStation/Switch). Not possible; said in Help |

## 4. UI

- A **Wii** section next to GameCube and Wii U: its own shelf (only Wii games), its own Settings and
  Help, an Unlock button. Original look: a light pearl surface with a sage-green accent (not the Wii
  Menu's channel grid or its blue). Light and dark mode, iPhone and iPad.
- Tab bars: the GameCube shelf gets a Wii tab next to Wii U; the Wii U tab bar gets Wii; the Wii tab bar
  has GameCube, Wii U, Wii, Settings, Help.
- Files: a Files-visible `Wii` folder (like `Wii U`) for Wii games. Wii games
  dropped in `Games` also show up in the Wii section (sorted by what the file is).
- The word "Wii" only in plain text. No Nintendo logos, fonts, Wii Remote or console pictures.

## 5. Purchase

The Wii section uses the same Unlock Full Version and the same free play rules as GameCube (10 minutes a
session, repeating). Dolphin games already share `FreePlaySession`, so Wii games get it unchanged. The
Wii section has an Unlock button in its header and in its Settings, so a reviewer reaches the purchase
without a game.

## 6. CPU, memory, size

- **Clock:** the Wii's CPU runs at 729 MHz against the GameCube's 486 MHz. Our CPU path has no JIT, so its
  cost is per emulated instruction. A Wii game that keeps its CPU busy needs up to 1.5x the instruction
  rate of a GameCube game that keeps its CPU busy.
- **Measured on the Mac (M4, no JIT, IridiaBench, the same program built for both):** the host time per
  finished frame of identical work is the same in both modes (x16: GameCube 33.7 ms, Wii 34.0 ms; x4:
  8.4 vs 8.2 ms). Wii mode finishes more frames per second (the 1.5x clock fits more work before each
  vsync), which made a plain maxSpeed comparison look 15% worse; per-frame cost is the right measure.
- **Memory:** Wii adds 64 MB (MEM2) to the emulated memory map; the 1.1 build already has the increased
  memory limit. Checked in tests.
- **App size:** no new libraries (Wii code is already in the binary); a few new Swift files.
- **iPhone guess (from TP on the iPhone 16 Pro, 2.4x headroom at 1x):** light Wii games should run full
  speed on A17 Pro / A18-class; CPU-heavy ones (late-era 3D games) are likely below full speed. List in
  WII_DONE.md, phone checks queued (not run now).

## 7. Optimization audit (every GameCube speed change, does it reach Wii)

Filled in as each is checked; results in WII_DONE.md. Per-optimization A/B (each one off alone, Wii and
GameCube builds of the same program): `benchmarks/wii/mac-opt-ab.txt`. Every one helps Wii as much as GameCube.

| Optimization | Applies to Wii | How checked |
|---|---|---|
| No JIT: Cached Interpreter + iCube CIR (block linking, micro-op pairs, fused paired-single sequences, compare-branch fusion) | Yes | Same CPU core in both modes; Wii profile shows the same handlers (`LinkBlock`, `PairMA`, `ExecuteFusedPsqSeqChained`, `CmpBranch`) at the same shares |
| Memory fast path (`LoadStoreFast` through the BAT page table) | Yes, MEM2 included | `UpdateDBATMappings` fills the table from every active region incl. MEM2; IridiaBench with its data in MEM2 = MEM1 (0.965 vs 0.964) |
| Wii extended BATs (HID4.SBE) | Yes | Same table (`DBATUpdated` adds BAT4-7 into it) |
| Idle-loop skipping | Yes | Mostly idle IridiaBench x1: same per-frame cost in both modes |
| Stall signposts compiled out, stall metrics off | Yes (global) | Build flag |
| Branchy Force25Bit / FP classification | Yes (global) | Same handlers in the Wii profile |
| -mcpu=apple-a13 tuning | Yes (global) | Build flag |
| PGO | Phone check queued | The Mac runner has no PGO, so this can't be measured here. The profile was trained on GameCube only: Wii-only code (IOS, Wii Remote, AX Wii) has zero counts and is laid out as cold. The Mac profile of Wii mode shows the same top handlers at the same shares as GameCube. Check on the phone: Wii IridiaBench with the PGO build vs without; retrain with a Wii workload if Wii loses more than GameCube |
| Metal renderer | Yes (global) | Same backend |
| Shader cache, async/ubershader mode | Yes | Per game ID; same settings |
| Audio mixer skips silent fifos | Yes | `MixerFifo::Mix` returns at once for a fifo that never got samples; the four Wii Remote speaker fifos go through the same `Mix`, so they cost nothing until a game plays sound on a remote |
| Thread QoS by thread name | Yes (nothing to add) | Offline build starts no extra Wii threads: `sample` shows the same threads as GameCube mode (1.1 started WiiConnect24 Worker, WiiConnect24 Scheduler Worker, KD Scheduler Timer and Network Worker) |
| No CoreMotion for GameCube | Yes, kept | Wii turns motion on only when pointer-by-gyro, tilt or shake-the-phone is on |
| Per-device presets (resolution, shader mode, anisotropy) | Yes | Global GFX settings |
| Wii Remote / Bluetooth emulation per frame | Cheap | IridiaBench reading the Wii Remote every frame: no measurable change |
| IOS HLE updates (1500 Hz event) | Cheap | Included in the per-frame numbers above |

## 8. Tests

- **GameCube and Wii U regression:** framebuffer checksums from our homebrew (same before/after),
  Mac fps (same), UI (shelf, tabs, trial, purchase, Wii U layouts) screenshots in the Simulator, unit tests.
- **Wii:** IridiaBench Wii builds, `iridiawii-input` (logs pointer, buttons, tilt, shake, Nunchuk,
  Classic to the NAND), an RVZ and an ISO/WBFS of our own test disc (made with a test-only key, so it
  proves both paths without any real key). The owner's games folder has no Wii games (the Twilight
  Princess file is the GameCube version).
- **Optimization A/Bs on the Mac**, no-JIT check, clean iPhone and iPad builds.

## 9. Combining with other branches later

`release/1.2-wii` is 1.1 plus Wii, so it is the whole next release. Any 1.1.x fix on `main` is merged
into it (`git merge main`; Wii changes sit in new files plus small hooks, so conflicts should be small).
