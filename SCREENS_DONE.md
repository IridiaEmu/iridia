# Wii U screens: done

Branch `release/wiiu-update`, local commits only (nothing pushed). Plan: `SCREENS_PLAN.md`.
No JIT, no Nintendo logos or copied Nintendo UI (the layout icons are plain drawn rectangles).
GameCube side unchanged: every changed file is under `Source/iOS/App/Common/Swift/WiiU/`, the Cemu core
(`Externals/Cemu/src`), or the new `WiiULayoutTests.swift`.

## What you get

Four layouts, remembered per game:

| Layout | What it shows |
|---|---|
| TV only (default) | TV picture |
| TV + GamePad | TV picture with the GamePad in a small window: drag to any corner, resize, hide (a small button brings it back). Tapping the small window enlarges it, it shrinks back after 4 s without touches |
| GamePad full screen | GamePad picture; the TV can be shown in a small window. On-screen buttons: normal, small at the edges, or hidden, plus a visibility slider; they hide by themselves while a game controller is used |
| Split | TV on top, GamePad below. Offered on iPad (both orientations) and iPhone portrait. On iPhone landscape it falls back to TV + GamePad with a short label saying so |

- **Swap screens** in every layout (the core draws the TV picture into the second view, so it costs nothing extra).
- Pictures always keep their shape (TV 16:9, GamePad 854x480), letterboxed, never stretched.
  Everything stays clear of the Dynamic Island, notch and home indicator.
- **Layout button** (44 pt, see-through, top corner beside the island): tap cycles TV only, TV + GamePad,
  GamePad full screen, Split; long press opens the menu with the four layout pictures, Swap screens, on-screen
  button options, Motion controls and Recenter. A label shows the new layout for 1 s, with a haptic tap.
- The same options are in the **pause menu** and in **each game's settings** on the Wii U tab (a settings button
  next to Play, or long press the game). Settings also has "Layout for new games" and "Show the layout button".
- **Controller shortcut**: hold Menu (+) and press L for the next layout, R to swap screens. Shown in the pause
  menu and the layout menu. A quick Menu press still reaches the game.
- **One-time tip** pointing at the layout button.
- **VoiceOver**: "Screen layout, currently TV only", with actions for the next layout, "Show all layouts" and "Swap screens". Menus switch to two
  columns at large text sizes and scroll when they don't fit.
- **Motion controls** (on by default, in the menu and settings): phone gyro and accelerometer go to the
  GamePad through Cemu's own sensor fusion; Recenter in both menus.
- Landscape on-screen buttons: - and + sit at the top centre, away from the face buttons (your request).
- MFi, Xbox and PlayStation controller mapping is unchanged.

GamePad touch: UIKit view on the GamePad picture, first finger only, press / drag / release, coalesced touches
(every 120 Hz sample), precise location (Apple Pencil works as the stylus). The touch is written straight into
the value the game reads on its next GamePad poll, so latency is one game frame at most. Touches outside the
GamePad picture go to the on-screen controls, never to the GamePad touchscreen.

## Screenshots

In `screens-shots/` (iPhone 18 Pro and iPad Pro 13" Simulators, latest build). Names are
`<device>-<orientation>-<state>.jpg`:

- `tvOnly`, `pip`, `pip-swap`, `gamePad`, `split`, `split-swap` (no Split on iPhone landscape: it falls back)
- `menu` (long-press menu), `tip`, `label` (the 1 s label after a change), `pause` (pause menu)
- `mac-kirby-gamepad-full.jpg`: Kirby and the Rainbow Curse in GamePad full screen on the Mac study build
- `mac-botw-gamepad-full.jpg`: BotW's GamePad picture full screen on the Mac study build

Note: in the Simulator BotW only gets to its first screen and its **TV picture stays black** there, in every
layout including TV only and with the previous build too, so the TV area looks empty in the shots. The
GamePad picture shows everywhere it should, swapped or not. On the Mac study build BotW's TV picture draws
normally in all layouts (the cost runs below take TV screenshots, all clean).

## Tests

| Test | Result |
|---|---|
| Unit tests (`WiiULayoutTests`, 9 tests: aspect, safe areas, top bar and buttons clear of the GamePad, which picture goes where, touch mapping, cycle order, corners, per-game prefs, shortcut) | 9/9 pass |
| Touch mapping, iPad (4 corners + centre, every layout, swap on/off, portrait and landscape, real UIKit hit testing, value read back from the game) | 58 taps, worst 0.20 px off, 0 routing failures, 0 taps the game missed |
| Touch mapping, iPhone, same | 55 taps, worst 0.21 px off, 0 routing failures, 0 taps the game missed (points under the small window are checked to go to the window instead) |
| Small window: a tap enlarges it and sends no touch to the game | Pass on both (iPad 344x193 pt window enlarges to 1211x681, iPhone 219x123 to 552x310; the game read no touch) |
| Drawing (BotW, GamePad full screen: a line drawn at 120 Hz, every point the game read recorded) | iPad: 30 new points in 0.96 s, iPhone: 31 in 1.00 s. A new point on every game poll: every 33.3 ms on average, longest gap 33.8 ms (BotW runs at 30 fps and reads the GamePad once a frame), 0 steps backwards. Kirby runs at 60 fps, so it should get a point every 16.7 ms; to confirm on a device |
| Layout button, long press menu, pause menu, shortcut each switch layouts; choice kept after relaunch | Layout button, menu, pause menu and prefs per game covered by the tour and unit tests; the shortcut by its unit tests (no controller in the Simulator). Relaunch: prefs are saved per game title ID and read back on launch (unit test `testPrefsSavedPerGameWithDefaults`) |
| Kirby boots | Mac study build: yes, 60 fps, title screen in GamePad full screen (`mac-kirby-gamepad-full.jpg`). iOS Simulator: the Simulator's Metal driver aborts while allocating a drawable after ~1 s, in TV only too, so it isn't the layouts. Needs the phone or iPad |
| Kirby line drawing | Not run: needs a device (Simulator crash above). The test is built in: `-wiiuAutoplay Kirby -wiiuDrawTest 30` |
| BotW TV only and TV + GamePad | Work (screenshots). Tapping the GamePad map/inventory needs gameplay, which the Simulator doesn't reach. Left for the phone check |
| GameCube | No GameCube files changed |
| No JIT | Mac study build: static + runtime check PASS on all 10 cost runs |

## Cost of each layout (Mac study build, BotW, 2 interleaved rounds of 60 s)

Same window and settings for each (`IRIDIA_GPU_QOS=utility`, native resolution). The second picture is a
second Metal view the core already supports, so the game renders exactly as before; only the final copy to
the screen is done twice.

| Layout | fps | GPU busy | P-core instructions / frame | P-core cycles / frame | Energy / frame |
|---|---|---|---|---|---|
| TV only | 22.5 | 54% | 593.3 M | 241.1 M | 374 mJ |
| GamePad full screen | 22.9 | 55% | 587.5 M | 238.5 M | 379 mJ |
| TV + GamePad (427x240 window) | 22.5 | 55% | 589.0 M | 240.4 M | 376 mJ |
| TV + GamePad, swapped | 22.5 | 55% | 593.3 M | 242.5 M | 387 mJ |
| Split (854x480 second view) | 23.0 | 55% | 592.9 M | 241.1 M | 375 mJ |

All within noise: the two TV-only rounds alone differ by 0.4% in instructions and 4.5% in energy. No layout
costs measurable fps, CPU or GPU on the Mac. **Phone check still to do**: repeat TV only vs TV + GamePad vs
Split on the iPhone (the phone is heat-bound, so watch fps and temperature over a few minutes).

## Decisions for you (I went with the first option)

1. **iPhone landscape GamePad full screen is 587x330 pt instead of the full 715x402**, so the layout and
   pause buttons never sit on the picture (touches there would hit the buttons instead of the GamePad).
   Alternative: full size with the buttons over the picture's top corners.
2. **Kirby starts in GamePad full screen**; every other game in TV only (the list is `gamePadFirstTitles`).
3. **Shortcut Menu + L / Menu + R.** Alternative: Menu + ZL / ZR.
4. **Split on iPhone landscape falls back to TV + GamePad** (two pictures side by side would each be tiny).
5. Motion controls on by default.
6. The Simulator can't rotate an iPad app in windowed mode, so the iPad tests use a test-only copy of the app
   marked full screen. The shipping app is unchanged.

## How to rerun

- Unit tests: `xcodebuild test ... -only-testing:iCubeTests/WiiULayoutTests`
- In the app (non-App Store builds), launch arguments: `-wiiuTouchTest 20`, `-wiiuDrawTest 20`,
  `-wiiuLayoutTour 20`, with `-wiiuAutoplay <game name>`.
- Screenshot tour: `WiiU/tools/sim_screens.sh <udid> <prefix> <out dir> <game name>` (study tree).
- Mac cost: `WiiU/tools/screens_cost.sh 2 60` (study tree; uses `IRIDIA_PAD_WINDOW=WxH` and
  `IRIDIA_PAD_SHOWS_TV=1`).
