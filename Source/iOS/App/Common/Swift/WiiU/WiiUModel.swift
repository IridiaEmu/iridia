// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Wii U tab state. Starts the Wii U core (IridiaCafeCore) the first time the tab opens, finds the
// player's games in Documents/Wii U (added with "Choose a Game File" or the Files app), and hands a chosen
// game to the play screen. Players bring their own games, and keys.txt for disc images.

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import IridiaCafeCore
import SwiftUI
import UIKit

struct WiiUGame: Identifiable, Hashable {
  let id: String          // file path
  let title: CemuTitle
  var name: String { title.name }
  /// A disc image (.wux, .wud) that no key in keys.txt opens yet. Play asks for the key (WiiUDiscKeyView).
  var needsKey: Bool { title.format == WiiUModel.needsKeyFormat }
  /// An installed game folder without its title.tik. Play explains what's missing.
  var missingTicket: Bool { title.format == WiiUModel.missingTicketFormat }
}

@MainActor
final class WiiUModel: ObservableObject {
  static let shared = WiiUModel()

  enum Phase: Equatable { case idle, starting, ready, failed(String) }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var games: [WiiUGame] = []
  @Published private(set) var scanning = false
  @Published var playing: WiiUGame?
  /// True while picked games are being copied into the Wii U folder (WiiUImport).
  @Published var importing = false
  /// A disc image the player tried to play without its key; shows the key screen.
  @Published var keyNeeded: WiiUGame?
  /// A game folder the player tried to play without its title.tik; shows what's missing.
  @Published var ticketMissing: WiiUGame?
  /// The shelf label of a disc image that needs its key.
  nonisolated static let needsKeyFormat = L("Needs a key")
  /// The shelf label of a game folder without its title.tik.
  nonisolated static let missingTicketFormat = L("Missing title.tik")

  /// Documents/Wii U: the folder players see in Files ("On My iPhone > Iridia > Wii U").
  let gamesDir: URL
  /// Library/Application Support/IridiaCafe: Wii U settings, console storage (mlc01), keys, caches. Hidden from Files.
  let userDir: URL

  /// "On My iPhone > Iridia > Wii U" (iPad on iPad), as the Files app names it.
  static var filesPath: String {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    return "\(device) > \(FilesAppNames.appFolder) > \(folderName)"
  }
  static let folderName = UserFolderUtil.wiiUFolderName

  /// Wii U games need about 2.7 GB while they run; only devices with 8 GB of memory can play them.
  /// (8 GB devices report a little under 8 GB.)
  static let canRunGames = ProcessInfo.processInfo.physicalMemory >= 7_000_000_000

  private init() {
    let fm = FileManager.default
    gamesDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.folderName, isDirectory: true)
    userDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("IridiaCafe", isDirectory: true)
    for dir in [gamesDir, userDir] {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  /// Starts the core once (on the first visit to the tab), then looks for games.
  func start() {
    guard phase == .idle, Self.canRunGames else { return }
    phase = .starting
    copyKeysIfPresent()
    // "Use less memory": the GPU reads the console's memory directly instead of keeping its own copy
    // (about 150 MB less, a little slower). Read when the core starts.
    if UserDefaults.standard.bool(forKey: "cafeLessMemory") { setenv("IRIDIA_BUFFER_HOST", "1", 1) }
    let user = userDir.path, games = gamesDir.path
    let resources = (Bundle(for: CemuBridge.self).resourceURL ?? Bundle.main.bundleURL)
      .appendingPathComponent("CemuData").path
    Task.detached(priority: .userInitiated) {
      let error = CemuBridge.start(withUserDir: user, gamesDir: games, resourcesDir: resources)
      await MainActor.run {
        if let error {
          self.phase = .failed(error)
        } else {
          self.phase = .ready
          self.rescan()
        }
      }
    }
  }

  func rescan(then done: (() -> Void)? = nil) {
    guard phase == .ready, !scanning, playing == nil else { done?(); return }
    if unpackArchivesInFolder() { done?(); return }   // scans again when the unpack is done
    copyKeysIfPresent()
    CemuBridge.reloadKeys()
    scanning = true
    let dir = gamesDir
    Task.detached(priority: .userInitiated) {
      let found = CemuBridge.scanGames()
      var titles = found + Self.homebrew(in: dir) + Self.gamesThatCantOpen(in: dir, found: found)
      // Test hook (not in App Store builds): -wiiuShowOnly <name part> lists only matching games (store screenshots).
      #if !APPSTORE
      if let only = UserDefaults.standard.string(forKey: "wiiuShowOnly") {
        titles = titles.filter { ($0.name as String).localizedCaseInsensitiveContains(only) }
      }
      #endif
      let shown = titles
      await MainActor.run {
        self.games = shown.map { WiiUGame(id: $0.path, title: $0) }
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.scanning = false
        done?()
      }
    }
  }

  func play(_ game: WiiUGame) {
    guard phase == .ready, playing == nil else { return }
    if game.needsKey { keyNeeded = game; return }
    if game.missingTicket { ticketMissing = game; return }
    WiiULastPlayed.mark(game.id)
    playing = game
  }

  /// Ends the running game and returns to the library.
  func quit() {
    CemuBridge.setPaused(false)
    CemuBridge.stopGame()
    playing = nil
  }

  /// Homebrew programs (.rpx) in the Wii U folder and the folders in it (not inside games). Installed titles
  /// come from the core's scan.
  nonisolated private static func homebrew(in dir: URL) -> [CemuTitle] {
    WiiUFileTypes.walk(dir, maxDepth: 3).filter { $0.pathExtension.lowercased() == "rpx" }.map { url in
      let t = CemuTitle()
      t.name = url.deletingPathExtension().lastPathComponent
      t.path = url.path
      t.format = "homebrew"
      return t
    }
  }

  /// Games in the Wii U folder (or a folder in it) that the core couldn't open, so they still go on the shelf
  /// and Play can say why: disc images with no key for them in keys.txt, and game folders without title.tik.
  nonisolated private static func gamesThatCantOpen(in dir: URL, found: [CemuTitle]) -> [CemuTitle] {
    let opened = Set(found.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
    return WiiUFileTypes.walk(dir, maxDepth: 3).compactMap { url in
      guard !opened.contains(url.resolvingSymlinksInPath().path) else { return nil }
      let format: String
      if WiiUFileTypes.isDirectory(url) {
        guard WiiUFileTypes.isMissingTicket(url),
              WiiUFileTypes.titleID(ofFolder: url).map({ WiiUFileTypes.kind(ofTitleID: $0) == .game }) ?? true else { return nil }
        format = missingTicketFormat
      } else {
        guard ["wux", "wud", "iso"].contains(url.pathExtension.lowercased()), WiiUImport.classify(url) == .wiiU else { return nil }
        format = needsKeyFormat
      }
      let t = CemuTitle()
      t.name = url.deletingPathExtension().lastPathComponent
      t.path = url.path
      t.format = format
      return t
    }
  }

  /// The update and extra content folders in the Wii U folder that belong to `game` (same title ID, other type).
  func addOns(of game: WiiUGame) -> [URL] {
    let low = game.title.titleId & 0xFFFF_FFFF
    guard game.title.titleId != 0 else { return [] }
    return WiiUFileTypes.walk(gamesDir, maxDepth: 3).filter { url in
      guard WiiUFileTypes.isTitleFolder(url), let id = WiiUFileTypes.titleID(ofFolder: url) else { return false }
      return id & 0xFFFF_FFFF == low && [.update, .extraContent].contains(WiiUFileTypes.kind(ofTitleID: id))
    }
  }

  /// Adds the disc keys in `text` (pasted, or a keys.txt) to the Wii U folder's keys.txt.
  func addDiscKeys(_ text: String) throws -> Int {
    try WiiUImport.mergeKeys(text: text, into: gamesDir)
  }

  /// The core reads disc keys from keys.txt in its data folder; players put theirs next to their games.
  private func copyKeysIfPresent() {
    let fm = FileManager.default
    let source = gamesDir.appendingPathComponent("keys.txt")
    guard fm.fileExists(atPath: source.path) else { return }
    let target = userDir.appendingPathComponent("keys.txt")
    try? fm.removeItem(at: target)
    try? fm.copyItem(at: source, to: target)
  }
}

enum WiiULastPlayed {
  private static let key = "cafeLastPlayed"
  static func all() -> [String: Date] {
    (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
  }
  static func mark(_ id: String) {
    var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    all[id] = Date().timeIntervalSince1970
    UserDefaults.standard.set(all, forKey: key)
  }
}
#endif
