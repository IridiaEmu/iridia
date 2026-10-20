# Iridia

Iridia is a GameCube emulator for iPhone and iPad, built for the App Store **without JIT**: the
PowerPC CPU runs on Dolphin's Cached Interpreter, heavily tuned for Apple silicon.

Iridia is free software under the **GNU General Public License v2.0 or later** (see `COPYING` and
`LICENSES/`). It is based on:

- [Dolphin](https://dolphin-emu.org): the GameCube/Wii emulator its core comes from (GPL-2.0-or-later)
- [DolphiniOS](https://dolphinios.oatmealdome.me): OatmealDome's iOS port (GPL-2.0-or-later)
- [iCube](https://github.com/Provenance-Emu/iCube): the DolphiniOS fork Iridia started from (GPL-2.0-or-later)

Iridia includes no games, BIOS, firmware or keys. GameCube is a trademark of Nintendo; Iridia is not
affiliated with or endorsed by Nintendo or the Dolphin Team.

## What's different from iCube
- No JIT anywhere, GameCube only.
- Performance work measured on device: see `BENCHMARKS.md` and `PERFORMANCE_EVAL.md`.
- New iOS app shell: the "Glass Shelf" library, glass pause sheet, our own touch controls and
  controller mapping (`Packages/GCControls`), a real 3D glass-cube logo (`Common/Swift/Branding`).
- No telemetry (iCube's Sentry reporting removed).

## Building
See `BUILDING.md` (Xcode 27, Tuist, the core xcframework, and on-device signing).

## Project docs
`PLAN.md` (phases), `PROGRESS.md` (log), `STATUS.md`, `RESEARCH.md`, `ASSETS.md` (where our art comes
from), `Store/` (App Store paperwork). Dolphin's and DolphiniOS's original readmes are in `docs/`.
