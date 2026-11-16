# Wii 1.2 progress

Branch release/1.2-wii, built on release/1.1.5 (merge cf4c5db112). iPhone 18 Pro and iPad Pro 13 (M5) Simulators, and since Nov 13 the iPhone 16 Pro (PHONE_TEST.md).

## Where things stand (Nov 13, evening)

Worktree ~/Projects/gc-emu-wii, branch release/1.2-wii, version 1.2.0 (18). Local commits only, nothing pushed.

Evening fix pass (your 11-item list), one commit each:

| Commit | What |
|---|---|
| ecfd44a9d8 | The dragged tab pill stays under the finger along the whole bar; letting go over Saves or Controllers opens them |
| 29af4c2d56 | Player folders stay in Documents; ones that 1.1.5 or earlier 1.2 builds hid come back once |
| 1e9a25034f | Added dates kept when Games becomes GameCube |
| c8d58bb9c4 | Downloads folder: when iOS drops access, a calm "Choose Downloads Again", shown once |
| e9df1683a0, 7d9c15e4f5, d62038d147 | Same menu tops on all three tabs, GameCube Settings sheet, pause menu per system (see "Menus on all three tabs") |
| 908ac1704e | Wii touch controls drawn with the GameCube parts in grey |
| ce8ac5e689 | No software keyboard when a menu opens during play |
| 3e0376701f | tar over 1 GB and bz2 over 250 MB refused with a clear message |
| fe812dc0ba | PHONE_TEST.md, UNPACK.md and this file brought up to date |
| 2d3b077724, 25b9ec842c | GameCube test hooks left out of App Store builds, archive libraries credited, OVERLOOKED.md |

Phone build ready, not installed: build-app-release, 1.2.0 (18), Release, no-JIT check PASS (dev mode),
keys check PASS. Install it only when you're at the phone.

Waiting for the phone: the tab switch stall (5 to 11 dropped frames at 120 Hz; the Simulator can't measure
it), and the rest of the batch in PHONE_TEST.md "Needs the phone".

Earlier commits:

| Commit | What |
|---|---|
| 3c400fb2be, b7ac1c52f8, dda2f5510f, 2fb57d4a55, d8eb4d5bd1 | Shared home and tab bar, WAD popup, Wii touch controls, notes |
| f7f57d46af | Encrypted Wii discs with the player's own key file |
| 6130f441bb | Every added game goes to its own tab, by its contents (import test matrix below) |
| 9229a88f46 | Controller settings, per-game Wii layouts, file choice popup |
| 2f4e0667df | Per-game layouts for GameCube, welcome card only on the home screen, darker tab icons |
| 71f1260bc2 | Mac test runner: headless GPU submit (memory fix), fps, screenshots |
| c8bbce93dd | Import message stays readable; picker test hooks |
| d4ce433aa6, 61038c05c6 | Retail Wii game check write-up |
| 18a88818a8 | 7Z/xz: the LZMA SDK's arm64 decoder (LZMA decoding 1.5x faster) |
| ba2729fd85 | ZIP: own extractor with 4 MB reads, progress in bytes, Cancel (stored 5x, deflate 2.5 to 3.6x faster) |
| ca71c3af0e, 8c750e00f1 | Unpack timing test (runs only with UNPACK_BENCH_DIR) |
| df4beff9ca, 92055260ac | No "Preloading '0' custom textures" message; custom textures off by default, kept on with a texture pack |
| c6dcc18b26 | Unpack progress card with Cancel, unpacked-size space check, Try Again after a cut-off |
| 24e6b57f23 | gzip unpacked in pieces; tar mapped instead of read |
| 48169925f7, 633f171046 | Cancel stops 7Z/xz (was ignored); unpack card above the tab bar on iPad |

Done: home and tabs, Wii touch controls, Wii formats and key file, import routing with tests, controller
settings, per-game layouts for both systems, same-game file choice, welcome card fix, retail Wii game
check (Super Mario Galaxy RVZ, passed; see "Retail Wii game"), faster unpacking with a progress card (see UNPACK.md).

Open:
- The phone batch (PHONE_TEST.md): tab stall at 120 Hz, imports with Cancel, keyboard, Mario Galaxy 20 min,
  Mario 3D World and BotW, a real controller, the Wii U pause sheet.
- Your call: the open items in UNPACK.md "For you to decide" (WIA LZMA decode speed, multi-core 7Z, playing a stored
  ZIP without unpacking, longer background unpacks, the texture message with a pack installed).
- OVERLOOKED.md: the bigger items that need your answer.
- Merge and push need your go-ahead.

## Menus on all three tabs (Nov 13)

Every menu has the same top: a large title on the left and, at the top right, the home screen's glass circle with an X in the tab's colours (indigo, grey, blue). Screenshots, before and after, side by side: ~/Downloads/Iridia test/menus (outside the repo; the pause shots show game footage).

| Menu | GameCube | Wii | Wii U |
|---|---|---|---|
| Settings | Sheet: Full Version, Speed (Power Mode), Controls, Downloads, Game Files, All Settings, About | Sheet: Full Version, Controls, Wii, Game Files, All Settings, About | Sheet: Full Version, Speed, Downloads, Controls, Screens, Memory, About |
| All Settings | Dolphin's full list (graphics, sound, controllers...) | The same list (it covers Wii games too) | None (the Wii U core has no other settings) |
| Per-game settings | Game Info sheet | Game Info sheet | Game settings sheet |
| Controllers hub | Sheet, indigo | Sheet, grey | Not on this tab (Wii U uses touch and game controllers directly) |
| In-game menu | Paused header, Resume, 4 tiles, Settings / Save & Exit, indigo | The same, grey, plus the Wii controls switch | Paused header, Resume, Screens, Show speed, Quit Game, blue |
| Edit Layout | Reset / Done bar over the game | The same bar | Its own Done bar (screen layout) |
| Help | Large title, close button, indigo | The same, grey | The same, blue |
| Unlock | Full screen, cube, list, buy button | Full screen, Wii mark, the same list | Full screen, Wii U mark, the same list |
| Popups | IridiaAlert, indigo | IridiaAlert, grey | IridiaAlert, blue |

Not checked in the Simulator: the Wii U pause sheet (the Simulator can't run Wii U games).

## Base

- release/1.1.5 merged in. Version 1.2.0 (18).
- Mac regression after the merge: GameCube and Wii checksums match the 1.1 baseline (x4 cfa55e7f, x16 3a2268d2,
  same for the Wii builds), speed a tie. Output in benchmarks/wii/mac-merge-1.1.5.txt.

## Home screen

- One header and tab bar shared by the three shelves. The Wii tab uses grey and white in place of pearl and sage,
  and its popups are grey and white too.
- Switching systems: the shelves crossfade and slide, the header controls morph in Liquid Glass, and the tab
  highlight glides. Each shelf stays loaded once shown, so its art isn't reloaded when switching back.
- Reduce Motion: the shelves and the tab highlight crossfade in place. Reduce Transparency: solid colours.

Switches, frames from a Simulator recording (early, middle, late, settled):

| | | | | |
|---|---|---|---|---|
| GameCube to Wii | ![](progress/wii/tour/gc-wii-0.png) | ![](progress/wii/tour/gc-wii-1.png) | ![](progress/wii/tour/gc-wii-2.png) | ![](progress/wii/tour/gc-wii-3.png) |
| Wii to Wii U | ![](progress/wii/tour/wii-wiiu-0.png) | ![](progress/wii/tour/wii-wiiu-1.png) | ![](progress/wii/tour/wii-wiiu-2.png) | ![](progress/wii/tour/wii-wiiu-3.png) |
| Wii U to GameCube | ![](progress/wii/tour/wiiu-gc-0.png) | ![](progress/wii/tour/wiiu-gc-1.png) | ![](progress/wii/tour/wiiu-gc-2.png) | ![](progress/wii/tour/wiiu-gc-3.png) |
| Reduce Motion, Wii to Wii U | ![](progress/wii/tour/reduce-motion-wii-wiiu.png) | | | |

The Simulator records only frames that change, so it can't show dropped frames. The 120 Hz check needs a device.

## Tab bar icons

- GameCube: an outlined cube. Wii: a slim upright console with one slot line and a base line. Wii U: a TV screen
  with a smaller second screen in front.
- Drawn as vector shapes (Iridia/SystemIcon.swift) on SF Symbols' 24-unit grid with round caps and joins, so they
  are sharp at any size and match Saves, Controllers, Settings and Help, which keep their SF Symbols. The selected
  tab draws a heavier line, and the weight animates.
- The selected tab sits on a Liquid Glass pill in the system's colour (indigo, grey, blue).
- Labels and icons follow the text size up to a cap. At the largest accessibility size "Controllers" shrinks a
  little to fit.
- The mockup (tab-bar-final.png) didn't come through, so these follow the written description.
- Unselected icons on the light Wii and Wii U bars are drawn in the darker text colour
  ([after](progress/wii/tabs/iphone-light-wii-darker-icons.png)). The dark GameCube bar is unchanged.

The welcome card ("Welcome to Iridia") now only shows on the GameCube home screen, with no game open or
opening. Before, a first launch straight into a game (Open in Iridia, or a test hook) could draw it over the game.
Checked in the Simulator: not over a Wii game started at launch, and shown on the GameCube home screen afterwards.

| | GameCube | Wii | Wii U |
|---|---|---|---|
| iPhone light | ![](progress/wii/tabs/iphone-light-gc.png) | ![](progress/wii/tabs/iphone-light-wii.png) | ![](progress/wii/tabs/iphone-light-wiiu.png) |
| iPhone dark | ![](progress/wii/tabs/iphone-dark-gc.png) | ![](progress/wii/tabs/iphone-dark-wii.png) | ![](progress/wii/tabs/iphone-dark-wiiu.png) |
| iPhone, text XXXL | ![](progress/wii/tabs/iphone-xxxl-gc.png) | ![](progress/wii/tabs/iphone-xxxl-wii.png) | ![](progress/wii/tabs/iphone-xxxl-wiiu.png) |
| iPhone, accessibility XXXL | ![](progress/wii/tabs/iphone-ax5-gc.png) | ![](progress/wii/tabs/iphone-ax5-wii.png) | ![](progress/wii/tabs/iphone-ax5-wiiu.png) |
| iPad light | ![](progress/wii/tabs/ipad-light-gc.png) | ![](progress/wii/tabs/ipad-light-wii.png) | ![](progress/wii/tabs/ipad-light-wiiu.png) |
| iPad dark | ![](progress/wii/tabs/ipad-dark-gc.png) | ![](progress/wii/tabs/ipad-dark-wii.png) | ![](progress/wii/tabs/ipad-dark-wiiu.png) |

## Wii touch controls

- Drawn by the same code as the GameCube controls (908ac1704e): the same buttons, trapezoid shoulders (Z, ZL/ZR,
  L/R), the round D-pad base with its cross and the octagon stick gate. Only the colours differ: grey plastic, a
  white A and a light grey rim. Labels: 1, 2, −, HOME, +, C, Z, SHAKE.
- Side by side with GameCube, iPhone and iPad, light and dark: ~/Downloads/Iridia test/controls (ipad.png,
  iphone.png; kept out of the repo because they show game footage). The table below still shows the older
  rounded Wii parts.
- Shake is an on-screen button (holds all three shake axes) instead of a top-bar button.
- Sideways is laid out from the screen size like the others; in portrait its −/HOME/+ row moves above the hands.
- In landscape the Controls switch moves left of any control in the top-right corner (Classic ZR/R, GameCube R).

| | Nunchuk | Wii Remote | Sideways | Classic | GameCube |
|---|---|---|---|---|---|
| iPhone portrait | ![](progress/wii/controls/iphone-light-nunchuk.png) | ![](progress/wii/controls/iphone-light-remote.png) | ![](progress/wii/controls/iphone-light-sideways.png) | ![](progress/wii/controls/iphone-light-classic.png) | ![](progress/wii/controls/iphone-light-gamecube.png) |
| iPhone landscape | ![](progress/wii/controls/iphone-light-land-nunchuk.png) | ![](progress/wii/controls/iphone-light-land-remote.png) | ![](progress/wii/controls/iphone-light-land-sideways.png) | ![](progress/wii/controls/iphone-light-land-classic.png) | ![](progress/wii/controls/iphone-light-land-gamecube.png) |

## Controller settings

- Wii Settings, Controls: controls for new games, aim the pointer (Drag on the screen, Follow your finger,
  Point the phone), pointer speed (each aiming mode keeps its own; hidden for Follow your finger), Show the
  pointer (a dot where the Wii Remote points, off by default), Shake the phone and Tilt the phone (both off
  by default). Recenter is the round button next to the controls in a game and in the player menu. On iPad
  the wording says iPad.
- Per-game layouts: Edit Layout in a game moves and resizes the controls and sets their opacity for
  that game only. A game starts from the layout all games share; Reset goes back to it. Edit Layout from
  the Controllers hub (outside a game) edits the shared layout. Opacity is kept in the game's profile,
  so it applies when the game boots. GameCube games work the same way: their first edit starts from the
  shared layout, which stays as players had it in 1.1.5.
- Controllers: MFi, Xbox and PlayStation pads get the Physical Controller profile for the Wii Remote,
  Nunchuk and Classic Controller (A/B, 1/2 on X/Y, the Nunchuk on the left stick and L, the pointer on the
  right stick or the pad's gyro, shake on R). Every control can be remapped, with Reset to Default.
- The Controllers hub and its screens use the Wii look when opened from the Wii tab.
- Tests: `TouchOverlayLayoutTests.testAGameKeepsItsOwnLayout` (game layout starts from the shared one,
  other games and the shared layout don't see it, Reset clears only the game's) and
  `testGameCubeGamesKeepTheirOwnLayoutAndOpacityStartsShared`. Full suite: 1,486 run, 7 skipped, 0 failures.

| | Screen |
|---|---|
| iPhone dark, Controllers | ![](progress/wii/controls/iphone-dark-controllers.png) |
| iPhone light, Controllers | ![](progress/wii/controls/iphone-light-controllers.png) |
| iPhone light, Wii Settings | ![](progress/wii/controls/iphone-light-wii-settings.png) |
| iPhone, pointer dot | ![](progress/wii/controls/iphone-pointer-dot.png) |
| iPhone dark, Edit Layout in a game | ![](progress/wii/controls/iphone-dark-edit-layout.png) |
| iPad dark, Edit Layout in a game | ![](progress/wii/controls/ipad-dark-edit-layout.png) |
| iPad dark, Wii Settings | ![](progress/wii/controls/ipad-dark-wii-settings.png) |

## Same game in several files

One card per disc (game ID, disc and revision). Play uses the only file that starts without asking for
anything (a disc needing the key file and WAD files don't count). When several can, Iridia's popup asks
which, in the look of the tab; when none can, the card's file is used, so the key-file prompt appears.
The card itself shows a file that plays when there is one. tvOS keeps its list.

![](progress/wii/controls/iphone-light-which-file.png)

## Retail Wii game

**Pending retail check: DONE, passed** (Nov 12, Mac and Simulator only, no phone).

The game: "Super Mario Galaxy (USA, Canada) (En,Fr,Es).7z" from ~/Downloads, 3.23 GB, holding one RVZ of
3.56 GB (game ID RMGE01, NTSC-U, revision 0). A valid retail Wii disc: the partition signatures and H3 hash
tables check out (dolphin-tool verify). Its per-block hash check needs the Wii key, which this setup doesn't
have, so those blocks can't be checked; the homebrew test disc reports the same. Copied (APFS clone) to
~/Downloads/Iridia test/Wii with the RVZ unpacked next to it. Not in the repo or the snapshot. Screenshots
and the Mac stats log are in ~/Downloads/Iridia test/Wii/Mario Galaxy check Nov 12 (kept out of the repo:
they're the game's own pictures).

| Check | Result |
|---|---|
| Key file | RVZ: boots with no key file anywhere (fresh Mac user folder, empty Simulator key slot). No key prompt |
| Choose a Game File (from the GameCube tab) | Copy/Move popup, then copied to the Wii folder; message "Super Mario Galaxy (USA, Canada) (En,Fr,Es).rvz went to the Wii tab."; GameCube shelf unchanged. iPhone and iPad |
| Check Downloads for Games (Wii tab, the 7Z) | "Wii Games in …" offer naming the 7Z; Add unpacked it to the Wii folder (byte-identical to the original RVZ) and moved the 7Z out. Unpacking took ~4.5 min on the Simulator (one core, ~13 MB/s) |
| Shelf | Wii tab, card "SUPER MARIO GALAXY" (the disc banner's own English name is in capitals), Iridia's generated cover (no box art by design), "RVZ" label |
| Boot, Mac | Wrist-strap screen at 1 s; title ~5 s after A (about 30 s if left alone) |
| Boot, iPhone and iPad Simulator | Title screen at 60 fps (iPhone ~50 s, iPad ~80 s with no input) |
| Play, Mac, 10 min | File created, prologue intro, then about 10 min walking, jumping, spinning and aiming around the town |
| fps, Mac | 59.9 average over 583 s of play; per-second 1% and 5% lows 59.9. One dip to 35 fps was a screenshot |
| Headroom, Mac (how much faster than full speed it could run) | Play: median 2.49x, 5% low 2.04x, worst second 1.87x. Title 2.8 to 4.5x. Twilight Princess (GameCube, same no-JIT path) title screens: 3.42x median, 1.76x 5% low |
| Memory, Mac | Flat at ~490 MB for the whole run (after the fix below) |
| Graphics | Title, file select, story book, town, castle, water reflections, bloom and star bits all look right. No problems seen |
| Audio | Recorded 15.5 min of the game's output: continuous, no clipping, 18 near-silent seconds (loading and fades), 6 gaps of 5 ms or more in loud parts. Not listened to; real-time playback needs the phone test |
| Controls, Mac (scripted Wii Remote + Nunchuk) | Pointer (file select, icon and Yes buttons), A, A+B, Nunchuk stick walking in all directions, shake to spin: all work |
| Controls, Simulator | On-screen Wii Remote + Nunchuk drawn in game; Edit Layout opens over the game with "Layout and opacity are saved for this game". Touch, gyro and a real pad can't be driven in the Simulator (see below) |
| Saving | New file saved in game (GameData.bin on the emulated NAND, 22:05). Quit, relaunched: file 1 "Mario" with that date is there, and Play This File starts it |

Not covered here (needs the phone or hands): touch pointer and gyro aiming, real MFi/Xbox/PlayStation
mapping, real-time audio, heat. The Mac's scripted controller went through Dolphin's controller mapping,
the same layer a game controller uses.

Found and fixed:
- **Mac test runner ran out of memory.** Headless runs never sent the GPU's work, so Metal's upload buffers
  doubled until the run asserted at ~7 GB (it also made the Mac's RAM run low). Headless now submits each
  frame's work; it also reports fps (it always said 0) and takes screenshots on request. Only the Mac runner
  changes (the app always has a screen). GameCube and Wii checksums unchanged (x4 cfa55e7f, x16 3a2268d2).
  Earlier Mac headroom numbers were measured with the leak; homebrew headroom reads ~15% higher now.
  Commit 71f1260bc2.
- **"Went to the Wii tab" message never seen.** The library refresh after an import replaced it at once with
  "Library refreshed", and the bar sat half under the tab bar. Import messages now stay 4 s, aren't
  replaced by the short refresh note, and sit above the tab bar. Commit c8bbce93dd.

For you to decide:
- **No progress while a big archive unpacks.** A 3 GB 7Z took ~4.5 minutes with nothing on screen until the
  game appeared. A progress card would need a small design; say if you want it.
- **"Preloading '0' custom textures for 'RMGE01'"** shows at every game start because custom textures are on
  by default in this fork (same in the 1.1.5 GameCube app). Turning the message or the default off is your
  call.

### iPhone 16 Pro estimate (an estimate, not measured)

The CPU emulation is single-thread bound. The A18 Pro's fast core runs about 10 to 20% behind this Mac's
(M4), and a warm phone loses another 15 to 20% (BENCHMARKS #17). Twilight Princess's 2.0 to 2.4x headroom on
the phone at 1x fits the same scaling.

| | Mac (measured) | iPhone 16 Pro, cool (estimate) | iPhone 16 Pro, warm (estimate) |
|---|---|---|---|
| Prologue play, median headroom | 2.49x | ~2.0 to 2.2x | ~1.6 to 1.8x |
| Worst second | 1.87x | ~1.5 to 1.7x | ~1.2 to 1.4x |
| fps | 60 | 60 | 60 expected; dips possible in the heaviest moments |

So 60 fps at 1x and 2x should hold. Things to look at in the phone test: later galaxies with more on screen
(the prologue is light), 3x and above when warm, gyro pointer feel, audio in real time, and battery heat over
20+ minutes.

## Wii files

Every disc format the Dolphin base reads plays: RVZ, WIA, ISO, WBFS, GCZ, CISO, plus .dol/.elf homebrew. WAD
stays not supported.

- ISO, WBFS, GCZ and CISO are encrypted, so they need the player's own key file, picked once, the way the Wii U
  tab asks for a disc key. The app bundles no keys and doesn't say where to get one.
- Until a key file is added those games show "Needs your key file" on the shelf, and Play opens the Key File
  Needed prompt (Wii grey and white). The picked file is copied to keys.bin in Iridia's own Wii storage, kept only
  if it opens the disc (otherwise whatever was there before is put back), and the game then starts. No restart:
  the core reads keys.bin fresh each time it checks.
- RVZ and WIA carry their own disc keys, so they keep working with no key file.
- A disc started some other way (not from the Wii shelf) goes back to the shelf, which opens the prompt.
- Check Downloads on the Wii tab now offers Wii ISO, WBFS, GCZ and CISO too (by the disc header, so GameCube
  ISOs stay on the GameCube tab).
- Old wording ("Encrypted Wii disc images aren't supported") replaced in the shelf, the Play popup, Settings,
  Help, What's New and the review notes. Settings shows whether a key file is added.

How it was tested: the homebrew test disc (DIRB00) was re-keyed to a made-up test key (random bytes, not a
Nintendo key, kept outside the repo), with a matching made-up key file, then converted to every format. CISO and
WBFS have no writer in dolphin-tool, so the earlier CISO/WBFS test files were re-keyed the same way.

Mac (dolphin-emu-nogui, 14 s each, maxSpeed is headroom over full speed):

| Format | No key file | With the test key file |
|---|---|---|
| ISO | Refused at boot | Plays, maxSpeed 13.87 |
| WBFS | Refused at boot | Plays, 14.14 |
| GCZ | Refused at boot | Plays, 14.21 |
| CISO | Refused at boot | Plays, 13.78 |
| RVZ | Plays, 14.28 | Plays, 13.96 |
| WIA (LZMA2) | Plays, 14.34 | Plays, 14.00 |

Simulator (iPhone 18 Pro):

| Step | Result | |
|---|---|---|
| WBFS on the shelf, no key file | "Needs your key file" | ![](progress/wii/keys/shelf-note.png) |
| Play | Key File Needed prompt | ![](progress/wii/keys/prompt.png) |
| A 1 KB file that isn't the key | "That key file doesn't open this disc." Nothing saved | ![](progress/wii/keys/wrong-file.png) |
| A file of the wrong size | "That isn't a Wii key file. A key file is exactly 1 KB." (size checked before reading) | |
| The test key file | Saved, game starts in the same session | ![](progress/wii/keys/wbfs-after-key.png) |
| Shelf afterwards | Note gone | ![](progress/wii/keys/shelf-after.png) |
| ISO, GCZ, CISO with the key | Play | ![](progress/wii/keys/iso.png) ![](progress/wii/keys/gcz.png) ![](progress/wii/keys/ciso.png) |
| RVZ, WIA with no key file | Play | ![](progress/wii/keys/rvz-no-key.png) ![](progress/wii/keys/wia-no-key.png) |
| WAD | "WAD files aren't supported" on the shelf; Play shows the WAD popup | ![](progress/wii/keys/wad-note.png) |
| Homebrew .dol / .elf | Play (unchanged) | ![](progress/wii/formats/Input-DOL.png) ![](progress/wii/formats/ELF.png) |

The Simulator's file picker can't be driven, so the picks above went through a debug-only launch option
(-wiiKeyFileTest, not in Release builds) that hands the prompt a file as if picked.

### Why the earlier WIA test file didn't start

Not the reader and not a missing key: our keyless dolphin-tool wrote the WIA with a wrong partition key, so the
"decrypted" data it stored was garbage. Converted back to ISO it still matched, because re-encrypting used the
same wrong key. A WIA made from a valid source (or with a key file present) plays, as above.

## Which tab a game goes to

Every way a game gets in now goes through one router (Import/GameImport.swift). What a file is comes from its
contents, never its name:
- **GameCube and Wii:** the core's own readers (every disc format, compressed ones included, WAD, DOL, ELF).
- **Wii U:** file signatures: "WUP-" (WUD, or a Wii U .iso), WUX0, WUHB, an RPX's CAFE ELF marking, the WUA
  footer, and game folders (code + meta, or title.tmd).
- **Archives:** recognised by signature, unpacked, and each game inside is sorted the same way.

A game added from another tab goes to its own tab, and a short message says where ("X went to the Wii tab.").
Anything that isn't a game is named ("X isn't a game Iridia can play."), and so is an archive with nothing
playable inside ("X doesn't have a game inside.").

| Way in | Before | Now |
|---|---|---|
| Choose a Game File, GameCube or Wii tab | Any archive went to the GameCube import, which unpacked it into Games (Wii U files in it were lost or landed there). Wii U files only got a message | Router |
| Choose a Game File, Wii U tab | GameCube and Wii files only got "isn't a Wii U game". Archives with no Wii U game were refused | Router: they go to their tab |
| Drag and drop | GameCube import, by extension | Router |
| Open in Iridia, share sheet, AirDrop | By extension; archives went to the Wii U import first | Router |
| Check Downloads, GameCube and Wii tabs | By extension and my header checks | By contents. Archives offered by their list of names, then sorted when unpacked. Never offers a Wii U archive |
| Check Downloads, Wii U tab | Partly by extension | By signature; archives with Wii U names (or keys.txt) offered |
| Files app: archives put in Games | Unpacked into Games by the shelf scan, whatever was inside | Unpacked and sorted (also in the Wii and Wii U folders) |
| Files app: Wii U game in Games | Asked to move | Moved, with a message. Also from the Wii folder |
| Files app: GameCube or Wii game in the Wii U folder | Ignored | Moved, with a message |
| Folders (picked) | Each import walked them its own way | Router walks them (two levels) |
| Web upload (old library screen) | Unpacked into Games | Wii U files and archives that may hold one go through the router |

GameCube and Wii games may sit in either the Games or the Wii folder, since both shelves read both folders.

### Test matrix

`iCubeTests/GameImportTests`, 11 tests, fixtures in DolphiniOSTests/Fixtures/Games. Last run Nov 12 with
the full suite (1,486 run, 0 failures):
- **Discs and programs:** small made-up GameCube and Wii discs, the test disc's RVZ/WIA, small homebrew
  programs, and Wii U files with the right signatures. No real games, no keys; the keys check passes on the
  folder.
- **Archives:** a ZIP and a 7Z of each fixture, plus a mixed archive.
- **How it's run:** each item goes through the router into empty folders. The test checks it is in the
  expected folder and in neither of the other two.

| System | Format | File | ZIP | 7Z |
|---|---|---|---|---|
| GameCube | ISO, GCM, GCZ, CISO, RVZ, WIA, DOL, ELF | GameCube tab | GameCube tab | GameCube tab |
| Wii | ISO, WBFS, GCZ, CISO, RVZ, WIA, WAD, DOL, ELF | Wii tab | Wii tab | Wii tab |
| Wii U | WUA, WUX, WUD, Wii U .iso, WUHB, RPX, game folder | Wii U tab | Wii U tab | Wii U tab |
| Wii U | keys.txt | Added to keys.txt | Added | Added |
| Mixed | GameCube RVZ + Wii WBFS + Wii U WUA + Wii U game folder | | Each to its tab | Each to its tab |
| Not a game | text file, random data, an all-zero .dol | Named as not a game, nothing added | "Doesn't have a game inside" | Same |

All pass. The same tests also cover:
- **Content over names:** a Wii disc named .gcm, a GameCube disc named .wbfs, a Wii U disc named .rvz and a
  Wii RVZ named .wua each land on the right tab.
- **Picked folders:** a folder holding all three systems' games.
- **Files app tidy-up:** stray games and archives in each folder end up in the right place, and GameCube/Wii
  games in either of their folders are left alone.
- **Check Downloads:** each tab offers only its own games.
- **Messages:** the wording from each of the three tabs.

The existing ZipImportHelper (12) and archive safety (25) tests still pass.

Fixed on the way:
- **Wii U Check Downloads:** didn't offer a ZIP or 7Z that only holds keys.txt.
- **Program check:** an all-zero file named .dol would have counted as a GameCube program. A program now needs
  code and an entry point.

## Checks

| Check | Result |
|---|---|
| Unit tests | 1,486 run, 7 skipped, 0 failures (Nov 12, latest commit) |
| Clean Release build, iPhone and iPad | Builds. 1.2.0 (18), device family 1 and 2 |
| No-JIT (`scripts/verify_no_jit.sh`) | PASS on the Release build |
| Keys (`scripts/verify_no_wii_keys.py --strict`) | PASS on the Release app (5,204 files) and the source tree |
| Test hooks in Release | None (`homeTour`, `wiiLandscape`, `wiiAutoplay`, `wiiEditLayout` not in the binary) |

## Still to do

- Tab switch stall at 120 Hz, measured on the phone (idle 120 Hz is confirmed: no drops).
- Remapping with a real MFi, Xbox or PlayStation pad (the Simulator has none).

## Decisions for you

- The 1.1.5 Wii U disc-key wording: left as is, as you decided.
- Same-disc files: built as decided.
- Per-game layouts for GameCube: added as you decided; the shared layout is untouched.
