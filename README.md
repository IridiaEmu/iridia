# Iridia: GameCube, Wii and Wii U emulator for iPhone and iPad

**[Download on the App Store](https://apps.apple.com/app/iridia/id6825803351)** ·
[Website](https://iridiaemu.github.io/iridia/) · [Support](https://iridiaemu.github.io/iridia/support/)

Iridia plays your own GameCube, Wii and Wii U games on iPhone and iPad. It is built for the App Store
**without JIT**: GameCube and Wii run on Dolphin's Cached Interpreter, heavily tuned for Apple silicon, and
Wii U (experimental) runs on Cemu's interpreter.

Iridia is free software under the **GNU General Public License v2.0 or later** (see `COPYING` and
`LICENSES/`). It is based on:

- [Dolphin](https://dolphin-emu.org): the GameCube/Wii emulator its core comes from (GPL-2.0-or-later)
- [Cemu](https://cemu.info): the Wii U emulator its Wii U core comes from (MPL-2.0)
- [DolphiniOS](https://dolphinios.oatmealdome.me): OatmealDome's iOS port (GPL-2.0-or-later)
- [iCube](https://github.com/Provenance-Emu/iCube): the DolphiniOS fork Iridia started from (GPL-2.0-or-later)

Iridia includes no games, keys, BIOS or firmware. GameCube, Wii and Wii U are Nintendo trademarks; Iridia is
not affiliated with or endorsed by Nintendo, the Dolphin Team or the Cemu project.

## What's different from iCube
- No JIT anywhere. GameCube and Wii, plus experimental Wii U from Cemu.
- Performance work measured on device: see `BENCHMARKS.md` and `PERFORMANCE_EVAL.md`.
- New iOS app shell: the "Glass Shelf" library, glass pause sheet, our own touch controls and
  controller mapping (`Packages/GCControls`), a real 3D glass-cube logo (`Common/Swift/Branding`).
- No telemetry (iCube's Sentry reporting removed).

## Building
See `BUILDING.md` (Xcode 27, Tuist, the core xcframework, and on-device signing).

## Project docs
`PLAN.md` (phases), `PROGRESS.md` (log), `STATUS.md`, `RESEARCH.md`, `ASSETS.md` (where our art comes
from), `Store/` (App Store paperwork). Dolphin's and DolphiniOS's original readmes are in `docs/`.
