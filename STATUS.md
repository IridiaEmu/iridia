# Iridia: status (2026-10-12)

Iridia is a GameCube emulator for iPhone, built for the App Store **without JIT**. It's forked from
iCube (GPL-2.0-or-later), which is built on Dolphin. The business model is a free download with
free 10-minute play sessions, plus a one-time $2.99 "Unlock Full Version" in-app purchase. A free
3DS mode is planned for later. Repo: `~/Projects/gc-emu` (local git only, nothing pushed yet).
Docs: PLAN.md, PROGRESS.md, RESEARCH.md, BUILDING.md, BENCHMARKS.md, PERFORMANCE_EVAL.md, ASSETS.md.

## Done

### Phase 0–1: environment and research
- Xcode 27, iOS 27 SDK, devkitPro and build tools installed. Tested on an iPhone 16 Pro running iOS 27.
- RESEARCH.md covers:
  - Competitors.
  - Why App Store apps can't use JIT on iOS 26/27.
  - GPL obligations.
  - App Review risks (guideline 3.1.1 trial wording, 5.2.1 IP).
  - The decisions made: GameCube only (Wii and its key stripped), free tier called "free 10-min
    play sessions" (never "trial"), in-app purchase named "Unlock Full Version".
- Deployment target: iOS 26.0 minimum, with iOS 27 the priority.

### Phase 2: baseline build
- iCube forked; builds with Xcode 27. A free Apple ID signing mode was added for device installs.
- Homebrew test programs boot on the device. Touch input works.

### Phase 3: no JIT
- The `GCEMU_NO_JIT` build option removes:
  - The JIT backends and ARM64 code emitters.
  - Executable-memory, TXM and StikDebug code.
- The core runs Dolphin's Cached Interpreter.
- `scripts/verify_no_jit.sh` checks entitlements, imported symbols, defined symbols, a build marker
  and bundled files. It passes on the current build. The only item it reports is `get-task-allow`,
  which Xcode's development signing adds and App Store signing removes.

### Phase 4: performance (checkpoint 4 presented)
- **Tooling:**
  - Benchmark mode, with JSON reports that include memory and a start-from-save-state option.
  - Interleaved A/B scripts and Instruments profiling scripts.
  - IridiaBench, our own GPL CPU benchmark.
- **Adopted** (numbers in BENCHMARKS.md):

| Change | Effect |
|---|---|
| Compiled out iCube's always-on os_signpost markers | +158–198% headroom |
| Branchy fast paths for float rounding and classification (bit-identical) | +4.3% |
| Profile-guided optimization | +3.3–4.9% |
| Metal instead of MoltenVK | 3–6% faster |
| Audio mixer skips 9 unused audio streams (bit-identical) | Audio thread CPU −67% |
| No CoreMotion polling for GameCube games | Battery only |

- **Rejected after measuring** (all within noise):
  - Full LTO.
  - Call-free NEON paired-singles.
  - iCube's experimental Cached Interpreter FP flags.
  - Retraining PGO on Twilight Princess.
- **Results with Twilight Princess** (the owner's own dump), Ordon area:
  - Full speed at 1x–8x internal resolution.
  - Memory: 0.6–1.4 GB.
  - Hyrule Field and Castle Town are **not measured yet**.
- **Built:**
  - FPS & speed overlay, with a hook to force it on during free sessions.
  - Live Performance panel: resolution, frame rate and CPU clock sliders, with a warning that the
    frame-rate setting can speed games up.
  - `Packages/IridiaPerformance`: device tiers, presets, power modes, thermal governor, labelled
    speed hacks. **Not yet wired into the UI.**

### Usability fixes
- **Importing games:**
  - Formats: .iso, .rvz, .gcm, .ciso, .zip and .7z (archives unpacked automatically; PLzmaSDK vendored).
  - The Files app shows a single Games folder; Dolphin's data is hidden.
  - The import picker opens on Browse (its Recents tab depends on iOS's search index and can hang).
  - An in-app guide explains adding games with the Files app.
- **Saves:**
  - Resume-where-you-left-off, saved on exit and when the app goes to the background.
  - A "Continue / Title Screen" choice.
  - In-game memory-card saves verified.
- **Audio and display:**
  - Game audio plays with the silent switch on (an inverted setting was fixed).
  - A Resolution slider at the top of Settings → Video, with the advanced options moved below.

### Phase 5: app shell and design (in progress, direction A "Glass Shelf")
- **Branding:**
  - Name Iridia (display name only; the bundle ID is unchanged, so saves were kept).
  - The glass cube is a **real 3D model** (SceneKit custom refraction, dispersion and thin-film
    shader), live in menus and rendered once for small images.
  - App icon and launch screen are rendered from that model. All AI-generated art was removed.
  - Covers that copied Nintendo box art, and the Dolphin/iCube logos, were replaced.
  - Sources are listed in ASSETS.md.
- **Library home:**
  - A 3D carousel of glass game cases, with Continue / Title Screen.
  - A liquid-glass tab bar (Games, Saves, Controllers).
  - Controller navigation, and iPhone landscape and iPad layouts.
- **Pause menu:** a glass sheet with Resume, Save/Load State, Performance, Controls, Settings,
  Save & Exit, and More (the full option grid).
- **Controls:** our own touch controller and Smart Mapping for physical controllers (`Packages/GCControls`).
- **Decided:** no music and no interface sounds; haptics stay.

## Not done (blocks release)
1. **Phase 5 remainder:**
   - Landscape, iPad and controller navigation are built but not yet tested on device.
   - Secondary screens (save-state browser, controller hub, game properties) keep iCube's layout,
     in dark mode.
   - The source-code link (`IridiaLinks.sourceCode`) is unset until the public repo exists (Phase 7).
   - Since this status was first written: Acknowledgements page added, device presets and Power
     Mode wired in, Keep Cool heat manager on by default, Settings restyled, the paused game now
     shows behind the pause sheet, and the shelf's Settings button (which did nothing on iPhone)
     fixed.
2. **Phase 6, StoreKit 2 (not started):**
   - The $2.99 non-consumable in-app purchase.
   - The 10-minute session timer, with auto-save and the unlock screen.
   - Restore purchases, transaction verification and refunds.
   - A local .storekit file, and a review of the 3.1.1 wording.
3. **Phase 7, compliance (mostly done 2026-10-12; only the public repo push is left):** Sentry removed; privacy manifest; firmware/Wii features removed, HLE boot with no IPL; clean App Store entitlements with increased memory and our App Group; Store/ paperwork written. Original list:
   - PrivacyInfo.xcprivacy.
   - High-level boot with no BIOS/IPL.
   - A **public GPL source repo**, required before release. Commits use a placeholder author that
     must be rewritten first.
   - App Review notes, description, keywords, age rating and privacy policy.
   - A review of whether downloading cover art (GameTDB) is OK for the store.
4. **Phase 8, testing (started 2026-10-13):** package tests 44/44 pass; device smoke test `scripts/smoke_test.sh` 7/7 pass (BENCHMARKS #14). Still to do:
   - Unit and smoke tests in CI. The updated settings unit tests haven't been run, because a
     simulator build of the core isn't set up.
   - Oldest and newest supported devices; Hyrule Field benchmarks; a compatibility list.
5. **Phase 9, release prep (not started):**
   - Apple Developer Program ($99/yr) and the Small Business Program.
   - App Store Connect record, in-app purchase setup, TestFlight.
   - Screenshots showing only homebrew.
   - The app currently uses a **free Personal Team**. Installs expire every 7 days and there is no
     App Store distribution yet.
6. **Phase 10 (3DS):** only after the GameCube release.

**Verdict: not ready for release.** The emulator core, the no-JIT build and performance are in good
shape, and the app shell is partly built. Payment, compliance, the public source repo, testing and
the App Store setup are all still to do.
