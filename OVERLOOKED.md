# What might be overlooked before 1.2 (Nov 13)

Ranked by how much harm it could do if nobody looks at it. Small, clear items are already fixed (end of the file).
The ones marked **Your call** need an answer before release.

## 1. The real 1.1.5 to 1.2 update hasn't been tested. **Your call**

The phone's 1.2 is the development app (com.yl4f87nwp8.gcemu.iCube). It has its own data, apart from the App Store
Iridia (app.iridia). The three update bugs found today (hidden folder, lost added dates, Downloads folder) came from
the development app's own older data, so they were close, but not the real path. Only a build with the App Store
bundle ID, installed over 1.1.5, tests what players will get. That means a TestFlight build: TestFlight installs
over the App Store app and keeps its data.

Recommendation: after the phone batch, upload 1.2 to TestFlight (internal testing only, no review), install it over
your App Store 1.1.5, and check the shelves, saves, Downloads folder and Wii U games. This touches the App Store
app on your phone, so only with your OK. Saves are already backed up.

## 2. Japanese: 443 of 1,890 strings aren't translated. **Your call**

Everything new in 1.2 is English only in Japanese: the Wii tab, import and unpacking messages, the Downloads prompts,
the new GameCube Settings sheet, the key file prompt, the tar/bz2 message. A Japanese player gets a mix of the two
languages. Options: I translate them all (a draft that a native speaker should read before release), or ship as is.
I'd translate them.

## 3. App Review and the Wii key file. **Your call (only the review note)**

Encrypted Wii discs need the player's own key file, and the prompt says so ("Iridia needs the key file from your own
Wii"). That's as you decided; the app has no keys and doesn't say where to get them, and the keys check passes.
It's still the line a reviewer is most likely to ask about. Recommendation: a short App Review note ready to paste:
Iridia ships no system files or keys; players use dumps of their own discs and their own console's files; homebrew
(.dol, .elf, .wad) runs without anything extra. Say if you want me to write it into the 1.2 review notes in ASC.

## 4. The branch still carries the old screenshots. (Release checklist)

release/1.2-wii isn't on the cleaned main yet: 999af05f05 isn't in its history, so screens-shots/ (40 BotW and Kirby
gameplay shots) would go to GitHub with it. This is already on the checklist (move 1.2 onto main, then
`scripts/check_public_snapshot.sh --push`). Checked the 1.2 images: wii-shots/ and progress/wii/ show only the test
programs and app screens, no game footage.

## 5. Tab switch stall on the phone

5 to 11 dropped frames per switch at 120 Hz. The Simulator can't measure it (it draws Liquid Glass on the CPU).
Measured in the phone batch with the Release build and `-frameMonitor`.

## 6. Save states aren't in iCloud backups. **Your call**

Save states are kept out of iCloud and computer backups on purpose (`DolphinPaths.swift`). Restoring a phone or
moving to a new one loses them. In-game saves (memory cards, Wii saves) are in backups. Same as 1.1.5. Options:
leave it (states can be big), or back them up. I'd leave it and say so in Help ("Save states stay on this device").

## 7. Devices, memory and heat

- Minimum iOS 26 (iPhone 11 and later). Only the iPhone 16 Pro has run 1.2. Wii games on a 4 GB phone (iPhone 11,
  SE 2nd gen and later) are untested; Mario Galaxy may be slow there. The memory entitlements are in the App Store
  build.
- Heat: the 20-minute Mario Galaxy run is in the phone batch.
- Storage: Wii games are up to 4.7 GB each (8.5 GB dual layer), and unpacking needs room for both the archive and
  the game. The space check handles that and says how much to free.

## 8. Accessibility

- The on-screen game buttons have no VoiceOver labels (only the opacity slider does). Same as 1.1.5. Playing by
  VoiceOver isn't realistic, but Edit Layout could read "A button" and so on. Small change; say if you want it.
- Reduce Motion and Reduce Transparency are handled on the home screen (checked in the Simulator). The new close
  buttons are labelled "Close".

## 9. Purchases

One product (iridia.unlock.full) unlocks every system. 1.1.5 buyers get Wii with no new purchase; the unlock screen
says "Unlimited play time in every game", which fits. Wii games use the same 10-minute free play. The display name
change to "Unlock All Consoles" is on the release checklist.

## 10. Privacy label

No change needed. Nothing is collected: the Sentry calls are empty stubs, the privacy manifest lists only the
required-reason APIs (disk space, file dates, boot time, user defaults), the Downloads folder link stays on the
device, and the Wi-Fi features have a local network usage text. "Data Not Collected" stays right.

## 11. Release checklist items not done yet

All planned for just before the archive (as you asked, not started early): the rating prompt, the App Store
listing changes in ASC, new store screenshots, What's New. Checked now: the home screen name is "Iridia" in the
App Store build.

## Fixed now (small and clear)

| Commit | What |
|---|---|
| 2d3b077724 | The GameCube shelf's test launch options (`-iridiaAutoplay`, `-iridiaOpen` and others) were in App Store builds; the Wii and Wii U ones never were. Now left out the same way. |
| 2d3b077724 | Acknowledgements were missing four libraries the app ships: SWCompression, BitByteData, Zip and minizip. Added with their licences (MIT, MIT, MIT, zlib). |

Checked and fine: the "DSU" debug readout seen while playing is on only in Debug builds.
