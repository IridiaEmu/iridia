# Wii U update: plan

Branch `release/wiiu-update`, made from `main` at 3ce38ce792 (App Store build 14, the released app).
Worktree: `~/Projects/gc-emu-wiiu-update`. `main`, the App Review build and the public GitHub repo stay as they are.
Nothing is pushed.

## 1. What gets merged, by folder

Source: branch `experimental/wiiu` (`~/Projects/gc-emu-wiiu/WiiU`). The Cemu clone there is not in git; its changes
live in `patches/cemu-iridia-study.patch` on top of Cemu commit 2c212b5.

| New folder in this branch | What it is | From |
|---|---|---|
| `Externals/Cemu/` | Cemu source (MPL-2.0) at 2c212b5 with our study patch applied: `src/` (core, threaded interpreter, Metal renderer, iOS bridge, iOS audio), `CMakeLists.txt`, `cmake/`, `dependencies/ih264d`, `dependencies/ZArchive`, `dependencies/imgui`, `dependencies/metal-cpp`, `LICENSE.txt`, game profiles and resources (translations + Noto shared fonts) | Cemu clone + patch |
| `Externals/Cemu/ios/` | Build script for the iOS core (CMake, iphoneos + iphonesimulator) that links everything into one dynamic framework, `IridiaCafeCore.framework`, plus the vcpkg manifest and triplets for its libraries | `WiiU/ios`, `WiiU/triplets` |
| `Source/iOS/App/Common/Swift/WiiU/` | The Wii U tab: library, settings, play screen, touch controls (PadArt), free play session | `WiiU/ios/App/Sources`, rewritten for the white and blue theme |

What ships, and is on by default (the settings the phone runs today):
- Threaded block interpreter (`CEMU_TBI`), no JIT (`CEMU_NO_JIT`), paired-single steps + wide psq (on unless `IRIDIA_PS_FAST=0`).
- Metal renderer with the continued-draw fast path (`IRIDIA_FASTDRAW`, on) and the cache memoisation, tracked shared
  buffers, in-pass streamout copies.
- Variable frame timing (`IRIDIA_VRR=1`) together with the audio catch-up and audio stretching it was measured with
  (`IRIDIA_AX_CATCHUP=4`, `IRIDIA_AUDIO_STRETCH=1`); a Wii U setting can turn the three off.
- iPhone thread layout, GPU thread at utility QoS, 100000-cycle time slices.
- Player options (off by default): Performance mode, Use less memory, GamePad screen.

What stays out:
- The AOT static recompiler (CMake option and its files removed), the counting build (`IRIDIA_COUNTERS`), the
  read/store watch and dirty-cost builds, the no-JIT negative control.
- Research switches: every `IRIDIA_*` environment switch that is not a product setting is compiled out
  (`IRIDIA_SHIP=1`: the switch reader returns "not set" for them, so their code is dead and stripped).
- Test tools and benchmark scripts (`WiiU/tools`, `run_botw.sh`, `abrun.sh`, phone scripts), the hang watchdog, the
  per-second diagnostics, the paired-single self-test, recordings, the WebAssembly test, the pad preview, `-cafeEnv`,
  `-cafeAutoplay`. Also the 75%/50% internal resolution option (the owner prefers native resolution).
- Cemu's desktop GUI (wxWidgets), Vulkan, OpenGL, cubeb, SDL, Discord, `xbyak_aarch64` (the JIT assembler).
- Online features: the account stays offline (no Nintendo Network or Pretendo login, no downloads).

## 2. Conflicts with the GameCube code

| Area | Conflict | How it is handled |
|---|---|---|
| Linking | Both cores bundle their own fmt, zlib, zstd, libpng etc. Static linking both into one binary would mix versions. | Cemu is its own dynamic framework (like `PVlibDolphin.framework`) and exports only the bridge classes (`CemuBridge`, `CemuTitle`, `CemuPerf`). Nothing else is visible to the app or to Dolphin. |
| Shared UI | The shelf's tab bar (Games, Saves, Controllers) is GameCube only. | One new tab, "Wii U", in that bar. It opens the Wii U home, which has its own bar with a GameCube tab to go back. An empty GameCube library also shows a Wii U button. |
| Settings | Different keys and screens. | Wii U settings live in the Wii U tab, with their own `cafe*` keys. GameCube Settings only gain Cemu in Acknowledgements. |
| File picker / folders | GameCube games are in `Documents/Games`. | Wii U games go in `Documents/Wii U` (visible in Files), keys.txt next to them. The GameCube scan never looks there. |
| Renderer | Both use Metal. | Separate layers and devices; only one core runs at a time (the UI never starts one while the other runs). |
| Audio | Both use AudioToolbox output. | Same audio session category as the GameCube side. Cemu's output unit is created only while a Wii U game runs. |
| Input | The shelf installs controller handlers for navigation. | The Wii U screen takes the controller over the same way the GameCube game screen does (controller scope), and gives it back on exit. |
| Store | One product, `iridia.unlock.full`. | Same `UnlockStore`, same purchase: one unlock covers both consoles (decision to confirm, see 7). |
| Memory | Both reserve large address ranges for the emulated console. | Only while their game runs. Cemu frees its range when the Wii U game ends. |

## 3. The Wii U tab

- Label "Wii U (Experimental)" at the top of the screen; "Wii U" on the tab button.
- Look: white or very light background, blue accents (buttons, selection, icons), our own rounded cards. Original:
  no Nintendo logos, fonts, icons, sounds or menu layouts (no tile grid like the console menu, no GamePad drawings
  in the UI chrome). SF Symbols and the system font only.
- Contents: game list (title, last played), Add a Game (Files app guide, plus a folder or file picker), Settings
  (Variable frame timing, Performance mode, GamePad screen, Use less memory, button vibration, touch controls
  visibility, how to add games and keys, no-JIT check), Unlock Full Version and Restore Purchases.
- Light and dark mode: light mode is white with blue; dark mode keeps the blue accents on a dark navy so the tab
  stays readable at night. Checked on iPhone and iPad (Simulator screenshots).

## 4. Free play and Unlock Full Version for Wii U

- Same system as GameCube: `FreePlayTimer` from the IridiaStore package with a 20-minute limit and a 1-minute
  warning. Like GameCube it is called a free play session (never "trial", Guideline 3.1.1); it repeats each time
  a game is started.
- Counts only while a Wii U game is on screen and the pause sheet is closed.
- At 20 minutes the game's input stops, sound is muted and the full-screen purchase screen (`UnlockView`) appears.
  Buying continues the game; Quit Game goes back to the Wii U library.
- Without a game: the Wii U home has an "Unlock Full Version" button in its header and in its Settings, and the
  purchase screen has Restore Purchases. A reviewer can reach both without loading anything.
- Restore Purchases is the same `AppStore.sync()` path; an unlock made on either side shows on both.

## 5. Memory entitlement and devices

- The app already has `increased-memory-limit` and `extended-virtual-addressing` (Cemu reserves a 4 GB+ range for the
  console's memory). No new entitlement.
- BotW uses about 2.7 GB on the phone. Wii U games are allowed on devices with at least 8 GB of memory: iPhone 15
  Pro / Pro Max, all iPhone 16 and 17 models, iPhone Air, iPad mini (A17 Pro), and M1 or newer iPads. Other devices
  still show the tab (so anyone can read about it and buy) but explain that this device can't run Wii U games.
- Speed: iPhone 16 Pro runs BotW at about 15 to 20 fps after the phone warms up; the tab says it is experimental.

## 6. App size

| | App on disk | .ipa |
|---|---|---|
| Before (build 14) | 136 MB | 103 MB |
| After (estimate) | about 185 MB (+~20 MB core, +27 MB fonts, +1 MB profiles) | about 130 MB |
Measured numbers go in UPDATE_DONE.md.

## 7. Decisions that are the owner's (I continue with the first option)

1. One purchase for both consoles (existing buyers get Wii U). A separate Wii U product would need a new IAP in App
   Store Connect.
2. Free play session length is 20 minutes per session for Wii U (the GameCube side keeps 10).
3. Devices: 8 GB rule above.
4. Export compliance: `ITSAppUsesNonExemptEncryption` stays false. Cemu's AES is used only to read the player's own
   game files (no network, online features off). Worth a second look before submitting.

## 8. Licensing, and what must be published as source when the update ships

- Cemu files keep their MPL-2.0 license and notices (`Externals/Cemu/LICENSE.txt`, file headers). Our changes to
  Cemu files are MPL-2.0 too. MPL-2.0 allows combining with GPL code (no "Incompatible With Secondary Licenses"
  notice in Cemu).
- Added to Acknowledgements: Cemu (MPL-2.0), Noto Sans CJK fonts (SIL OFL 1.1), and the libraries the Wii U core
  links (Boost, fmt, pugixml, zlib, zstd, libzip, libpng, glslang, rapidjson, Dear ImGui, metal-cpp, ih264d,
  ZArchive and the rest from the vcpkg list).
- To publish when the update ships (same repo, same written offer):
  - All of `Externals/Cemu/` (patched Cemu source, build script, vcpkg manifest and triplets, licenses).
  - `Source/iOS/App/Common/Swift/WiiU/` and every other app file changed on this branch.
  - The build steps for `IridiaCafeCore.framework` (in BUILDING.md).
  - Not published: game files, keys, firmware (none are in the repo), App Store Connect scripts (already untracked).
- Before pushing: the experimental/wiiu history still has Claude trailers; this branch copies files, not that
  history, so nothing from it needs rewriting.

## 9. Steps

1. This plan. 2. Merge (vendor Cemu, framework build, link). 3. Wii U tab. 4. Free play + unlock. 5. Tests:
GameCube regression (Simulator benchmark, checksums of the Dolphin core, UI flows, store tests), Wii U BotW in the
Simulator (boots, plays, checksums vs the study build), 20-minute Mac play test, no-JIT checks, iPhone and iPad
builds. 6. Icon options. 7. Review and update notes. 8. UPDATE_DONE.md.
