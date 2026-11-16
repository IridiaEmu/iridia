# Simulator test of 1.2 (Nov 13, 2026)

Branch release/1.2-wii, Debug build with normal settings, iPad Pro 13-inch (M5) and iPhone 18 Pro Simulators. No phone, no JIT, nothing pushed. Screenshots with game footage are in ~/Downloads/Iridia test/sim-test, not in the repo. The UI tests that drove this are in ~/Projects/iridia-uitest (`SimCheck`).

Frame rates in the Simulator say nothing about the phone.

## Results

| Area | Result |
|---|---|
| Super Mario Galaxy (iPad) | Boots to the title at 60 fps. A+B together starts it; touch drag aiming picks files and buttons. Made a new file, reached the courtyard, walked Mario with the stick. The game's own save stayed after a relaunch. Quick Save at the file screen, then Quick Load, restored it (60 fps after). One 9 fps reading about 40 s into boot. |
| Shake button | Pressed; the file screen has nothing that reacts to it, so the effect wasn't seen. |
| Layout button | Controls menu lists Wii Remote + Nunchuk, Wii Remote, Sideways, + Classic, GameCube. Switching to Wii Remote and back works. |
| Per-game layout | Edit Layout moved Shake; it stayed there after a relaunch; another game (Wii Input DOL) kept the default; Reset put it back. |
| Tabs (both) | The pill glides between GameCube, Wii and Wii U and back, Wii grey and Wii U blue in light, white and blue in dark. Headers crossfade. Reduce Motion: the pill fades in place, no slide. Reduce Transparency: the bar is solid. For about 0.15 s mid-glide the pill covers the icon it passes. |
| Import 7Z (iPhone) | Card "Unpacking big-disc.7z", percent and time left. Cancel: "Stopped unpacking", card gone, nothing added. Closing the app mid-unpack, then opening it: "Unpacking Stopped" says Iridia was closed; Try Again finished it ("went to the Wii tab"). |
| Import ZIP (iPhone) | Imports fine, but a 300 MB ZIP unpacks in under 2 s here, too fast to see or cancel the card. Cancel for ZIP is covered by the unit check `testCancelStopsUnpacking`. |
| Wii key file | Encrypted test disc (re-keyed to a self-made test key): a 500-byte file says "That isn't a Wii key file. A key file is exactly 1 KB." (a 4 GB file too, without reading it); a random 1 KB file says "That key file doesn't open this disc." and isn't kept; the test key is kept and the game starts. |
| GameCube regression | Twilight Princess boots to its health screen at 60 fps; the IridiaBench DOL runs at 50 fps. On a first launch the Welcome card never showed over either game (checked at 5, 15, 30, 45 s). |
| Wii U regression | Super Mario 3D World starts (Loading, the free play notice and the Screen layout tip, no Welcome card), then the app stops: the Simulator's Metal has no cube array textures ("Texture Cube Array is not supported on this device"). Known Simulator limit. |
| Controllers | No controller is connected to the Mac, so no button presses. The Controllers screen and Wii Remote 1's button list were checked for Wii Remote + Nunchuk (buttons, D-Pad, Nunchuk stick, C/Z, system buttons, pointer, swing, tilt, shake) and Wii Remote + Classic (face buttons, D-Pad, both sticks, ZL/ZR/L/R and the analog triggers). All 10 controller unit test classes pass (157 tests: remap capture, profiles, assignment, Plays as). |

## Fixed (committed locally)

- 918a298ca6: after a relaunch, the offer to unpack again says Iridia was closed, instead of reading like a failed unpack.
- 07b823d5b5: a wrong 1 KB key file was accepted and saved, and the game then ran on garbage. Now the key is kept only if it decrypts the disc's game partition header (the same check Dolphin's verifier uses). A hash check was tried first and rejected: it refused the right key on the homebrew test disc, whose hashes are invalid.
- 48169925f7, 633f171046 (earlier today): Cancel stops 7Z and xz; the unpack card sits above the tab bar on iPad.

## Found here, fixed later

1. **Plays as got stuck on Sideways** when GameCube port 1 was taken. Fixed in cd561d0d8c: a taken port is skipped on tap, and the Controllers screen says why.
2. **Keyboard on iPad with the Controls menu open during play.** Not a Simulator quirk. The play screen's event controller is Apple's GCEventViewController, which tells UIKit it needs a keyboard while it is first responder. Opening any menu reloads the input views, so the keyboard came up. Fixed in ce8ac5e689 with an empty input view on that controller; hardware keys still reach the game. `test48KeyboardRepro` now reports no keyboard at every step, and the screenshot shows none.

## First phone results (Nov 13, iPhone 16 Pro, 1.2.0 (18))

- Kirby about 60 fps past the title, Wind Waker HD 30 fps in the intro, both drawn right.
- The screen runs at 120 Hz; the idle home screen drops no frames.
- Switching tabs drops 5 to 11 frames (about 40 ms). The Simulator can't measure this one: it draws Liquid Glass on the CPU. To be measured with a Release build in the phone batch.
- Saves backed up to ~/Downloads/Iridia test/saves/2026-11-13 before installing.
- Problems seen there and fixed since: the 1.1.5 Downloads folder needed picking again (c8d58bb9c4: asked calmly, once), a player folder hidden by the update (29af4c2d56: brought back), added dates lost when Games became GameCube (1e9a25034f).

## Needs the phone (one batch)

Install the new Release build only once you're ready; nothing gets installed while you test.

- Tab switching at 120 Hz with `-frameMonitor`, and the pill drag over every tab.
- Imports from Files: a ZIP and a 7Z, Cancel partway, Try Again.
- The keyboard fix with the Controls menu during play.
- Mario Galaxy for 20 minutes (speed and heat).
- Mario 3D World and BotW start and play in 1.2.
- A real controller, if one is connected.
- The Wii U pause sheet's new look (the Simulator can't run Wii U games).

Earlier list:

- Real speed and heat (Mario Galaxy, Twilight Princess, Mario 3D World), and 120 Hz frame drops.
- Gyro aiming (the Simulator has no motion), and whether Shake does something in gameplay.
- A real controller: Wii Remote, Nunchuk and Classic mappings with button presses, and remapping (capture needs real input).
- The file picker steps: pick a ZIP and a 7Z in Files, see the card, Cancel partway, Try Again. Here the import was started with the `-importTest` launch option.
- The ZIP progress card on a large ZIP (too fast to see here).
- Wii U past the title screen (the Simulator can't).
- Wii key file prompt with your own key file and a real encrypted disc.
