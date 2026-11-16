# Update review: 1.1.5 (17) to 1.2.0 (19)

Code review only, Nov 15, 2026. Compared tag `v1.1.5` (999af05f05) with build 19 (77a514c6cd).
The tag and the build 17 commit (946c917bfb) hold the same code; they differ only by removed screenshots.
Nothing was built, run, uploaded or pushed. Paths are under `Source/iOS/App` unless they start with `Source/Core`.

## Verdict

**Safe to ship build 19 as is.** A normal update from 1.1.5 keeps every game, save, setting, layout and the
purchase. Nothing in 1.2 deletes or overwrites data that 1.1.5 wrote, and every one-time step can be cut off
and repeated without harm.

Nothing must be fixed first. Three things are worth knowing before release:

1. **Don't go back to App Store 1.1.5 on the test phone after installing build 19** (finding R1). 1.1.5 hides
   the new GameCube and Wii folders, and 1.2 won't bring them back afterwards. No data is deleted, but the
   games disappear from the shelf and Files until a fix or a manual move.
2. **Players who ran encrypted Wii discs in 1.1.5 need their key file in 1.2** (finding W1). 1.1.5 was never
   sold as playing Wii, but it could. Their saves are kept.
3. **One recommended fix for a build 20, about 10 lines** (finding F1): let the folder repair merge into
   folders that already exist, and run it for `GameCube` on every launch. It closes R1 and a gap in the repair.

## What a 1.1.5 player has, and where

| Data | Location | Changed in 1.2? |
|---|---|---|
| GameCube games | `Documents/Games` | Moved to `Documents/GameCube` at first launch |
| Wii U games, updates, DLC, keys.txt | `Documents/Wii U` | No |
| Dolphin user folder (config, memory cards, save states, covers, layouts, profiles) | `Library/Application Support/Iridia` | No |
| Wii save storage (NAND) | `Library/Application Support/Iridia/Wii` | No; `keys.bin` may be added here |
| Wii U save data | `Library/Application Support/IridiaCafe` | No |
| Preferences | UserDefaults, app group `group.app.iridia` | Keys added, none renamed or retyped |

Bundle ID, app group, entitlements, Info.plist and the `IridiaStore` package are identical in both versions.

## 1. Games: safe

- **Games folder move** (`Common/UserFolderUtil.swift:103-116`): at launch, before anything reads Dolphin's
  folders (`Common/AppDelegate.swift:14`), each item in `Documents/Games` is renamed into `Documents/GameCube`.
  - Subfolders move whole. A file that already exists at the destination is never overwritten.
  - A rename on the same disk is atomic per item. If the app is killed part-way, the next launch moves the rest.
  - The empty `Games` folder is removed only after the dates are moved, so a cut-off run repeats cleanly.
  - `GameImport.tidyFolders` repeats the move on every launch and return (`UserFolderUtil.swift:137-146`), so a
    `Games` folder a player recreates later is handled too.
- **Date added** (`Common/Swift/LibraryAddedDateStore.swift:33-43`): keys are relative
  (`Documents/Games/x`), and are rewritten to `Documents/GameCube/x`. A file's creation date, the fallback,
  survives a rename. Shelf order by last played is keyed by game ID (`LastPlayedStore`), unchanged.
- **Cover pictures** (`Common/UI/SoftwareList/TVGameItem.mm:292-300`): stored in the user folder under
  `Covers`, named by game ID, not by path. Unchanged.
- **Library scan** (`Common/UI/SoftwareList/GameFileCacheManager.mm:31-34`): reads the folder functions, not a
  saved path, and now scans GameCube and Wii. The game list cache is rebuilt.
- **Wii U games, updates and DLC**: `WiiUModel` paths are unchanged (`Common/Swift/WiiU/WiiUModel.swift:61-63`).
  The folder walk never goes inside a title folder (`Common/Swift/Import/WiiUFileTypes.swift:82`), so game
  data isn't touched.

Low-risk behaviour changes (no data loss):

- **G1. Stray games move without asking.** 1.1.5 asked before moving a Wii U game out of the GameCube folder
  and remembered "Not Now" (`wiiuStrayAsked`). 1.2 moves it (`Common/Swift/Import/GameImport.swift:356-372`)
  and ignores the old answer. New: a GameCube or Wii game in the Wii U folder moves to its own folder. A player
  sees the game on the right tab and a snackbar. An existing file of the same name is skipped, not replaced.
- **G2. Archives are tried once more.** The "already tried" list was renamed (`wiiuArchivesTried` to
  `archivesTried`, `GameImport.swift:385`), so an archive 1.1.5 gave up on is unpacked once more, then left.
- **G3. Archives are found by content, not name** (`GameImport.swift:70-77`). Any loose file in a game folder
  that starts like a ZIP, 7Z, gzip, bzip2, xz or tar is unpacked once into a scratch folder to look for
  games. It is deleted only if every game inside was added. A player may see an unpack card once.
- **G4. Platform overrides** (`LibraryPlatformOverrideStore`) are keyed by file path and aren't rewritten by
  the move. I didn't check whether Iridia's screens still expose this old iCube setting.

## 2. Saves: safe

- **GameCube memory cards, GCI folders, save states, resume states**: all under the user folder, by region or
  game ID. No code that reads or writes them changed (`SaveStateService.swift` changed one benchmark check).
- **Wii U saves**: `IridiaCafe` is outside the user folder, so the folder repair never looks at it.
- **Wii storage**: same NAND folder as 1.1.5. The key file screen writes only `Wii/keys.bin`, atomically, and
  puts the previous file back if the new one doesn't work (`Common/Swift/Wii/WiiScreens.swift:384-395`).
- **Console identity changed** (`Source/Core/Core/IOS/IOSC.cpp`): the built-in device ID and keys were
  replaced with made-up ones. Save files in the NAND are plain files and don't depend on them.

- **W1. Risky for some players: encrypted Wii discs stop booting until a key file is added.** 1.1.5 had the
  Wii common keys compiled in and showed Wii discs on its one shelf, so a player could run ISO, WBFS, GCZ and
  CISO Wii games (see `WII_PLAN.md`, "State in 1.1"). 1.2 removes the keys on purpose. Those games now appear
  on the Wii tab marked "Needs your key file". RVZ and WIA games keep working. Saves are kept.
  No code fix; decide whether to say so in the release notes or support page.
- **W2. Wii control defaults changed** for players who never set them: shake and tilt by device motion are off
  (`Common/Swift/Controllers/MotionSettings.swift`), the pointer follows the finger
  (`Source/Core/Core/Config/iOSSettings.cpp`), pointer speed is 1.25, and each Wii game starts as Wii Remote +
  Nunchuk until the player picks (`Common/Swift/Wii/WiiControls.swift:16-26`). Button mappings are kept.

## 3. Settings: safe

- **Control layouts** (`DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayLayoutStore.swift:149-169`): same file
  and format. Per-game layouts are extra keys (`game.<id>.<kind>.<orientation>`) in the same dictionary. With no
  per-game entry the shared layout is read, and the first edit in a game starts from a copy of the shared one.
- **Global and per-game settings, controller mappings, game profiles**: no changes to how they're stored.
- **Wii U screen layouts and options**: same `cafe*` keys and defaults.
- **Resolution**: no stored-setting change.
- **Custom textures** (`Source/Core/Core/Config/GraphicsSettings.cpp`, `Common/Services/DolphinCoreService.mm:53-82`):
  the built-in default went from on to off. At each launch, if `Load/Textures` holds a folder and the player
  never set the option, it is turned on. "Existing player with a pack" is detected by the folder, not by a
  version flag, so it also covers a pack added later (after a relaunch). A player who turned it off stays off.
- **UserDefaults**: added keys only (`restoredPlayerFolders`, `downloadsFolderAskedAgain`, `archivesTried`,
  `wiiDownloadsAsked`, `iridia_wii_controls`, `iridia_wii_controls_default`, `wii_show_pointer`). No key
  changed type. Two were retired (G1, G2). Test-hook keys are compiled out of App Store builds.

## 4. Files and access: safe, with one gap

- **Downloads bookmark** (`Common/Swift/Import/DownloadsFolder.swift:14,51-57,66-82`): same key and same kind of
  bookmark. If iOS has dropped access, 1.2 asks for the folder once instead of once per launch.
  A Wii game in Downloads that a player declined under the GameCube check is offered once more by the Wii tab.
- **Files opened from the Files app**: now asks Copy or Move; no stored data involved.
- **Container path**: stored paths are relative, or rebuilt from the folder functions.
- **Folder hiding** (`UserFolderUtil.swift:93-116`): 1.2 moves only Dolphin's and Iridia's own folder names out
  of Documents. I checked the list against Dolphin's folder names and the Simulator installs on this Mac: every folder the
  app creates is on it, so nothing of the app's is pushed into Documents by mistake.
- **F1. Gap in the repair** (`UserFolderUtil.swift:120-134`): 1.1.5 hid every folder a player made in
  Documents. 1.2 puts them back once, except when a folder of that name already exists in Documents
  (line 131) and except `Wii` (line 125). So a player who made a folder called `GameCube` or `Wii` in 1.1.5,
  the two most likely names, doesn't get it back: 1.2 has just created folders with those names.
  Their games were already hidden by 1.1.5, so this isn't new damage, but the repair misses them.
  **Smallest fix:** at line 131, when both are folders, merge with the existing `merge()` instead of skipping;
  for `Wii`, move only game and archive files from the top of the hidden `Wii` folder into `Documents/Wii`;
  and run the `GameCube` merge on every launch instead of behind the one-time flag.

## 5. Purchases: safe

- No change to the store code, product ID, bundle ID or app group, so the unlock, Restore and Family Sharing
  behave as in 1.1.5.
- Trial timers: same limits (10 minutes GameCube and Wii, 20 minutes Wii U) and nothing is persisted between
  sessions, so nothing can reset or lock out. A paying player never starts a timer
  (`Common/Swift/Iridia/IridiaUnlock.swift:52`).
- The launch option that skipped the timer is now compiled out of App Store builds
  (`Common/Swift/GCEmu/GCEmuBenchmark.swift:113-119`).

## 6. First-launch flows: safe

- **Welcome card**: same "seen" key, so an existing player doesn't see it again. It now waits for the GameCube
  home screen.
- **Folder repair**: runs once behind `restoredPlayerFolders` (`UserFolderUtil.swift:85-89`). It only moves
  items and never overwrites. If it's cut off before the flag is saved, it runs again and skips what's done.
- **Folder tidying and Downloads checks**: don't run while a game is playing, never overwrite, and ask before
  adding from Downloads.
- **Interrupted unpack**: leftovers are removed and the archive is offered again; the archive itself is kept.
- Nothing blocks the shelf: the moves are renames, and tidying runs in the background.

## 7. Rollback to 1.1.5: one-way in one respect

- **R1. Risky: games vanish if 1.1.5 runs after 1.2.** 1.1.5 treats every folder in Documents except `Games`,
  `Wii U` and `Inbox` as its own and moves it into the hidden user folder (v1.1.5 `UserFolderUtil.swift:69-76`).
  So `Documents/GameCube` is hidden, and `Documents/Wii` is merged into the Wii save storage folder. The shelf
  is empty. Updating to 1.2 again doesn't undo it: the repair already ran, and it skips those two names (F1).
  Nothing is deleted. This can't happen from the App Store, which never downgrades, but it can on a phone that
  swaps a TestFlight build for the App Store version. The F1 fix closes it.
- Everything else reads back fine in 1.1.5: extra layout keys and new preferences are ignored and kept,
  memory cards, save states and Wii U saves are untouched, and a `keys.bin` is simply used.
- Minor: date-added records are now under `Documents/GameCube`, so after a rollback 1.1.5 falls back to file
  dates.

## 8. Anything else that changes stored data

- `Wii/keys.bin` is new, written only when the player picks a key file.
- AppleDouble (`._*`) and `.DS_Store` files are now also removed from the Wii folder, as they were from Games.
- Nothing else found.

## Not covered

- This is a reading of the code. The real update (App Store 1.1.5, then TestFlight build 19) still needs to
  be run once on the phone.
- The Wii U core is a prebuilt framework and isn't in the diff. Its data folder and the app code that
  drives it are unchanged.

## Follow-up: fixed in build 20

F1 and R1 are fixed. `UserFolderUtil.restoreGameFolders` runs at every launch:
- A hidden `GameCube` folder is merged into `Documents/GameCube`, folder by folder.
- Game and archive files at the top of the Wii save storage folder move into `Documents/Wii`. The save storage,
  `keys.bin` and anything that isn't a game stay where they are.
- Nothing is overwritten: a file whose name is taken is kept next to the existing one as "Name 2.ext".

Tests: `GameImportTests.testHiddenGameCubeFolderJoinsTheGameCubeFolder` and
`testGamesHiddenInWiiStorageJoinTheWiiFolder`.
