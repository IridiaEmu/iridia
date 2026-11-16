# Drafts for 1.2: App Review notes and update notes

Drafts for the Wii update (1.2.0, build 16). Nothing here has been sent anywhere. The 1.1 drafts
stay in UPDATE_NOTES.md.

## App Review notes (App Store Connect, "Notes" for the reviewer)

```
This update adds Wii support next to the existing GameCube and Wii U support.

The app contains no games, no console keys, no system files and no firmware, and
it does not link to any. Players use their own game files, which they copy into
the app's folder with the Files app (On My iPhone > Iridia > Wii). Wii games play
as RVZ, WIA, ISO, WBFS, GCZ or CISO files. ISO, WBFS, GCZ and CISO files need the
player's own key file, which they choose once; the app includes none. All emulation
runs as an interpreter: the app does not generate or execute code at runtime (no
JIT). Online features are turned off: the emulated Wii has no network access.

How to see the Wii section and the purchase without a game:
1. Open the app. On the library screen (the shelf, also when it is empty), tap
   "Wii" in the bottom tab bar.
2. The Wii screen opens with its own shelf. Tap "Unlock" at the top right to open
   the purchase screen (Unlock Full Version, Restore Purchases).
3. The same purchase options are in the Wii section's Settings (bottom tab bar) >
   Full Version.
4. Tap "GameCube" or "Wii U" in the bottom tab bar to go to the other sections.

Purchase: the existing one-time In-App Purchase "Unlock Full Version"
(iridia.unlock.full) now covers GameCube, Wii and Wii U. Without it, each Wii game
plays in free play sessions of 10 minutes, the same as GameCube (Wii U stays at 20
minutes); the sessions repeat without limit. When a session ends, the game pauses
and the purchase screen appears.

Real Wii Remotes can't be connected (iOS does not give apps access to them). Wii
games are played with on-screen controls or a supported game controller.
```

## Update notes ("What's New in This Version")

```
Wii support

- A new Wii section with its own shelf, next to GameCube and Wii U. Tap Wii in
  the tab bar.
- Add your own Wii games with the Files app: On My iPhone > Iridia > Wii. Wii
  games play as RVZ, WIA, ISO, WBFS, GCZ or CISO files. ISO, WBFS, GCZ and CISO
  files need the key file from your own Wii, added once.
- On-screen Wii Remote, with Nunchuk, Classic Controller, sideways and GameCube
  controller layouts. Switch any time with the controls button or the pause
  menu; each game remembers its choice.
- Aim by dragging on the screen, by following your finger, or by pointing the
  phone. Shake with a button, or by shaking the phone if you turn it on.
- Game controllers work too: the left stick is the Nunchuk, the right stick
  aims.
- Your Unlock Full Version purchase covers Wii too. Without it, Wii games play in
  free sessions of 10 minutes.

Iridia includes no games, keys, system files or firmware. Online features are
not available.
```

Promotional text (optional, 170 characters max):

```
Now with Wii support, next to your GameCube and Wii U libraries. Bring your own games.
```

## Description changes (App Store listing)

The listing currently names GameCube and Wii U. For 1.2, add Wii wherever both are named
("GameCube, Wii and Wii U") and add one feature line:

```
- Wii: on-screen Wii Remote with Nunchuk and Classic Controller layouts, pointer
  by touch or by pointing your device, and game controller support.
```

The seizure warning stays as it is.
