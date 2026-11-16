// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

@objc class UserFolderUtil: NSObject {
  /// Dolphin's user folder (config, saves, caches, logs). gc-emu: on iOS this lives in
  /// Library/Application Support/Iridia, which the Files app never shows, so Files only lists
  /// the game folders (see getSoftwareFolder). Computed once.
  @objc static func getUserFolder() -> String {
    userFolder
  }

  /// Where GameCube games go. gc-emu: on iOS this is Documents/GameCube, shown in the Files app under
  /// "On My iPhone > Iridia" next to Wii and Wii U, so it's obvious where to put a game file.
  @objc static func getSoftwareFolder() -> String {
    softwareFolder
  }

  private static let userFolder: String = {
    #if NONJAILBROKEN || TROLLSTORE || APPSTORE
    #if os(tvOS)
    return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    #else // !tvOS
    let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
    let dir = base.stringByAppendingPathComponent("Iridia")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
    #endif
    #else
    return "/private/var/mobile/Documents/iCube"
    #endif
  }()

  private static let softwareFolder: String = {
    #if (NONJAILBROKEN || TROLLSTORE || APPSTORE) && os(iOS)
    let dir = documentsFolder.stringByAppendingPathComponent(gamesFolderName)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
    #else
    return userFolder.stringByAppendingPathComponent("Software")
    #endif
  }()

  static let gamesFolderName = "GameCube"
  /// What the GameCube folder was called up to 1.1.5. Its games move into the GameCube folder at launch.
  static let oldGamesFolderName = "Games"

  private static var documentsFolder: String {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
  }

  /// gc-emu: Wii U games and keys.txt (Documents/Wii U), shown in Files next to GameCube.
  static let wiiUFolderName = "Wii U"

  /// gc-emu: Wii games (Documents/Wii), shown in Files next to GameCube.
  /// Wii games put in GameCube work too; the library sorts every game by what it is.
  static let wiiFolderName = "Wii"

  @objc static func getWiiFolder() -> String {
    wiiFolder
  }

  private static let wiiFolder: String = {
    #if (NONJAILBROKEN || TROLLSTORE || APPSTORE) && os(iOS)
    let dir = documentsFolder.stringByAppendingPathComponent(wiiFolderName)
    #else
    let dir = userFolder.stringByAppendingPathComponent("WiiGames")
    #endif
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }()

  /// gc-emu: move from the old layout, where Documents itself was Dolphin's user folder and games lived in
  /// Documents/Software. Must run before anything reads Dolphin's folders (AppDelegate, first thing).
  @objc static func migrateLegacyLayoutIfNeeded() {
    #if (NONJAILBROKEN || TROLLSTORE || APPSTORE) && os(iOS)
    let fm = FileManager.default
    let user = getUserFolder()
    let games = getSoftwareFolder()
    // Dev-only PGO profiles once lived in the games folder; keep them in the hidden user folder.
    let strayPGO = games.stringByAppendingPathComponent("pgo")
    if fm.fileExists(atPath: strayPGO) { merge(strayPGO, into: user.stringByAppendingPathComponent("pgo"), fm: fm) }
    moveOldLayout(docs: documentsFolder, user: user, games: games)
    restoreGameFolders(user: user, games: games, wii: getWiiFolder())
    let restoredKey = "restoredPlayerFolders"
    if !UserDefaults.standard.bool(forKey: restoredKey) {
      restorePlayerItems(docs: documentsFolder, user: user)
      UserDefaults.standard.set(true, forKey: restoredKey)
    }
    #endif
  }

  /// Folders Dolphin and Iridia keep in the hidden user folder. Only these move there from Documents; anything
  /// else in Documents is the player's and stays where they put it.
  static let ownNames: Set<String> = [
    "Anaglyph", "Backup", "Benchmarks", "Cache", "Clips", "Config", "Covers", "DebugSnapshots", "Dump",
    "DynamicInputTextures", "Firmware", "GBA", "GC", "GameSettings", "GraphicMods", "Load", "Logs", "Maps",
    "MemoryWatcher", "Passive", "Pipes", "Profiles", "Redump", "ResourcePacks", "Resources", "RetroAchievements",
    "Riivolution", "SavedAssembly", "Saves", "ScreenShots", "Shaders", "Skins", "StateSaves", "Styles", "Textures",
    "Themes", "Triforce", "Unpacking", "User", "WFS", "WiiGames", "pgo",
  ]

  static func moveOldLayout(docs: String, user: String, games: String) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: docs) else { return }
    for name in items {
      let src = docs.stringByAppendingPathComponent(name)
      if name == "Software" || name == oldGamesFolderName {
        moveChildren(of: src, into: games, fm: fm)
        LibraryAddedDateStore.moveDates(from: src, to: games)
        if (try? fm.contentsOfDirectory(atPath: src))?.isEmpty ?? false { try? fm.removeItem(atPath: src) }
      } else if ownNames.contains(name) {
        merge(src, into: user.stringByAppendingPathComponent(name), fm: fm)
      }
    }
  }

  /// Up to 1.2, every folder in Documents that wasn't a game folder was moved into the hidden user folder, so a
  /// folder the player made in Files vanished. This puts those folders, and any games or archives, back.
  static func restorePlayerItems(docs: String, user: String) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: user) else { return }
    let gameExtensions = playerFileExtensions
    for name in items where !name.hasPrefix(".") && !ownNames.contains(name) && name != "Wii" && name != gamesFolderName {
      let src = user.stringByAppendingPathComponent(name)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: src, isDirectory: &isDir) else { continue }
      guard isDir.boolValue || gameExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
      let dst = docs.stringByAppendingPathComponent(name)
      guard !fm.fileExists(atPath: dst) else { continue }
      do { try fm.moveItem(atPath: src, toPath: dst) } catch { NSLog("[Layout] couldn't restore %@: %@", name, "\(error)") }
    }
  }

  /// 1.1.5 and earlier hide a folder named GameCube or Wii that is in Documents: GameCube goes into the user
  /// folder, and Wii is mixed into the Wii save storage there. This brings the games back into 1.2's own
  /// folders. Runs at every launch, because an older version run after 1.2 hides them again.
  static func restoreGameFolders(user: String, games: String, wii: String) {
    let fm = FileManager.default
    let hiddenGames = user.stringByAppendingPathComponent(gamesFolderName)
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: hiddenGames, isDirectory: &isDir), isDir.boolValue {
      mergeKeepingBoth(hiddenGames, into: games, fm: fm)
    }
    // Only game and archive files at the top level: everything else in there is the Wii save storage.
    let storage = user.stringByAppendingPathComponent("Wii")
    for name in (try? fm.contentsOfDirectory(atPath: storage)) ?? [] where !name.hasPrefix(".") {
      let src = storage.stringByAppendingPathComponent(name)
      guard fm.fileExists(atPath: src, isDirectory: &isDir), !isDir.boolValue,
            playerFileExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
      try? fm.createDirectory(atPath: wii, withIntermediateDirectories: true)
      move(src, to: freePath(wii.stringByAppendingPathComponent(name), fm: fm), fm: fm)
    }
  }

  /// Game and archive files. "bin" and "img" are left out: Dolphin keeps files of its own with those endings.
  private static var playerFileExtensions: Set<String> {
    ImportableFileTypes.softwareExtensions.union(ImportableFileTypes.archiveExtensions)
      .union(WiiUFileTypes.extensions).subtracting(["bin", "img"])
  }

  /// Moves everything in `src` into `dst`. Folders are merged; a file whose name is taken is kept next to the
  /// one already there under a numbered name. Nothing is overwritten.
  private static func mergeKeepingBoth(_ src: String, into dst: String, fm: FileManager) {
    try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
    for child in (try? fm.contentsOfDirectory(atPath: src)) ?? [] {
      let from = src.stringByAppendingPathComponent(child), to = dst.stringByAppendingPathComponent(child)
      var fromIsDir: ObjCBool = false, toIsDir: ObjCBool = false
      guard fm.fileExists(atPath: from, isDirectory: &fromIsDir) else { continue }
      if fm.fileExists(atPath: to, isDirectory: &toIsDir), fromIsDir.boolValue, toIsDir.boolValue {
        mergeKeepingBoth(from, into: to, fm: fm)
      } else {
        move(from, to: freePath(to, fm: fm), fm: fm)
      }
    }
    if (try? fm.contentsOfDirectory(atPath: src))?.isEmpty ?? false { try? fm.removeItem(atPath: src) }
  }

  /// `path`, or "Name 2.ext", "Name 3.ext" and so on when that name is taken.
  private static func freePath(_ path: String, fm: FileManager) -> String {
    guard fm.fileExists(atPath: path) else { return path }
    let folder = (path as NSString).deletingLastPathComponent
    let ext = (path as NSString).pathExtension
    let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    var number = 2
    while true {
      let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
      let candidate = folder.stringByAppendingPathComponent(name)
      if !fm.fileExists(atPath: candidate) { return candidate }
      number += 1
    }
  }

  private static func move(_ src: String, to dst: String, fm: FileManager) {
    do { try fm.moveItem(atPath: src, toPath: dst) } catch { NSLog("[Layout] couldn't move %@: %@", src, "\(error)") }
  }

  /// Games put in a folder named Games (the GameCube folder's name up to 1.1.5) move into the GameCube folder.
  static func moveOldGamesFolder() {
    #if (NONJAILBROKEN || TROLLSTORE || APPSTORE) && os(iOS)
    let fm = FileManager.default
    let old = documentsFolder.stringByAppendingPathComponent(oldGamesFolderName)
    guard fm.fileExists(atPath: old) else { return }
    moveChildren(of: old, into: getSoftwareFolder(), fm: fm)
    LibraryAddedDateStore.moveDates(from: old, to: getSoftwareFolder())
    if (try? fm.contentsOfDirectory(atPath: old))?.isEmpty ?? false { try? fm.removeItem(atPath: old) }
    #endif
  }

  private static func moveChildren(of src: String, into dst: String, fm: FileManager) {
    try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
    for child in (try? fm.contentsOfDirectory(atPath: src)) ?? [] {
      merge(src.stringByAppendingPathComponent(child), into: dst.stringByAppendingPathComponent(child), fm: fm)
    }
  }

  /// Move `src` to `dst`. If `dst` already exists and both are folders, merge child by child;
  /// an existing file at the destination is kept (never overwritten).
  private static func merge(_ src: String, into dst: String, fm: FileManager) {
    var srcIsDir: ObjCBool = false, dstIsDir: ObjCBool = false
    guard fm.fileExists(atPath: src, isDirectory: &srcIsDir) else { return }
    if !fm.fileExists(atPath: dst, isDirectory: &dstIsDir) {
      do { try fm.moveItem(atPath: src, toPath: dst) } catch { NSLog("[Layout] couldn't move %@: %@", src, "\(error)") }
      return
    }
    if srcIsDir.boolValue && dstIsDir.boolValue {
      moveChildren(of: src, into: dst, fm: fm)
      if (try? fm.contentsOfDirectory(atPath: src))?.isEmpty ?? false { try? fm.removeItem(atPath: src) }
    }
  }
}
