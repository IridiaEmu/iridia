// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Choose a Game File" for the Wii U tab, the same flow as the GameCube shelf's: Apple's picker,
// then Copy or Move into Documents/Wii U. Takes Wii U disc images (.wux, .wud, .iso), .wua and .wuhb files,
// game, update and extra content folders, homebrew (.rpx) and keys.txt. A picked folder that isn't a game
// itself is searched (two levels) for those. GameCube files get a plain message pointing to their tab.

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum WiiUImport {
  enum Kind: Equatable { case wiiU, keys, gameCube, wii, other }

  static let fileExtensions: Set<String> = ["wux", "wud", "wua", "wuhb", "rpx", "iso"]
  /// GameCube (and Wii) formats the GameCube shelf knows; picking one here gets a pointer to that tab.
  private static let gameCubeExtensions: Set<String> = ["gcm", "tgc", "rvz", "wia", "gcz", "ciso", "nkit", "dol", "elf", "zip", "7z"]
  private static let wiiExtensions: Set<String> = ["wbfs", "wad"]

  /// What `url` is. Disc images named .iso are told apart by the GameCube and Wii disc magic words.
  static func classify(_ url: URL) -> Kind {
    if url.lastPathComponent.lowercased() == "keys.txt" { return .keys }
    if isDirectory(url) { return isTitleFolder(url) ? .wiiU : .other }
    let ext = url.pathExtension.lowercased()
    if ext == "iso" {
      switch discMagic(url) {
      case .gameCube?: return .gameCube
      case .wii?: return .wii
      default: return .wiiU
      }
    }
    if fileExtensions.contains(ext) { return .wiiU }
    if gameCubeExtensions.contains(ext) { return .gameCube }
    if wiiExtensions.contains(ext) { return .wii }
    return .other
  }

  /// An installed game, update or extra content folder (title.tmd), or an unpacked one (code, content, meta).
  static func isTitleFolder(_ url: URL) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.appendingPathComponent("title.tmd").path) { return true }
    return ["code", "meta"].allSatisfy { isDirectory(url.appendingPathComponent($0)) }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  private static func discMagic(_ url: URL) -> Kind? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 0x20), head.count == 0x20 else { return nil }
    let word = { (at: Int) in head[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    if word(0x18) == 0x5D1C_9EA3 { return .wii }
    if word(0x1C) == 0xC233_9F3D { return .gameCube }
    return nil
  }

  /// Sorts what the player picked: Wii U items to add, keys.txt files, and names to explain.
  struct Sorted {
    var items: [URL] = []
    var keys: [URL] = []
    var gameCube: [String] = []
    var wii: [String] = []
    var other: [String] = []
  }

  static func sort(_ urls: [URL]) -> Sorted {
    var sorted = Sorted()
    func visit(_ url: URL, depth: Int, picked: Bool) {
      switch classify(url) {
      case .wiiU: sorted.items.append(url)
      case .keys: sorted.keys.append(url)
      case .gameCube: if picked { sorted.gameCube.append(url.lastPathComponent) }
      case .wii: if picked { sorted.wii.append(url.lastPathComponent) }
      case .other:
        if isDirectory(url), depth < 2 {
          let before = sorted.items.count + sorted.keys.count
          let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? []
          for child in children { visit(child, depth: depth + 1, picked: false) }
          if picked, sorted.items.count + sorted.keys.count == before { sorted.other.append(url.lastPathComponent) }
        } else if picked {
          sorted.other.append(url.lastPathComponent)
        }
      }
    }
    for url in urls { visit(url, depth: 0, picked: true) }
    return sorted
  }

  /// Puts `source` (a file or a folder) into `folder` under its own name. Like the GameCube import it goes
  /// through a `.importing` sibling, so a game only ever appears complete.
  nonisolated static func place(_ source: URL, in folder: URL, move: Bool) throws {
    let fm = FileManager.default
    let destination = folder.appendingPathComponent(source.lastPathComponent)
    guard isDirectory(source) else {
      if move {
        try ImportStaging.stagedMove(fromPath: source.path, toPath: destination.path)
      } else {
        try ImportStaging.stagedCopy(fromPath: source.path, toPath: destination.path)
      }
      return
    }
    let staged = destination.path + ImportStaging.stagingSuffix
    try? fm.removeItem(atPath: staged)
    if move {
      try fm.moveItem(atPath: source.path, toPath: staged)
      do { try fm.moveItem(atPath: staged, toPath: destination.path) } catch {
        try? fm.moveItem(atPath: staged, toPath: source.path)   // never lose the player's files
        throw error
      }
    } else {
      do {
        try fm.copyItem(atPath: source.path, toPath: staged)
        try fm.moveItem(atPath: staged, toPath: destination.path)
      } catch {
        try? fm.removeItem(atPath: staged)
        throw error
      }
    }
  }

  /// Adds the keys in `source` that the Wii U folder's keys.txt doesn't have yet. Returns how many.
  nonisolated static func mergeKeys(from source: URL, into folder: URL) throws -> Int {
    let target = folder.appendingPathComponent("keys.txt")
    let incoming = try String(contentsOf: source, encoding: .utf8)
    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    func key(_ line: Substring) -> String {
      String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        .trimmingCharacters(in: .whitespaces).lowercased()
    }
    var known = Set(existing.split(whereSeparator: \.isNewline).map(key).filter { !$0.isEmpty })
    var added: [String] = []
    for line in incoming.split(whereSeparator: \.isNewline) {
      let k = key(line)
      guard !k.isEmpty, !known.contains(k) else { continue }
      known.insert(k)
      added.append(String(line))
    }
    guard !added.isEmpty else { return 0 }
    var text = existing
    if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    text += added.joined(separator: "\n") + "\n"
    try text.write(to: target, atomically: true, encoding: .utf8)
    return added.count
  }

  struct Outcome {
    var added: [String] = []
    var skipped: [String] = []
    var errors: [String] = []
    var keysAdded = 0
  }

  /// The file work of an import, off the main thread. A name already in the folder is skipped, never replaced.
  nonisolated static func copy(_ sorted: Sorted, into folder: URL, move: Bool) -> Outcome {
    _ = ImportStaging.removeStaleStagedImports(inFolder: folder.path)
    var outcome = Outcome()
    for url in sorted.items {
      if FileManager.default.fileExists(atPath: folder.appendingPathComponent(url.lastPathComponent).path) {
        outcome.skipped.append(url.lastPathComponent); continue
      }
      do { try place(url, in: folder, move: move); outcome.added.append(url.lastPathComponent) }
      catch { outcome.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    for url in sorted.keys {
      do { outcome.keysAdded += try mergeKeys(from: url, into: folder) }
      catch { outcome.errors.append("keys.txt: \(error.localizedDescription)") }
    }
    return outcome
  }
}

extension WiiUModel {
  /// "Choose a Game File" on the Wii U tab.
  func chooseGameFiles() {
    GameFilePicker.present(types: [.data, .folder], directory: gamesDir) { [weak self] urls in
      self?.add(urls)
    }
  }

  /// Adds picked files and folders: explains anything that isn't a Wii U game, then asks Copy or Move.
  func add(_ urls: [URL]) {
    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    let sorted = WiiUImport.sort(urls)
    var notes: [String] = []
    if !sorted.gameCube.isEmpty {
      notes.append(String(format: L("%@ is a GameCube game. Add it on the GameCube tab."), sorted.gameCube.joined(separator: ", ")))
    }
    if !sorted.wii.isEmpty {
      notes.append(String(format: L("%@ is a Wii game. Wii games aren't supported."), sorted.wii.joined(separator: ", ")))
    }
    if !sorted.other.isEmpty {
      notes.append(String(format: L("%@ isn't a Wii U game. Use WUA, WUX, WUD or RPX files, or a game folder."), sorted.other.joined(separator: ", ")))
    }
    guard !sorted.items.isEmpty || !sorted.keys.isEmpty else {
      accessed.forEach { $0.stopAccessingSecurityScopedResource() }
      alert(title: L("Nothing to Add"), message: notes.joined(separator: "\n\n"))
      return
    }
    let finish = { (move: Bool?) in
      guard let move else {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        return
      }
      self.copyIn(sorted, move: move, notes: notes) { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
    }
    // keys.txt alone is always copied; games get the same Copy / Move question as the GameCube shelf.
    if sorted.items.isEmpty { finish(false); return }
    let question = UIAlertController(title: L("Import"), message: nil, preferredStyle: .alert)
    question.addAction(UIAlertAction(title: L("Copy"), style: .default) { _ in finish(false) })
    question.addAction(UIAlertAction(title: L("Move"), style: .default) { _ in finish(true) })
    question.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in finish(nil) })
    GameFilePicker.topViewController()?.present(question, animated: true)
  }

  private func copyIn(_ sorted: WiiUImport.Sorted, move: Bool, notes: [String], done: @escaping () -> Void) {
    importing = true
    let folder = gamesDir
    let task = ImportStaging.beginBackgroundTask()
    Task.detached(priority: .userInitiated) {
      let outcome = WiiUImport.copy(sorted, into: folder, move: move)
      await MainActor.run {
        ImportStaging.endBackgroundTask(task)
        done()
        self.importing = false
        var lines = notes
        if !outcome.added.isEmpty {
          lines.insert(outcome.added.count == 1 ? String(format: L("Added %@."), outcome.added[0])
                                                : String(format: L("Added %ld games."), outcome.added.count), at: 0)
        }
        if outcome.keysAdded > 0 {
          lines.append(outcome.keysAdded == 1 ? L("Added 1 key to keys.txt.")
                                              : String(format: L("Added %ld keys to keys.txt."), outcome.keysAdded))
          // The core reads keys.txt once, when Iridia starts; discs that need the new keys show up after that.
          lines.append(L("Close and reopen Iridia to see disc images that use them."))
        } else if !sorted.keys.isEmpty, outcome.errors.isEmpty {
          lines.append(L("keys.txt already has these keys."))
        }
        if !outcome.skipped.isEmpty {
          lines.append(String(format: L("Already in the Wii U folder: %@."), outcome.skipped.joined(separator: ", ")))
        }
        lines += outcome.errors.prefix(3)
        self.rescan()
        // A plain "Added" needs no alert: the game appears on the shelf. Anything else is said once.
        if !(lines.count == 1 && !outcome.added.isEmpty) {
          self.alert(title: outcome.errors.isEmpty ? L("Import") : L("Some Files Weren't Added"), message: lines.joined(separator: "\n\n"))
        }
      }
    }
  }

  private func alert(title: String, message: String) {
    let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
    a.addAction(UIAlertAction(title: L("OK"), style: .default))
    GameFilePicker.topViewController()?.present(a, animated: true)
  }
}
#endif
