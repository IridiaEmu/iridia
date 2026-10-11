# PLAN

The master plan for gc-emu: an App Store–compliant, JIT-less GameCube emulator for iPhone/iPad. The SDK is iOS 27; the minimum is iOS 26.0, with iOS 27 first.
Running log: [PROGRESS.md](PROGRESS.md) · Research: [RESEARCH.md](RESEARCH.md) · Build steps: [BUILDING.md](BUILDING.md)

## Branding (updated 2026-10-11)

- **Home-screen name: Iridia.** App Store title TBD by the user (something like "Iridia: Retro Emulator"; never a console maker's name).
- **App name: Iridia.** From the Greek root for "rainbow" (iris/irid-). Replaces all "gc-emu"/placeholder naming in user-facing text. Internal code names (repo folder, `GCEMU_NO_JIT`, package names) may stay.
- **Name check (2026-10-11):** no App Store app is named exactly "Iridia". Similar names exist in unrelated categories (iRidium control panels, Iridium satellite apps). Final availability is confirmed when the name is reserved in App Store Connect (Phase 9); a trademark search is recommended before launch.

### Cube motif (replaces the earlier blanket ban on any cube motif)
- The app icon and logo **may** feature an original cube: a translucent, iridescent glass cube (shimmering purple → blue → teal) with light refracting through it into a small rainbow, reflecting the name Iridia.
- The cube must be clearly our own design: **no letters or symbols** inside or cut out of it, and **nothing resembling Nintendo's GameCube logo** in shape, construction, color layout, or style.
  - Specifically avoid: a cube built from a letterform or negative-space "G", nested cubes or a cube-in-a-cube outline, the isometric three-face line-art construction with a hollow center, and Nintendo's purple/indigo flat color blocking.
  - Ours: a solid, glassy, light-transmitting volume with soft rounded edges, a gradient tint, and an external rainbow refraction.
- If any version could be mistaken for Nintendo's logo, flag it and propose an alternative.
- **Show 3 icon concepts before finalizing**, rendered at App Store icon sizes (1024 px, plus home-screen sizes 180/120/87/60 px) on a home-screen mockup.
- **Risk:** a cube icon on a GameCube-focused emulator raises the odds that App Review or Nintendo sees confusing similarity (guideline 5.2.1), even if the design is original. Keep a non-cube fallback concept (e.g. a prism splitting light) ready.
- Unchanged: no "G" motif, no Nintendo logos, names, fonts, startup animation, sounds, or original menu layout.

## Phases
0. Environment setup ✅
1. Research and license check ✅ (base: iCube core, GameCube-only, "Unlock Full Version" + "free 10-min play sessions")
2. Baseline build (in progress)
3. Enforce no-JIT
4. Performance (maximum optimization)
5. App shell (SwiftUI) and design
6. Free 10-min play sessions and unlock (StoreKit 2)
7. App Store compliance
8. Testing
9. Release prep
10. 3DS mode (later, free)

Performance comes first in every phase.

---

## Touch controls and controllers (Delta-style)

_Added 2026-10-11 at the user's request._ Implemented as the Swift package `Packages/GCControls`, independent of any app, so our Phase 5 app shell (and the 3DS core later) can reuse it. `Apps/ControlsLab` is the test harness.

### Portrait
- The game screen is in the top half; an on-screen controller fills the bottom half (like Delta's N64 skin).
- Every GameCube input: A, B, X, Y, Start, Z, L and R triggers, main analog stick, C-stick, D-pad, plus a Menu button.
- An original illustrated skin in our own style: indigo/purple glassy background, soft shading, rounded glossy buttons. Button layout, relative sizes and colors match what GameCube games refer to, so in-game prompts make sense (A = large green, B = small red, Z = purple, C-stick = yellow, X/Y/L/R/Start = gray).
- Don't trace or copy Nintendo's controller artwork or photos, and put no Nintendo logos or trademarks on the skin. Our own app logo goes where Delta puts theirs, but only once the real logo exists (Phase 5). The temporary sparkle mark was removed because it read as an "AI" button (user feedback, 2026-10-11).
  - **Flag:** X and Y use our own rounded-pill shapes, not the original kidney shapes, and the skin is drawn in code from our own primitives.

### Landscape
- The game screen fills the display (respecting the aspect-ratio setting).
- The same controller layout is overlaid on top with adjustable transparency (default ~40% opacity) and stays fully usable.

### Touch feel
- The main stick and C-stick are true analog: drag distance controls how far the stick is pushed.
- L/R are analog by slide distance (touch = light press, sliding toward the screen edge = deeper press, the digital click fires at full press), with a "digital triggers" fallback.
- Haptics on presses (toggleable), multi-touch, and sliding between buttons without lifting your finger.
- Fast path:
  - The UIKit view handles raw touches, with no SwiftUI gesture system.
  - The skin art is drawn once per size; only small highlight layers change when pressed.
  - All of a pad's state is published as **one lock-free 64-bit atomic word per player**. The emulation thread reads it without locks, replacing the core's current mutex + `std::map` StateManager on the hot path.

### Physical controllers
- On connect (GameController framework), hide the on-screen controller automatically; in portrait the game screen expands into the freed space.
- On disconnect, pause the game and bring the on-screen controller back.
- Supported: Xbox, PlayStation (DualShock/DualSense), Switch Pro/Joy-Con, MFi, and Backbone-style controllers, with up to four for multiplayer (players 1–4).
- Input handlers run on a dedicated serial queue, never the main thread.

### Customization
- Per-controller-type mapping profiles: remap any physical button to any GameCube input. Saved separately for each controller model, and optionally per game.
- Adjustable analog dead zones and sensitivity.
- On-screen controller editor: move, resize and change the opacity of each button, separately for portrait and landscape, with "Reset to default."
- Skin system: layouts are stored as a simple, documented format (JSON + optional embedded images, see [docs/SKIN_FORMAT.md](docs/SKIN_FORMAT.md)), so new layouts can be added later. Ship the default skin plus alternate color variants, and let users import custom skins via the Files app.
- Quick toggle: the Menu button shows or hides the on-screen controller manually.

### Integration (after the controls are built)
- Phase 5 app shell: host `TouchControllerView` and `ControllerSession`, and lay out the game view per the visibility rules.
- Core bridge: the emulation thread calls `gcpad_read(player)` (C ABI, lock-free) from the iOS input backend.

### Smart mapping mode
_Added 2026-10-11 at the user's request, as part of the controller work._

- **Detection on connect**, using GameController's `productCategory`, vendor name and available elements:
  - Families: Xbox, PlayStation (DualShock/DualSense), Switch Pro, Joy-Con (single and paired), Backbone/MFi, and a generic fallback.
  - A single Joy-Con is recognized by its missing second stick.
- **Smart defaults per family**, designed so GameCube games feel natural:
  - Left stick → main stick, right stick → C-stick, D-pad → D-pad.
  - Left/right triggers → L/R with full analog pressure where the controller supports it.
  - Right shoulder → Z; Start/Options/+ → Start; Menu/Home-area button → our app's Menu.
  - Face buttons laid out GameCube-style, with A as the main action button.
- **Two styles, selectable per controller:**
  - **By position** (default): south → A, west → B, east → X, north → Y, so muscle memory carries over.
  - **By label**: printed letters match (A → A, …). The letters are read at runtime from each element's GameController name and symbol, which handles Switch's swapped A/B and X/Y. Controllers without letters (PlayStation) fall back to By position, and the UI says so.
- **Connect toast**, e.g. "DualSense connected — Smart mapping: By position", with an Edit shortcut.
- **Controller extras:**
  - DualSense adaptive-trigger resistance on L/R that ramps toward the digital click point.
  - Rumble passthrough via `GCDeviceHaptics`, exposed as `setRumble(player:intensity:)` for the core.
  - Controller light set to the app theme (indigo).
- **Remembering choices:** editing a smart mapping saves it as that controller type's custom profile, used automatically next time. Per-game overrides still take priority. Resolution order: per-game override → family custom profile → smart default in the chosen style.
- **Multiplayer:** each connected controller gets its own smart mapping for its type (players 1–4).
- **Visual mapping screen:**
  - Our own schematic drawing of the detected controller type. These are generic outlines drawn in code, not traced product art or logos.
  - Each physical button is shown by the system's GameController glyph (`sfSymbolsName`) and labeled with its GameCube function.
  - Tap to remap; "Reset to smart defaults."
- **Fast path:** profiles compile to a flat `[GCTarget]` table indexed by element. The controller handler queue reads a fixed-size array snapshot, with no dictionaries or allocations per event.
