// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

@objc class UserFolderUtil: NSObject {
  /// Dolphin's user folder (config, saves, caches, logs). gc-emu: on iOS this lives in
  /// Library/Application Support/Iridia, which the Files app never shows, so Files only lists
  /// the one Games folder (see getSoftwareFolder). Computed once.
  @objc static func getUserFolder() -> String {
    userFolder
  }

  /// Where games go. gc-emu: on iOS this is Documents/Games, the only folder the Files app shows
  /// under "On My iPhone > Iridia", so it's obvious where to put a game file.
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

  static let gamesFolderName = "Games"

  private static var documentsFolder: String {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
  }

  /// gc-emu: one-time move from the old layout, where Documents itself was Dolphin's user folder
  /// and games lived in Documents/Software. Everything except the Games folder moves into the
  /// hidden user folder, and the old Software folder's contents move into Documents/Games.
  /// Must run before anything reads Dolphin's folders (AppDelegate, first thing).
  @objc static func migrateLegacyLayoutIfNeeded() {
    #if (NONJAILBROKEN || TROLLSTORE || APPSTORE) && os(iOS)
    let fm = FileManager.default
    let docs = documentsFolder
    let user = getUserFolder()
    let games = getSoftwareFolder()
    // Dev-only PGO profiles once lived in the games folder; keep them in the hidden user folder.
    let strayPGO = games.stringByAppendingPathComponent("pgo")
    if fm.fileExists(atPath: strayPGO) { merge(strayPGO, into: user.stringByAppendingPathComponent("pgo"), fm: fm) }
    guard let items = try? fm.contentsOfDirectory(atPath: docs) else { return }
    for name in items where name != gamesFolderName && name != "Inbox" && !name.hasPrefix(".") {
      let src = docs.stringByAppendingPathComponent(name)
      if name == "Software" {
        moveChildren(of: src, into: games, fm: fm)
        if (try? fm.contentsOfDirectory(atPath: src))?.isEmpty ?? false { try? fm.removeItem(atPath: src) }
      } else {
        merge(src, into: user.stringByAppendingPathComponent(name), fm: fm)
      }
    }
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
