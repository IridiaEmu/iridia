# Wii U screens: plan

Branch `release/wiiu-update`, built on top of the finished Wii U update work. Nothing pushed; `main`, the App Review
build and the public source repo untouched. No JIT. No Nintendo logos, icons or copied Nintendo UI: the layout icons
are plain rounded rectangles drawn in SwiftUI, the rest is SF Symbols and the system font.

## 1. What the core already does (no rendering change needed)

- The core draws the TV image into the main Metal layer and, when a second layer is attached
  (`CemuBridge.setGamePadLayer`), the GamePad image into that layer. `setGamePadOnMainScreen` makes the main layer
  show the GamePad image instead of the TV.
- Each image is drawn aspect-fit and centred in its layer (`LatteRenderTarget_getScreenImageArea`).
- Touch: `setTouchDown(x, y)` with 0..1 on the GamePad image, turned into the GamePad panel's raw values in
  `vpad.cpp` (the same mapping as Cemu's emulated GamePad). Motion fields (acc, gyro, orientation, attitude) are not
  filled for the app's pad yet.

The only core changes are about what is shown where, never how the game renders:
1. `setPadLayerShowsTV:` so the second layer can show the TV image (needed for "Swap screens": GamePad big, TV small).
   One flag next to `isDRCPrimary` in `LatteRenderTarget_copyToBackbuffer`; default off (today's behaviour).
2. `setMotionGyro:acc:dt:` and `recenterMotion`: feed device motion into Cemu's own `WiiUMotionHandler` (Mahony
   filter, already in the tree) and fill the motion fields in the app pad's `VPADRead` like Cemu's
   `VPADController::update_motion`.
3. A switch between the layouts while the game runs, without restarting it: the main layer's TV/GamePad choice
   is already live (`isDRCPrimary`); the second layer is attached, resized and detached at run time.

## 2. Layout modes (remembered per game)

Stored per title ID in UserDefaults (`cafeLayout.<titleId>` = mode, `cafeSwap.<titleId>`, PiP corner and size).
A game with no saved choice starts in TV only, except Kirby and the Rainbow Curse (title ID 00050000101ABC00, the copy in Downloads; other
regions' IDs only once checked), which starts in GamePad full screen. The old global "GamePad screen" setting becomes
the default for games that have no choice saved yet (Off -> TV only, Instead of TV -> GamePad full screen, Small
window -> TV + GamePad).

| Mode | Big screen | Small screen |
|---|---|---|
| TV only | TV, fills the screen (aspect-fit 16:9) | none (second layer detached: no cost) |
| TV + GamePad | TV | GamePad window: drag to any corner (snaps), pinch or corner handle to resize (20-50% of the width), tap the small hide tab to hide/show |
| GamePad full screen | GamePad, fills the screen (aspect-fit 854:480) | TV as a small window, or hidden (option) |
| Split | top half TV, bottom half GamePad, both as large as fits | - |

- Swap screens exchanges big and small in TV + GamePad and GamePad full screen, and top and bottom in Split.
- Split is offered on iPad (both orientations) and on iPhone in portrait. On iPhone in landscape, Split shows as
  TV + GamePad (and the label says so) until the phone is turned upright; the saved choice stays Split.
- Every screen is fitted to its own aspect ratio in SwiftUI and the Metal view is given exactly that size, so the
  core's own letterboxing is a no-op and the black bars are the background. That keeps touch mapping exact: a touch
  is `(location - viewOrigin) / viewSize`.
- Safe areas: big screens are fitted inside the safe area horizontally in landscape (Dynamic Island / notch side)
  and vertically in portrait; the home indicator area is kept free of the PiP window and the layout button. The
  black background still fills the whole display.
- Portrait iPhone, TV only and the GamePad modes: picture at the top as today, touch controls below.

## 3. Reaching it

- Layout button: top-left (the pause button is top-right), 44 x 44 pt hit area, semi-transparent rounded square with a
  small two-rectangles glyph. Inside the safe area, outside every GamePad image (if the GamePad image would be under
  it, the button moves to the free side). Tap cycles TV only -> TV + GamePad -> GamePad full screen -> Split (Split
  skipped where it isn't offered). Long press opens a small menu: 4 picture icons of the modes, Swap screens, and
  on-screen button options (opacity, hide in GamePad full screen, move to the edges).
- On every change: a short label ("GamePad full screen") for 1 s, a light haptic tap, and a VoiceOver announcement.
- Pause menu: a "Screens" section with the same 4 icons, Swap screens, and the controller shortcut written out.
- Wii U tab: each game gets a settings sheet (long-press / context menu on its case, "Game settings") with the
  layout, swap, and gyro on/off. The global Settings keep the default layout for new games and the
  "Show layout button" toggle.
- Controller shortcut: hold Menu (the +/Start button) and press L1 to step to the next layout, R1 to swap screens.
  While Menu is held with L1/R1, those presses are not sent to the game (only + alone is). Written out in the pause
  menu.
- One-time tip: the first time any Wii U game is opened, a small card points at the layout button ("Tap to change how
  the TV and GamePad screens are shown. Hold for all options."), dismissed by a tap; `cafeLayoutTipShown` stops it
  coming back.
- Accessibility: VoiceOver labels and values ("Screen layout, currently TV only", hint "Double-tap to change, or hold
  for more options"); the menus use Dynamic Type text and scroll at large sizes; the haptic follows the existing
  button-vibration setting.
- The layout button can be hidden in Settings; the pause menu and the controller shortcut always keep working.

## 4. GamePad touch

- A UIKit view (not a SwiftUI DragGesture) over every GamePad image: `touchesBegan/Moved/Ended/Cancelled`, the first
  touch only (others ignored until it lifts), `coalescedTouches` for the in-between points, and predicted touches not
  used (they would put points where the finger never went). Every point goes straight to the core's atomics (no
  timer), so the game sees the newest point at each GamePad read (the game reads it every frame; the core keeps the
  last point, so nothing is dropped between frames).
- Each touch is clamped to the image: a drag that slides off the image edge stays at the edge (like a finger at
  the edge of the real screen) instead of lifting.
- Apple Pencil: the same view gets Pencil touches (`.pencil` type) as the stylus; Pencil hover is not used.
- Touches outside the GamePad image fall through to the on-screen controls (the touch view only covers the image).
- On-screen controls in GamePad full screen: opacity slider, "Move to the edges" (sides of the screen, outside the
  GamePad image where there is room), "Hide in GamePad full screen" and the existing hide-while-a-controller-is-used.
  While a controller is used they hide automatically in every mode, as today.
- Small PiP: a tap on the window when it is under 40% of the screen width expands it to a large centred view
  (touch goes to the game there), with a shrink button; it shrinks back after 4 s without a touch or on the button.
  The first tap only expands (not sent to the game), so a touch never lands somewhere the user can't see well.

## 5. Gyro

- Core Motion device motion at 100 Hz on a background queue, rotated from the device frame to the GamePad frame for
  the current interface orientation (landscape left/right, portrait), sent to the core.
- Setting "Motion controls" (per game, default on) and a Recenter button in the pause menu (and long-press menu).
- Off: no Core Motion at all (battery).

## 6. Controllers

Unchanged mapping (MFi, Xbox, PlayStation through GameController). The shortcut in 3 is the only addition.

## 7. Cost

The app can't run on the Mac ("Designed for iPad" stops at launch) and the Simulator can't play BotW, so the cost is
measured with the Mac study build (`~/Projects/gc-emu-wiiu/WiiU`), which uses the same Metal renderer and the same
present code. BotW replay as in the study (IRIDIA_GPU_QOS=utility, windows transparent in the background, also the
GamePad window), COUNTERS=1, interleaved rounds, for the layouts that cost something different:
- one picture (TV only; GamePad full screen with the TV hidden),
- two pictures (TV + GamePad, Split, either way round with Swap).
Reported: fps, P-core instructions and cycles per frame (as in the study's judging rule), and GPU time per frame.
The second picture is one extra quad and one extra drawable present per frame, so a small cost is expected. Phone
check noted for later.

## 8. Tests

- Touch mapping: a unit test of the mapping function for every mode, swap and orientation on iPhone and iPad
  sizes (corners and centre -> expected 854 x 480 point within 1 px), plus a test hook that taps the four corners
  and the centre in the Simulator and reads back the raw panel values the core reports (IRIDIA_INPUT touch lines).
- Kirby and the Rainbow Curse (in Downloads, NUS format): boots, GamePad full screen, drawing a line with a
  scripted drag (smooth: every coalesced point reaches the core, no gaps over 1 frame), touch lands where tapped.
- BotW: TV only and TV + GamePad, the GamePad map screen tapped.
- Layout button, long press, pause menu and controller shortcut (Simulator controller injection) switch modes; the
  choice survives a relaunch.
- GameCube regression: the GameCube files are not touched; build and the existing GameCube UI tests.
- No-JIT checks on every build.

## 9. Owner decisions (I go with the first option)

1. Kirby starts in GamePad full screen by default; every other game in TV only.
2. Controller shortcut: Menu + L1 next layout, Menu + R1 swap.
3. Split on iPhone landscape falls back to TV + GamePad.
