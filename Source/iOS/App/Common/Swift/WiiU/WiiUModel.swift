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
  /// The shelf label of a disc image that needs its key.
  static let needsKeyFormat = L("Needs a key")

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
    copyKeysIfPresent()
    CemuBridge.reloadKeys()
    scanning = true
    let dir = gamesDir
    Task.detached(priority: .userInitiated) {
      let found = CemuBridge.scanGames()
      var titles = found + Self.homebrew(in: dir) + Self.discsNeedingKeys(in: dir, found: found)
      // Test hook (not in App Store builds): -wiiuShowOnly <name part> lists only matching games (store screenshots).
      #if !APPSTORE
      if let only = UserDefaults.standard.string(forKey: "wiiuShowOnly") {
        titles = titles.filter { ($0.name as String).localizedCaseInsensitiveContains(only) }
      }
      #endif
      await MainActor.run {
        self.games = titles.map { WiiUGame(id: $0.path, title: $0) }
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.scanning = false
        done?()
      }
    }
  }

  func play(_ game: WiiUGame) {
    guard phase == .ready, playing == nil else { return }
    if game.needsKey { keyNeeded = game; return }
    WiiULastPlayed.mark(game.id)
    playing = game
  }

  /// Ends the running game and returns to the library.
  func quit() {
    CemuBridge.setPaused(false)
    CemuBridge.stopGame()
    playing = nil
  }

  /// Homebrew programs (.rpx) in the top of the Wii U folder. Installed titles come from the core's scan.
  nonisolated private static func homebrew(in dir: URL) -> [CemuTitle] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension.lowercased() == "rpx" }.map { url in
      let t = CemuTitle()
      t.name = url.deletingPathExtension().lastPathComponent
      t.path = url.path
      t.format = "homebrew"
      return t
    }
  }

  /// Disc images in the top of the Wii U folder that the core couldn't open (no key for them in keys.txt).
  /// They still go on the shelf, so the player can add the key from there.
  nonisolated private static func discsNeedingKeys(in dir: URL, found: [CemuTitle]) -> [CemuTitle] {
    let opened = Set(found.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { url in
      guard ["wux", "wud", "iso"].contains(url.pathExtension.lowercased()), WiiUImport.classify(url) == .wiiU else { return false }
      return !opened.contains(url.resolvingSymlinksInPath().path)
    }.map { url in
      let t = CemuTitle()
      t.name = url.deletingPathExtension().lastPathComponent
      t.path = url.path
      t.format = needsKeyFormat
      return t
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
