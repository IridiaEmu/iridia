# App Review notes (paste into App Store Connect → App Review Information → Notes)

Iridia is an emulator for GameCube software (Guideline 4.7). It does not include, download or link
to any games, BIOS/firmware or encryption keys. Players add their own legally obtained game files
(their own disc backups or homebrew) through the Files app or the in-app Import button.

**How to test**
- The app opens to an empty library. To try it, add a homebrew GameCube program (.dol), e.g. from
  devkitPro's open-source examples, or your own disc backup (.iso/.rvz) via Import → Browse.
- Tap a game, then Play. Tap ☰ (bottom of the controller) for the pause menu.

**In-App Purchase: "Unlock Full Version" (non-consumable)**
- Iridia is free. Each game launch is a free play session of 10 minutes of actual play; sessions
  repeat without limit and never expire, so this is a limited free version, not a time-based trial.
- The limit is stated before play (a notice at the start of each session and on the unlock screen),
  with a warning 1 minute before the session ends.
- When a session ends the game pauses, the player's progress is saved, and the unlock screen
  appears with the price, what the purchase adds, Restore Purchases, and "Not now".
- To review the purchase without playing 10 minutes: tap **Unlock** at the top of the library.
- Restore Purchases is on the unlock screen.

**No JIT / no executable memory**
- The CPU is emulated with an interpreter only. The app requests no JIT or dynamic-code-signing
  entitlements and never maps executable memory.

**Network use** (no account, no analytics, no tracking)
- Optional cover art from GameTDB (the game's ID is sent to look up the image).
- Optional remote game sources the player adds themselves (WebDAV servers, often plain HTTP on a home
  network; this is why the app allows non-HTTPS loads).
- Optional Wi-Fi upload from the player's computer, and handing a game to the player's other devices
  (local network, Bonjour).

**Entitlements**
- Increased Memory Limit: some games use ~1.4 GB at higher internal resolutions.
- Extended Virtual Addressing: the emulated console's memory map is reserved as data (not executable).

**Open source**
- Iridia is free software under the GNU GPL v2 (or later), based on Dolphin, DolphiniOS and iCube.
  Source: [SOURCE REPOSITORY URL]. Licences and credits: Settings → About → Acknowledgements.

Contact: [YOUR NAME], [YOUR EMAIL], [YOUR PHONE]
