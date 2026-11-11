// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Choose a Game File" for the Wii U tab, the same flow as the GameCube shelf's: Apple's picker,
// then Copy or Move into Documents/Wii U. Takes Wii U disc images (.wux, .wud, .iso), .wua and .wuhb files,
// game, update and extra content folders, homebrew (.rpx) and keys.txt. A picked folder that isn't a game
// itself is searched (two levels) for those. Archives (.zip, .7z, ...) are unpacked and searched the same way,
// also when the Files app put them in the Wii U folder. GameCube files get a plain message pointing to their tab.

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum WiiUImport {
  enum Kind: Equatable { case wiiU, keys, archive, gameCube, wii, other }

  static let fileExtensions: Set<String> = ["wux", "wud", "wua", "wuhb", "rpx", "iso"]
  /// GameCube (and Wii) formats the GameCube shelf knows; picking one here gets a pointer to that tab.
  /// (Archives can hold any system's game, so they're unpacked and looked inside instead.)
  private static let gameCubeExtensions: Set<String> = ["gcm", "tgc", "rvz", "wia", "gcz", "ciso", "nkit", "dol", "elf"]
  private static let wiiExtensions: Set<String> = ["wbfs", "wad"]

  /// What `url` is. Disc images named .iso are told apart by the GameCube and Wii disc magic words.
  nonisolated static func classify(_ url: URL) -> Kind {
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
    if ZipImportHelper.isArchivePath(url.path) { return .archive }
    if gameCubeExtensions.contains(ext) { return .gameCube }
    if wiiExtensions.contains(ext) { return .wii }
    return .other
  }

  /// An installed game, update or extra content folder (title.tmd), or an unpacked one (code, content, meta).
  nonisolated static func isTitleFolder(_ url: URL) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.appendingPathComponent("title.tmd").path) { return true }
    return ["code", "meta"].allSatisfy { isDirectory(url.appendingPathComponent($0)) }
  }

  nonisolated private static func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  nonisolated private static func discMagic(_ url: URL) -> Kind? {
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
    var archives: [URL] = []
    var gameCube: [String] = []
    var wii: [String] = []
    var other: [String] = []
  }

  /// `maxDepth`: how far into picked folders to look (an unpacked archive gets one level more).
  nonisolated static func sort(_ urls: [URL], maxDepth: Int = 2) -> Sorted {
    var sorted = Sorted()
    func visit(_ url: URL, depth: Int, picked: Bool) {
      switch classify(url) {
      case .wiiU: sorted.items.append(url)
      case .keys: sorted.keys.append(url)
      case .archive: if picked { sorted.archives.append(url) }
      case .gameCube: sorted.gameCube.append(url.lastPathComponent)
      case .wii: sorted.wii.append(url.lastPathComponent)
      case .other:
        if isDirectory(url), depth < maxDepth {
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

  enum KeyError: LocalizedError {
    case noKeys
    var errorDescription: String? { L("That isn't a disc key. A key is 32 characters, using 0 to 9 and A to F.") }
  }

  /// The key on a keys.txt line, the way the core reads it: before any # or ;, without spaces, dashes or
  /// underscores. Nil unless it's 32 hex characters (anything else would make the core show an error).
  nonisolated static func key(in line: Substring) -> String? {
    let text = line.prefix { $0 != "#" && $0 != ";" }
    let k = text.filter { !" \t-_".contains($0) }.lowercased()
    return k.count == 32 && k.allSatisfy(\.isHexDigit) ? k : nil
  }

  /// Adds the keys in `source` that the Wii U folder's keys.txt doesn't have yet. Returns how many.
  nonisolated static func mergeKeys(from source: URL, into folder: URL) throws -> Int {
    try mergeKeys(text: String(contentsOf: source, encoding: .utf8), into: folder)
  }

  /// Adds the keys in `incoming` that keys.txt doesn't have yet (other lines are left out). Returns how many;
  /// throws when `incoming` has no key at all.
  nonisolated static func mergeKeys(text incoming: String, into folder: URL) throws -> Int {
    let target = folder.appendingPathComponent("keys.txt")
    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    var known = Set(existing.split(whereSeparator: \.isNewline).compactMap { key(in: $0) })
    var added: [String] = []
    var valid = 0
    for line in incoming.split(whereSeparator: \.isNewline) {
      guard let k = key(in: line) else { continue }
      valid += 1
      guard !known.contains(k) else { continue }
      known.insert(k)
      added.append(line.contains("#") ? line.trimmingCharacters(in: .whitespaces) : k)
    }
    guard valid > 0 else { throw KeyError.noKeys }
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
    /// Archives with no Wii U game inside (name, and whether a GameCube or Wii game was found instead).
    var archivesWithoutWiiU: [(name: String, otherSystem: Bool)] = []
  }

  /// Hidden folders archives are unpacked into, inside the Wii U folder (same disk, so moving out is instant).
  static let unpackPrefix = ".unpacking-"

  /// The file work of an import, off the main thread. A name already in the folder is skipped, never replaced.
  nonisolated static func copy(_ sorted: Sorted, into folder: URL, move: Bool) -> Outcome {
    let fm = FileManager.default
    _ = ImportStaging.removeStaleStagedImports(inFolder: folder.path)
    for leftover in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where leftover.hasPrefix(unpackPrefix) {
      try? fm.removeItem(at: folder.appendingPathComponent(leftover))   // an unpack cut short last time
    }
    var outcome = Outcome()
    for archive in sorted.archives {
      unpack(archive, into: folder, deleteArchive: move, outcome: &outcome)
    }
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

  /// Unpacks `archive` into a hidden folder, adds the Wii U games and keys inside, then removes that folder.
  /// The archive itself is deleted only when `deleteArchive` and a game came out of it.
  nonisolated private static func unpack(_ archive: URL, into folder: URL, deleteArchive: Bool, outcome: inout Outcome) {
    let fm = FileManager.default
    let name = archive.lastPathComponent
    let temp = folder.appendingPathComponent(unpackPrefix + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: temp) }
    do { try ZipImportHelper.extractArchive(at: archive, to: temp) } catch {
      outcome.errors.append(String(format: L("%@ couldn't be unpacked: %@"), name, error.localizedDescription))
      return
    }
    let children = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let inner = sort(children, maxDepth: 3)
    if inner.items.isEmpty && inner.keys.isEmpty {
      outcome.archivesWithoutWiiU.append((name, !inner.gameCube.isEmpty || !inner.wii.isEmpty))
      return
    }
    let before = outcome.added.count
    for url in inner.items {
      if fm.fileExists(atPath: folder.appendingPathComponent(url.lastPathComponent).path) {
        outcome.skipped.append(url.lastPathComponent); continue
      }
      do { try place(url, in: folder, move: true); outcome.added.append(url.lastPathComponent) }
      catch { outcome.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    for url in inner.keys {
      do { outcome.keysAdded += try mergeKeys(from: url, into: folder) }
      catch { outcome.errors.append("keys.txt: \(error.localizedDescription)") }
    }
    if deleteArchive, outcome.added.count > before { try? fm.removeItem(at: archive) }
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
    guard !sorted.items.isEmpty || !sorted.keys.isEmpty || !sorted.archives.isEmpty else {
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
    if sorted.items.isEmpty && sorted.archives.isEmpty { finish(false); return }
    let question = UIAlertController(title: L("Import"), message: nil, preferredStyle: .alert)
    question.addAction(UIAlertAction(title: L("Copy"), style: .default) { _ in finish(false) })
    question.addAction(UIAlertAction(title: L("Move"), style: .default) { _ in finish(true) })
    question.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in finish(nil) })
    GameFilePicker.topViewController()?.present(question, animated: true)
  }

  /// Archives the Files app put straight into the Wii U folder: unpacked once, and removed when a game came out.
  /// One that has no Wii U game is left where it is and not tried again. Returns true when an unpack started
  /// (it scans the shelf again when it's done).
  func unpackArchivesInFolder() -> Bool {
    guard !importing else { return false }
    let files = (try? FileManager.default.contentsOfDirectory(at: gamesDir, includingPropertiesForKeys: [.fileSizeKey],
                                                              options: [.skipsHiddenFiles])) ?? []
    var tried = Set(UserDefaults.standard.stringArray(forKey: "wiiuArchivesTried") ?? [])
    func key(_ url: URL) -> String {
      "\(url.lastPathComponent)|\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
    }
    let archives = files.filter { WiiUImport.classify($0) == .archive && !tried.contains(key($0)) }
    guard !archives.isEmpty else { return false }
    archives.forEach { tried.insert(key($0)) }
    UserDefaults.standard.set(Array(tried), forKey: "wiiuArchivesTried")
    var sorted = WiiUImport.Sorted()
    sorted.archives = archives
    copyIn(sorted, move: true, notes: []) {}
    return true
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
        } else if !sorted.keys.isEmpty, outcome.errors.isEmpty {
          lines.append(L("keys.txt already has these keys."))
        }
        for archive in outcome.archivesWithoutWiiU {
          lines.append(archive.otherSystem
            ? String(format: L("%@ has a GameCube or Wii game inside, not a Wii U game. GameCube games go on the GameCube tab."), archive.name)
            : String(format: L("%@ doesn't have a Wii U game inside."), archive.name))
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
