# Wii support for Iridia 1.2: done

Branch `release/1.2-wii` in `~/Projects/gc-emu-wii`, on the shipped 1.1 (`524f1be383`, tag
`iridia-1.1-build15`). Version 1.2.0 (16). Local commits only: nothing is pushed, and `main` and the
1.1 tag are untouched. The plan, with the full optimization table, is in WII_PLAN.md.

## What changed

**Core**
- **No Wii keys in the source or the app.** The retail, Korean and dev common keys and the SD key are
  gone, and the console identity is our own made-up one. These keys were still in 1.0 and 1.1; 1.2
  replaces 1.1 (no 1.1.1). `scripts/verify_no_wii_keys.py` passes on the source tree and the app.
- **Wii formats.** RVZ and WIA play (they are stored decrypted). Encrypted Wii disc images (ISO, WBFS,
  CISO, GCZ) and WAD files aren't supported, and the app never says how to make them work:
  - The shelf shows "Encrypted Wii disc image. Not supported."
  - Play shows "Encrypted Wii disc images aren't supported" ("Iridia plays Wii games as RVZ or WIA
    files, and Wii homebrew as .dol or .elf files.") and goes back to the shelf. It never hangs.
- **Homebrew.** DOL and ELF files built for the Wii go to the Wii shelf, sorted by what the file is.
- **Saves** go in the virtual NAND inside the hidden user folder, which the device backup already
  includes.
- **Online off.**
  - Network devices answer "no link" or "refused".
  - WiiConnect24 requests fail.
  - None of the four network threads start.
  - Checked: on 1.1 our test program reached the internet; on 1.2 it gets errors and keeps running.
- **No Wii Menu.** A game that asks for the Wii Menu or a missing channel stops with a plain message,
  and its saves are kept. On 1.1 it hung.

**Controls**
- On-screen Wii Remote layouts:
  - Wii Remote + Nunchuk (the default).
  - Wii Remote alone (no Nunchuk controls shown).
  - Sideways.
  - Classic Controller.
  - GameCube controller.
- **Quick switch.**
  - A 44 pt controls button at the top of the game screen, plus a "Wii controls" row in the pause
    menu.
  - The choice is remembered for each game. Settings sets the default for new games.
  - The switch never moves devices between GameCube port 1 and Wii Remote 1, so GameCube games keep
    their controller.
- **Pointer:**
  - Drag on the screen (the default), Follow your finger, or Point the phone.
  - A Recenter button shows while pointing with the phone.
- **Shake button** on screen. "Shake the phone to shake" and "Tilt the phone to tilt" are in Wii
  Settings, both off by default.
- **Motion sensors** run only when one of these uses them. GameCube still never starts them.
- **Game controller defaults** (`Physical Controller.ini`):
  - Left stick: Nunchuk stick.
  - Right stick: aims the pointer (relative). On controllers with a gyro, the gyro aims too.
  - Right shoulder: shake.
  - Classic Controller: mapped by position.
- **GameCube controller in Wii games:** pick GameCube in the switch.
- Help says real Wii Remotes can't connect (iOS gives apps no access to them).

**UI**
- **Wii section** next to GameCube and Wii U, with its own shelf (Wii games only), Settings, Help and
  Unlock.
  - Pearl and sage look, light and dark mode, iPhone and iPad.
  - System font and SF Symbols only. No Nintendo art, fonts, Wii Remote or console pictures, or Wii
    Menu look.
- **Tab bars:**
  - GameCube: Games, Saves, Controllers, Wii, Wii U.
  - Wii: GameCube, Wii, Wii U, Settings, Help.
  - Wii U: GameCube, Wii, Wii U, Settings, Help.
- **Files:** a visible `Wii` folder for Wii games. Wii games put in
  `Games` also show up on the Wii shelf.

**Purchase**
- Same Unlock Full Version, now worded "GameCube, Wii and Wii U".
- Wii free play: 10-minute sessions that repeat, the same as GameCube. Wii U stays at 20.
- A reviewer reaches the purchase without a game: Wii tab, then Unlock (top right) or Settings, then
  Full Version.

## Optimization audit (summary; full table in WII_PLAN.md section 7)

Every GameCube speed change reaches Wii mode.

Mac A/B: each shipping CPU optimization was turned off alone, on the same benchmark program built for
Wii and for GameCube. Mac M4, no JIT, two rounds, frames per second. Raw numbers are in
`benchmarks/wii/mac-opt-ab.txt`.

| Turned off | Wii: slower by | GameCube: slower by |
|---|---|---|
| PIC load/store | 67% | 68% |
| Record chaining | 38% | 39% |
| Paired-single NEON | 11% | 11% |
| Block linking | 3.5% | 4.4% |
| Long blocks | 2.5% | 4.0% |
| Micro-op fusion | 1.7% | 3.3% |
| Micro pairs | 1.3% | 2.0% |
| Dynamic linking, mem micro-ops, specialized ops | within noise (about ±2%) | within noise |

- The checksum is the same in every run.
- Per-frame cost of identical work: Wii 33.1 ms, GameCube 32.9 ms (x16).
- Memory: MEM2 uses the same fast path as MEM1.
- Threads: the offline build starts the same threads as GameCube mode.
- Audio: an unused Wii Remote speaker fifo costs nothing.
- **PGO:** can't be measured on the Mac; queued for the phone.

## Test results

| Test | Result |
|---|---|
| GameCube regression (Mac): IridiaBench checksums | Same as 1.1 (`cfa55e7f` x4, `3a2268d2` x16) in GameCube and Wii mode; speed vs the 1.1 binary is a tie |
| GameCube regression (Simulator) | Shelf shows GameCube games only, plus the Wii tab; IridiaBench plays at full speed |
| Wii U regression (Simulator) | Wii U section opens with the Wii tab; IridiaCafeCore unchanged from 1.1 (both slices rebuilt); its no-JIT check passes |
| Wii homebrew | `iridiawii-input`: every layout reaches the game (Nunchuk, Classic, none); pointer valid on 831 of 840 frames |
| Our test disc, RVZ | Plays without a key |
| Our test disc, ISO/WBFS | Note on the shelf, plain message on Play (checked on the Mac with a test-only key too: the core path works) |
| `iridiawii-net` | 1.1 online; 1.2 offline, keeps running |
| `iridiawii-menu` | 1.2 stops with a message at 3 s; 1.1 hung |
| Unit tests (iCubeTests, iPhone Simulator) | 1475 run, 7 skipped, 0 failures. Two Settings tests left stale by 1.1 were updated |
| No-JIT check (`scripts/verify_no_jit.sh`) | PASS on the Release device build |
| No Wii keys (`scripts/verify_no_wii_keys.py`) | PASS on the app and the source tree |
| Clean builds | iPhone and iPad Simulator Debug; Release device build (universal: iPhone and iPad), 1.2.0 (16) |
| App Store archive (Nov 11) | `build-appstore/Iridia-1.2-16.xcarchive`, app.iridia 1.2.0 (16), iPhone + iPad. Keys check `--strict`: PASS (5,231 files). No-JIT: PASS except `get-task-allow`, which every archive has (development-signed, same as the 1.1 archive); the App Store export re-signs without it, so run the check again on the exported .ipa. No test hooks or keys.bin text in the binary |

**Not done here:**
- Landscape screenshots, because there's no command-line rotate in a headless Simulator.

## Screenshots

In `wii-shots/` (iPhone 18 Pro and iPad Pro 11" Simulators):
- **Wii section:** `iphone-home-light/dark`, `iphone-settings-light/dark`, `iphone-help-light`,
  `iphone-unlock-light/dark`, `ipad-home-light/dark`, `ipad-settings-dark`, `ipad-unlock-light`.
- **Controls:** `iphone-controls-nunchuk/remote/sideways/classic/gamecube`,
  `iphone-pause-controls-row`, `ipad-play-nunchuk`.
- **Encrypted files:** `iphone-needs-key-note`, `iphone-needs-key-alert`. These show the old keys.bin
  wording, which 1.2 no longer has; retake before using them anywhere.
- **Regression:** `iphone-gamecube-shelf-wii-tab`, `iphone-gamecube-play`, `iphone-wiiu-home-wii-tab`.
- **Debug-only items in the shots:** the in-game screenshots show the "1 FPS" pill (the test program
  redraws rarely). Debug builds also show a DSU line; it was hidden for these shots and Release builds
  don't have it.
- **Simulator quirk:** it hands the Mac keyboard to the app as a game controller, so the GameCube game
  shot has no touch pad. A phone has no such controller.

## Wii games likely too slow on iPhone

These are estimates. No Wii game was run: there are none here, and the phone wasn't used.
- **Same cost per instruction:** our CPU path costs the same in Wii and GameCube mode (above).
- **Faster CPU:** the Wii's CPU is 1.5x faster than the GameCube's, so a Wii game that keeps it busy
  needs up to 1.5x the time per frame.
- **Headroom:** Twilight Princess (GameCube) has about 2.4x headroom on the iPhone 16 Pro.

| Likely | Games |
|---|---|
| Too slow for full speed | Super Mario Galaxy 1 and 2 (busy levels), Xenoblade Chronicles, The Last Story, Pandora's Tower, GoldenEye 007 (2010), Call of Duty Wii ports, Monster Hunter Tri, Skyward Sword, Metroid Prime 3 / Trilogy, Red Steel 2, Epic Mickey |
| Borderline (drops in busy scenes) | Super Smash Bros. Brawl, Mario Kart Wii (4 players), Donkey Kong Country Returns, Sonic Colors, Twilight Princess (Wii), Silent Hill: Shattered Memories, Okami (Wii) |
| Should be full speed on A17 Pro / A18 | Wii Sports, Wii Sports Resort, Wii Play, New Super Mario Bros. Wii, Kirby's Return to Dream Land, Kirby's Epic Yarn, WarioWare: Smooth Moves, Punch-Out!!, Excite Truck, Mario Party 8/9, Animal Crossing: City Folk |

On A13 to A15 phones, move each row one step slower.

## Queued phone checks (not run; the phone wasn't used)

1. Wii IridiaBench x16 and x4 with the PGO build vs a non-PGO build (does Wii lose more than GameCube?).
2. One of your own Wii games from each row of the list above: fps, heat after 10 minutes.
3. Point the phone: does Recenter hold the pointer centred? Does tilt follow the phone? Does phone
   shake fire only on a real shake?
4. Controls switch mid-game on the phone; pause menu row; layouts in landscape.
5. A real game controller: left stick Nunchuk, right stick aims, right shoulder shakes, Classic layout.
6. The "not supported" alert on the phone for an encrypted disc image and for a WAD.

## Docs

`UPDATE_NOTES_1.2.md` has three drafts: the App Review notes (how to reach the Wii section and the
purchase without a game), What's New, and the listing changes. Nothing has been sent.

## Decisions

Made (Nov 11):
1. **No 1.1.1.** 1.2 replaces 1.1 and stays key-free.
2. **History is not rewritten.** The public source is one clean snapshot commit, never our history.
   Release gate: `scripts/check_public_snapshot.sh <snapshot repo>` (BUILDING.md section 7) fails unless
   the snapshot has exactly one commit, a clean tree, and no Wii key in any file (raw, hex, C list,
   base64, or inside zip/tar/gzip/bzip2/xz). Tested: it fails on the 1.1 tree, on a two-commit repo and
   on a key hidden in base64 or a zip; it passes on the 1.2 tree.
3. **No keys.bin anywhere** in the app, help or notes. The keys.bin import is removed. Also removed:
   bundled iCube help pages on disc/NAND dumping, JIT and the GameCube BIOS (they shipped in 1.1 but
   weren't shown); help pages are never downloaded; the BIOS alerts' Learn More buttons (one opened
   icube-emu.com); the About link to icube-emu.com.
4. **`release/wii-support`** is tagged `archive/wii-support` (43f7263d50) and deleted.

Still open (recommendations in the chat):
5. WAD files.
6. Motion defaults (shake and tilt the phone off by default).
7. Same game in two formats (merged entry with a source picker).
8. Classic Controller on a game controller mapped by position.
9. Wii U conflicts as resolved above (tab order, trial lengths, one purchase, layouts unchanged).
