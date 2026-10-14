# PROGRESS

Running log for the JIT-less GameCube emulator for iOS. Newest entries at the bottom of each phase.

## Phase 0 — Environment setup (2026-10-11)

### Host
- macOS 26.6.2 (25G83), Apple M4, 16 GB RAM.
- Free disk: ~58 GB at start, ~45 GB after Xcode and the simulator runtime. Above the 40 GB target, but Xcode plus the iOS platform, simulators, and Dolphin build trees will use most of it. Watch it.
- Xcode 27 needs macOS Tahoe 26.6 or later, so this Mac qualifies (https://developer.apple.com/support/xcode/).

### Tooling
| Tool | Version | Path | Status |
|---|---|---|---|
| Homebrew | 5.0.9 | /opt/homebrew | already present |
| cmake | 4.4.4 | /opt/homebrew/bin | installed |
| ninja | 1.13.2 | /opt/homebrew/bin | installed |
| git-lfs | 3.8.0 | /opt/homebrew/bin | installed, `git lfs install` done |
| pkg-config (pkgconf) | 3.0.8 | /opt/homebrew/bin | installed |
| ccache | 4.14.1 | /opt/homebrew/bin | installed |
| mas | 7.0.0 | /opt/homebrew/bin | installed |
| Xcode 27 | 27.0 (27A266a) | /Applications/Xcode.app | user installed it from the App Store (mas couldn't: needs sudo, and it can't do a first-time "Get") |
| iOS SDK | iphoneos27.0, iphonesimulator27.0 | — | included with Xcode |
| iOS Simulator runtime | iOS 27.0 (24A434) | — | `xcodebuild -downloadPlatform iOS` (8.05 GB) |

Notes:
- MacPorts is also installed (`/opt/local`). Homebrew comes first on PATH, so Homebrew's pkg-config wins. Dolphin's CMake could still pick up MacPorts libraries from `/opt/local`, so we'll watch for that in Phase 2.
- `mas account` no longer exists on recent macOS, so App Store sign-in was inferred from `mas list`.
- git identity is a repo-local placeholder ("gc-emu developer" <gc-emu@localhost.invalid>). The user will set up GitHub later. Rewrite authorship before anything is pushed publicly (Phase 7).

### Decisions
- **Deployment target: iOS 26.0 minimum, iOS 27 is the priority** (user decision, 2026-10-11).
  - Build with the iOS 27 SDK; set `IPHONEOS_DEPLOYMENT_TARGET = 26.0`.
  - Design, profile, and test mainly on iOS 27. Use iOS 27 APIs and design materials as the primary path, behind `if #available(iOS 27, *)`.
  - iOS 26 gets working, simpler fallbacks. It doesn't get its own design work or performance tuning.
  - Benchmarks in BENCHMARKS.md are recorded on iOS 27 first. iOS 26 gets a smoke test only.

### Pending
- [x] Xcode 27.0 installed; xcode-select already pointed at it; license and first launch done in the Xcode app
- [x] iOS 27.0 Simulator runtime installed; simulators include iPhone 17, 17e, Air, 18 Pro/Pro Max and several iPads
- [x] iOS 27 SDK confirmed
- [x] User added their Apple ID in Xcode > Settings > Accounts (free Personal Team). Signing gets confirmed with the first device build in Phase 2.
- [x] User picks the deployment target (26.0 minimum, iOS 27 prioritized)
- [x] Placeholder git identity (local only) and first commit

**CHECKPOINT 0 complete (2026-10-11).** Waiting for the go-ahead on Phase 1.

## Phase 1 — Research & license check (2026-10-11)
- Wrote RESEARCH.md: App Store landscape, licenses, JIT-less approach, GPL obligations, App Review rules.
- Key findings:
  - Provenance already ships a JIT-less Dolphin GameCube core on the App Store, so there's precedent.
  - iCube (GPL-2.0-or-later) has the most heavily optimized Cached Interpreter.
  - No JIT for App Store apps on iOS 26/27.
  - The Wii common key in Dolphin's source is a Nintendo target, so we should strip Wii support.
  - The "10-min session" model should be framed as free play, not a 3.1.1 "free trial."
- Recommendation: fork iCube's core, build our own app, add upstream Dolphin as a second remote, GameCube-only.

**CHECKPOINT 1 reached.** Waiting for the user's decision on the base codebase.

### Decisions (user, 2026-10-11)
1. **Base:** fork iCube's emulation core (GPL-2.0-or-later) and build our own app. Upstream Dolphin is added as a second remote. Pin to tested iCube commits.
2. **GameCube only:** remove Wii support and the Wii common key from the source tree and the binary.
3. **Naming:** the IAP is "Unlock Full Version." The free tier is called **"free 10-min play sessions"**, never "trial" (so it isn't read as a guideline 3.1.1 "XX-day Trial"). Users can check performance during these sessions, and the FPS overlay stays visible.

## Phase 2 — Baseline build (started 2026-10-11)
- Cloned iCube @ b7fdf8aa with 37 submodules into ~/Projects/gc-emu. Remotes: `icube`, `upstream`.
- Installed tuist 4.211.1 and bartycrouch 4.15.
- ✅ Core xcframework built from source for the iOS Simulator (`BuildiOSXCFramework.py -p SIMULATORARM64`). Log in build-logs/core-sim.log.
- ❌ Simulator app build fails under Xcode 27: "package product 'PLzmaSDK-product' cannot be used as a dependency … uses unsafe build flags". iCube CI uses Xcode 26.3.
  - Try 1: build as-is. Try 2: pin to exact revision 4dbac7ac. Both failed, so I stopped (two-failure rule) and reverted try 2.
  - PLzmaSDK is only used by `ZipImportHelper.swift` (extracting 7z/zip on import).
- devkitPro pacman installer (v6.0.2, SHA-256 verified against the GitHub release) is unsigned. The user needs to allow it in Privacy & Security.
- Fixed the Simulator launch crash (unsigned MoltenVK): use ad-hoc signing. The baseline iCube app runs in the iOS 27 Simulator.
- Built the core from source for OS64 + SIMULATORARM64, and stopped tracking iCube's prebuilt xcframework.
- Downloaded the Metal Toolchain (Xcode 26+ ships it separately).

### Controller work (user request, 2026-10-11): PLAN.md "Touch controls and controllers" + "Smart mapping mode"
- New package `Packages/GCControls`:
  - **GCControlsCore** (pure Swift, 23 unit tests passing on macOS):
    - The pad state is packed into one UInt64 per player, with button bits matching Dolphin's PadButton.
    - A lock-free `PadStateStore` (Swift `Atomic`, separate touch/physical slots, merged on read) and a C ABI `gcpad_read(player)` for the core.
    - Analog math (radial dead zone with rescale, 8-way D-pad), the skin format and validation, three built-in skins (Indigo, Midnight, Orchid), and layout overrides.
    - Smart Mapping: family detection, By position / By label (label letters read at runtime), compiled flat mapping tables, and the profile store (per-game → custom → smart).
  - **GCControlsUI** (iOS):
    - `TouchControllerView`: raw UIKit multi-touch, sliding between buttons, analog sticks, slide-pressure L/R with a digital click, haptics. Art is prerendered; only layer contents are swapped.
    - `PhysicalControllerManager`: a per-controller handler queue, players 1–4, DualSense adaptive triggers, rumble channel, theme light.
    - `ControllerSession` (auto-hide, pause on disconnect, toasts), the layout editor, the visual mapping screen (our own schematic outline plus system glyphs), and the skin picker/importer.
- `Apps/ControlsLab`: test harness (Tuist). Verified in the iOS 27 Simulator:
  - Portrait layout and landscape overlay at 40%.
  - Connect toast ("MFi controller connected — Smart mapping: By position") with auto-hide.
- The portrait skin was reworked to matte plastic: top-left light, bevels, AO shadows, recessed wells, grain, debossed labels, a dished and knurled stick cap, and muted palettes. All of it is prerendered (the shell is a single image).
- Not yet verifiable without hardware:
  - Real touch feel and haptics.
  - Rumble and DualSense triggers.
  - Whether `buttonA` is positional on Switch controllers. The mapping screen's live highlight will show this.
- Core integration comes later: the iOS input backend will read `gcpad_read`, replacing the mutex + std::map StateManager on the hot path.
- ✅ **Device builds** on the user's iPhone 16 Pro (iPhone17,1) with the free Personal Team:
  - Xcode created the certificate and profiles itself via `-allowProvisioningUpdates`, so the user didn't need to click anything.
  - Controls Lab is installed and launched; the user trusted the developer profile.
  - The iCube baseline (Release, NJB) is installed and launched. It uses a new **free-team mode** in `Source/iOS/App/Project.swift` (`TUIST_GCEMU_FREE_TEAM=1`): our bundle prefix, the minimal `FreeTeam.entitlements` (only team ID + `get-task-allow`, no JIT or memory entitlements), and no thumbnail/Quick Look extensions.
  - Layout checks on the iPhone SE (3rd gen) and 13 mini simulators are fine.
- Waiting on: the user's touch-feel feedback; the devkitPro install for the homebrew test program.
- devkitPro installed (the user ran the sudo steps).
  - Fixed "GPGME error: Invalid crypto engine": GPGME finds `gpgconf` only via PATH, so `/opt/devkitpro/pacman/bin` has to be on PATH (`sudo env "PATH=$PATH" pacman …`).
  - Toolchain: devkitPPC 16.2.0 + libogc (cube).
- Built 5 homebrew test programs from devkitPro's examples into `roms/homebrew/` (gitignored): fb-consoletest, gx-triangle, gx-gxSprites, gx-neheGX-lesson06, modplay. Copied them to iCube's `Documents/Software` on the iPhone with `devicectl device copy to`.
  - ⚠️ Licensing: the devkitPro examples have no LICENSE, and modplay embeds a third-party `technique.mod`. They're **for private testing only** and must not be used in screenshots or shipped. Phase 9 needs our own demo program.
- **Our controller now runs in the emulator** (user request, after seeing iCube's own pad):
  - `Source/iOS/App/Common/Swift/GCEmu/GCEmuTouchPadView.swift` hosts `TouchControllerView` (bottom half in portrait, overlay in landscape) and replaces `TCGameCubePad` at both mount sites in `EmulationScreen+TouchAndMotion.swift`.
  - It sends only changed inputs to iCube's `TCManagerInterface`: button IDs and the stick-axis convention match `TCJoystick`, and L/R send an analog value plus a digital click.
  - ☰ posts `DOLShowPauseMenu`. Touches that miss our controls pass through to iCube's gestures.
  - Added an `onStateChange` hook to TouchControllerView.
  - Raised the iCube app's iOS deployment target from 17.0 to 26.0 to match our minimum (GCControls requires 26).
  - Built and installed on the iPhone 16 Pro. The test .dol files survived the reinstall.
  - Note: this bridge still goes through iCube's mutex + std::map StateManager. Phase 4 replaces it with the core reading `gcpad_read`.

## Phase 3 — Enforce no-JIT (2026-10-11, started early at the user's request)
The user saw iCube asking for JIT/StikDebug. The goal is an App Store build with **no JIT at all**.
- **Core** (`GCEMU_NO_JIT`, CMake option, default ON):
  - Excludes JitArm64, VertexLoaderARM64 and Arm64Emitter from the build.
  - Replaces the iOS executable-memory implementations (Legacy/LuckNoTXM/LuckTXM, JITMemoryTracker) with an empty `MemoryUtil_iOS_NoJIT.cpp`, and undeclares the whole executable-memory API in `MemoryUtil.h`.
  - Adds a `static_assert` in `CodeBlock` against executable blocks.
  - `JitInterface` never constructs JitArm64. `DefaultCPUCore()` is the Cached Interpreter, and JITARM64 isn't offered. The vertex loader is always NEON.
  - The `pthread_jit_write_protect_np` lookup is no longer compiled on iOS.
  - The core compiled all 1,275 files with no errors, so nothing else depended on the JIT.
- **App**:
  - `GCEMU_NO_JIT` is defined for C/ObjC/Swift, and `Common/Jit/**` + `JitAcquisitionService.swift` are excluded.
  - The boot path no longer does JIT detection, TXM handshakes or exec-memory allocation, and any JIT CPU setting falls back to the Cached Interpreter.
  - Removed: the "Waiting for JIT" prompt, the ptrace child process, the JIT debug API routes, JIT telemetry, and the JIT/debugger/TXM/StikDebug rows in Debug settings (replaced by a "CPU Emulation: No JIT" row).
  - Removed the bundled `icube.js` StikDebug broker, `dolphin_jit_lldb.py`, `.lldbinit` and the scheme LLDB init hooks.
  - iCube's DebugRootModelBuilderTests (JIT debug UI) are compiled out.
- **`scripts/verify_no_jit.sh`**:
  - Against the old build: FAIL, 7 findings (ptrace/csops, icache flush, JitArm64/Arm64Gen symbols, StikDebug strings, icube.js, no marker).
  - Against the new build: **PASS**.
  - `vm_remap` is allowed: MemArenaDarwin uses it for RW views of emulated RAM (fastmem data, not code).
- Installed the no-JIT build on the iPhone 16 Pro.
- Remaining for CHECKPOINT 3: confirm on the device that the test programs boot with no JIT prompt; release-mode check (no get-task-allow) once we have App Store signing (Phase 9).
- Fix: iCube mounts its programmatic `TouchOverlayView` by default (since its 2026-10-01 change), so our GCEmuTouchPadView never showed. The GameCube pad now always takes the non-hosted path (ours), and iCube skins don't move the game picture. **Verified with a device screenshot** (`devicectl device capture screenshot`): neheGX lesson06 running in the top half, our matte controller in the bottom half.
- Note for Phase 5: iCube's placeholder library covers contain the "Nintendo GameCube" logo, and the app uses a dolphin icon. Both must go when we replace the UI.
- **fb-consoletest black screen fixed.**
  - Cause: three display shortcuts iCube enables by default: Immediate XFB, XFB-to-texture-only (skip XFB copy to RAM) and VBI skip mode 2. They hide frames the CPU draws directly into the XFB.
  - Diagnosed on device: Dolphin file logging showed the .dol booting normally. Turning the three off globally in GFX.ini made the text appear.
  - Fix: `EmulationCoordinator.mm` turns them off in the CurrentRun layer for .dol/.elf only; discs keep the faster defaults.
  - Verified with the original GFX.ini restored: "testing console / Hello World / RTC time" shows.
  - (A first attempt that only changed XFB-to-texture was not enough.)
- Tooling learned this session:
  - `devicectl device capture screenshot` for device screenshots.
  - `devicectl device process launch --payload-url "dolphinios://play?id=<game ID>"` boots a game remotely.
  - `devicectl device copy to/from` with `--domain-type appDataContainer` reads and writes the app's config and logs.
  - `devicectl device orientation set` only works in the Simulator.
- ✅ Input verified end to end: in fb-consoletest, the user tapped START on our on-screen controller. The program's `PAD_BUTTON_START` exit ran and iCube returned to the library.

**CHECKPOINT 2 complete (2026-10-11):**
- The baseline builds for the iOS 27 Simulator and the iPhone 16 Pro (free Apple ID).
- The 5 homebrew test programs boot on the device: graphics, textures, sprites, audio, framebuffer text.
- Our controller works in the emulator in portrait and landscape, and touch input reaches the game.

**CHECKPOINT 3 complete (2026-10-11):**
- The app has no JIT: `GCEMU_NO_JIT` core + app, and `scripts/verify_no_jit.sh` PASSES (development mode).
- Still to do in later phases:
  - Release-mode verification (no get-task-allow) once App Store signing exists (Phase 9).
  - Rebuild the Simulator core slice with GCEMU_NO_JIT before the next Simulator use.

## Phase 4 — Performance (started 2026-10-11)
- Benchmark mode built: `-gcemuBench` writes JSON to Documents/Benchmarks. It's scripted with devicectl (`--payload-url dolphinios://play?id=…`, app args after `--`). Tools: `scripts/bench_compare.py`, `scripts/profile_summary.py`.
  - Profiling: `xctrace record --all-processes` with the hardware UDID. Attaching to a pid fails; the developer disk image was already mounted.
- Baseline maxSpeed on iPhone 16 Pro: 1.78–1.90×.
- **Opt #1** (stall signposts compiled out; StallMetrics default off): maxSpeed **+158% to +198%** (4.57–5.66×).
- **Opt #2** (no CoreMotion polling for GameCube): no speed change (within noise); ≈3% less CPU, for battery.
- Next: real-game workloads from the user's own dumps (the homebrew barely loads the interpreter); texture-hash sampling; audio mixer cost; input path to our lock-free pad state.
- **Paused 2026-10-11 (user break).** In flight:
  - Opt #3: `BuildiOSXCFramework.py` now targets `-mcpu=apple-a13 -mtune=apple-a18` (was apple-a10), since iOS 26 = A13+. The core rebuild was started in the background; it still needs benchmarking (labels `opt3-*`) against opt2.
  - Next candidates:
    - Keep frame pointers (drop `-fomit-frame-pointer`) for readable profiles; measure the cost.
    - Full LTO A/B (`DOL_FULL_LTO=1`).
    - PGO (the script has env-driven support).
    - Route touch input through lock-free `gcpad_read` instead of iCube's StateManager + expression parsing.
    - Audio mixer cost (battery).
    - Real-game workloads once the user adds their own dumps (Files → On My iPhone → iCube → Software).
  - Free-team app installs expire around 2026-10-18; reinstall via BUILDING.md step 5.
- Added **IridiaBench** (`Tools/homebrew/iridiabench`, original GPL program; `make SCALE=n`). x16/x32 are CPU-bound on the iPhone 16 Pro.
- iCube's off-by-default CIR FP/PSQ flags were A/B tested (`scripts/cir_ab*.sh`): no gain, kept off.
- The phone hit "serious" thermal state during sustained benchmarking, so testing was paused to let it cool.
- **Opt #5:** Force25Bit/ClassifyFloat/ClassifyDouble now branch on the common case (asm barrier against if-conversion). Proven bit-identical (all 2^32 floats). **+4.3%** on IridiaBench x16 (interleaved build A/B via `scripts/build_ab.sh`). The phone now runs build B.
- **PGO blocked (stopped after 2 attempts, per the ground rules):**
  - Attempt 1: the app build's "Build Dolphin Core" phase replaced the instrumented core with a normal one. Fix: pass `DOL_PGO=generate` to xcodebuild, as `Tools/pgo/pgo.sh` does.
  - Attempt 2: the core was instrumented, but `___llvm_profile_write_file` / `___llvm_profile_set_filename` are linked "non-external (was a private external)", not exported. So `ICubePGOAvailable()` (dlsym) returns 0, no profile path is set, and nothing is written.
  - Proposed fix: export those two symbols in DOL_PGO=generate builds (`-Wl,-exported_symbol,…` in BuildiOSXCFramework.py, next to the existing `-u` flags). Awaiting the user's OK.
  - Build B was reinstalled on the phone.
- **PGO adopted:** +3.3% to +4.9% on all three workloads. The profile is stored at `pgo/icube.profdata` (Git LFS). The phone now runs build E (PGO). Metal confirmed over Vulkan (3–6%). The IridiaPerformance package is done (11 tests).
- **Paused 2026-10-12 (overnight).** The phone runs build E (PGO). Next: the user adds their own Twilight Princess dump; then benchmark, profile and retrain PGO on it; then finish Phase 4 (FPS overlay) and CHECKPOINT 4.
- **Compressed game import (user request):**
  - `.zip` already worked.
  - Restored `.7z`/`.xz` by vendoring PLzmaSDK 1.6.2 (MIT + LZMA SDK public domain, commit 4dbac7ac, trimmed to 3.7 MB) as a local package (`Packages/PLzmaSDK`). PLzmaSDK streams to disk; SWCompression's 7z path decompresses into memory and would crash on a 1.4 GB game.
  - Verified on device: a .7z and a .zip pushed into Documents/Software were auto-extracted at launch, and the extracted .dol booted.
  - Told the user that RVZ plays without extraction.
  - To do for Phase 5/7: credit PLzmaSDK and LZMA SDK in Acknowledgements.
- **One obvious game folder (user request):**
  - Dolphin's user folder moved to `Library/Application Support/Iridia` (hidden from Files). Games go in `Documents/Games`, the only folder Files shows.
  - `UserFolderUtil.migrateLegacyLayoutIfNeeded()` runs first in AppDelegate. The Wi-Fi upload server now targets Games, and the benchmark/PGO/debug-snapshot folders are hidden. Scripts use `$UDIR`.
  - Verified on device: Files shows only "Games", the library lists all 12 programs, and neheGX boots.
  - The hint text now tells users where to put games.

- 2026-10-12: Import picker Recents spun on "Loading". Cause: Recents is a query of iOS's Spotlight file index (stale/rebuilding index on iOS 26/27), not app code. Fix: GameFilePicker presents UIDocumentPickerViewController with directoryURL so it opens on Browse.
- 2026-10-12: TP (own dump) profiled live in Ordon: full speed, CPU thread ~37% busy. Audio was ~13% of app CPU; mixer fix cut it ~67% (BENCHMARKS #10).
- 2026-10-12: Resume-where-left-off on by default (+background save), verified on device with TP: relaunch resumes in ~14 s. Pause menu Performance tile; VBI warning.
- 2026-10-12: Video settings: simple Picture section (Resolution slider + Aspect Ratio), the rest under Advanced. Resolution sweep 1x–8x on TP: full speed throughout (BENCHMARKS #11). Bench mode can start from a save state.
- 2026-10-12: Branding: Iridia logo (in-app), app icon, display name "Iridia" (bundle ID unchanged, saves kept). Save backup at ~/Projects/gc-emu-save-backup/.
- 2026-10-12: Phase 4 finished. FPS & speed overlay (2 Hz SwiftUI pill, forced-on hook for free play), QoS reviewed (already right), memory measured (TP 0.6–1.4 GB), PGO retrained on TP (no gain, old profile kept). CHECKPOINT 4 presented.
- 2026-10-12: Phase 5 started. Direction A chosen. Glass cube is a real 3D model (SceneKit refraction shader; Blender script for stills). Icon + launch screen rendered from the model; AI art removed. Glass Shelf library home built and on device.
- 2026-10-12: Glass pause sheet, interface sounds (no music), shelf controller navigation, landscape/iPad shelf layouts. Pause backdrop capture does not land (dark backdrop for now).
- 2026-10-12: Pause sheet see-through (game visible), Acknowledgements, per-device presets + Power Mode, Keep Cool on by default (gentler), Settings restyled, shelf Settings button fixed.
- 2026-10-12: Phase 6 built. IridiaStore package (StoreKit 2 unlock + FreePlayTimer), 10 tests pass in Tools/StoreTestHost (purchase, persist, restore, refund re-locks, cancel). Free play session + unlock screen verified on device (25 s test session). Product loads once the IAP exists in App Store Connect (Phase 9).
- 2026-10-12: Phase 7 started. Removed iCube Sentry telemetry (was sending crash/perf data to iCube's Sentry account); verified no Sentry in the binary. Next: PrivacyInfo.xcprivacy, strip Wii firmware/NAND/online-update UI, memory entitlement decision, store docs, GPL repo prep (ask before pushing).
- 2026-10-12: Phase 7: firmware/Wii features removed (HLE boot, no IPL anywhere), privacy manifest, clean App Store entitlements + Iridia App Group/identifiers, local-network usage text, AltServer Bonjour removed. Store/ docs: review notes, listing, privacy policy, age rating + privacy label. Remaining: GPL repo (needs owner decisions).
- 2026-10-13: Phase 8 started. All package tests pass (GCControls 23, IridiaPerformance 11, IridiaStore 10). New `scripts/smoke_test.sh` boots each test program on the phone and checks full speed: 7/7 pass incl. TP (BENCHMARKS #14). Phone is at 8x resolution (left from the sweep), which explained the lower headroom; no regression. Hyrule Field needs a save there from the owner.
- 2026-10-13: Owner requests: Keep Cool removed (no resolution drop when hot); Resolution slider confirmed in free sessions and moved to the top of the in-game Performance panel; camera-stick invert confirmed by the owner. Hyrule Field skipped (owner has no time; free sessions let players test). Frame stability study (BENCHMARKS #15): heat throttling is the main cause; ImmediateXFB was on on the owner's phone and made pacing worse (turned off: +9% headroom, −5% CPU, steadier).
- 2026-10-13: iPad Pro 12.9" 3rd gen (A12X) added as a test device. Core now built for A12 (iPadOS 26 still supports A12/A12X iPads); A12 iPads added to the device tiers. TP transferred; full speed at 1x–4x (BENCHMARKS #16). Fixed: Immediate XFB no longer seeded on for new installs (iCube default), benchmark file dates on non-Gregorian calendars, "1 games", iPad shelf case not centred. Device scripts now require GCEMU_DEVICE (a paired iPhone showed up over Wi-Fi and two runs went to it by mistake).
- 2026-10-13: Save States, Game Info and Controllers screens restyled to the Iridia look (IridiaScreenStyle.swift); verified on iPhone; smoke test 7/7. Game Info drops the Wii sensor bar and the never-populated 'Apply Recommended'. Test hook -iridiaOpen saves|controllers|properties.
- 2026-10-13: Shelf '+' is now a menu: Choose a Game File, or Add with the Files App (guide restyled). The Continue (resume) save now gets a picture (pause preview on Save & Exit, live frame on leaving the app or when a free session ends); save thumbnails are decoded at card size and shrunk on disk (8x screenshots were ~13 MB). Test hooks: -iridiaOpen filesguide, -iridiaResumeAnswer continue|title.
- 2026-10-13: Vibration is now a setting (Controllers > Touch Controls > Vibration, key iridia_haptics), off by default; covers the Iridia and legacy on-screen pads and all interface taps. Controller rumble unchanged.
- 2026-10-13: Owner clarified: keep button vibration (back on by default, now 'Button Vibration'), and make game rumble on the device optional: new 'Game Rumble' setting (iridia_game_rumble, off by default) checked in the core's iOS Motor for the touchscreen's motor and the device-haptics mirror.
- 2026-10-13: App unit tests running for the first time on the Simulator (core Simulator slice built): 1466 tests, 0 failures, 7 skipped. Fixed: test target deployment target, skin fixture identifier (traversal tests weren't exercising anything), 7 tests out of date with intentional changes; Sentry link test inverted into a no-telemetry guard; ICubeCardFocusTests skipped on iOS 27 (two renders of the same view differ).
- 2026-10-13: Heat study (BENCHMARKS #17): GPU nearly idle up to 4x (8%), ~82–87% from 5x; CPU profile flat (in-app sampler, Instruments couldn't attach). Owner chose to keep 8x with a warning from 5x. Found devicectl 'copy to' silently skips a same-size file that's older than the device copy, so ini_ab restores could fail (likely left the phone at 3x); fixed (touch + verify). Phone set back to 3x where it was found.
- 2026-10-13: UI text pass (owner: 'sound less like AI'): ~190 user-visible strings rewritten plainly; ja translations re-keyed; Wii-only and developer-only screens left as is. 1466 tests pass.
- 2026-10-13: v1 scope: no RetroAchievements; built-in Help replaces iCube's online wiki; no cover downloads (generated Iridia covers or the player's own image; old GameTDB covers deleted); iCloud Sync, Wi-Fi upload/WebDAV and Nearby Devices held back behind IridiaFeatures.networkSharing.
