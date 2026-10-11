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
