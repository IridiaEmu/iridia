// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U folder's side of an import (GameImport decides what goes where): places games, updates,
// extra content and homebrew in Documents/Wii U, and adds disc keys to keys.txt.

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum WiiUImport {
  struct Sorted {
    var items: [URL] = []
    var keys: [URL] = []
  }

  nonisolated private static func isDirectory(_ url: URL) -> Bool { WiiUFileTypes.isDirectory(url) }

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
    /// Updates and extra content that were added: they don't get a case of their own.
    var addOns: [String] = []
  }

  /// The file work of an import, off the main thread. A name already in the folder is skipped, never replaced.
  nonisolated static func copy(_ sorted: Sorted, into folder: URL, move: Bool) -> Outcome {
    _ = ImportStaging.removeStaleStagedImports(inFolder: folder.path)
    var outcome = Outcome()
    for url in sorted.items {
      add(url, into: folder, move: move, outcome: &outcome)
    }
    for url in sorted.keys {
      do { outcome.keysAdded += try mergeKeys(from: url, into: folder) }
      catch { outcome.errors.append("keys.txt: \(error.localizedDescription)") }
    }
    return outcome
  }

  /// Places one game, update or homebrew file, after checking it isn't there already and that it fits.
  nonisolated private static func add(_ url: URL, into folder: URL, move: Bool, outcome: inout Outcome) {
    let name = url.lastPathComponent
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
      outcome.skipped.append(name); return
    }
    if !sameDisk(url, folder), let message = spaceProblem(for: url, needing: size(of: url), into: folder) {
      outcome.errors.append(message); return
    }
    do { try place(url, in: folder, move: move) } catch {
      outcome.errors.append("\(name): \(error.localizedDescription)"); return
    }
    let placed = folder.appendingPathComponent(name)
    if isDirectory(placed), let id = WiiUFileTypes.titleID(ofFolder: placed), WiiUFileTypes.kind(ofTitleID: id) != .game {
      outcome.addOns.append(name)
    } else {
      outcome.added.append(name)
    }
  }

  /// On the same disk a copy is a clone and a move a rename, so neither needs free space.
  nonisolated static func sameDisk(_ a: URL, _ b: URL) -> Bool {
    guard let x = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
          let y = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject else { return false }
    return x.isEqual(y)
  }

  /// A message when `needed` bytes for `url` won't fit in the space left in `folder`.
  nonisolated static func spaceProblem(for url: URL, needing needed: Int64, into folder: URL) -> String? {
    guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage else { return nil }
    let margin: Int64 = 200 * 1024 * 1024
    guard needed + margin > free else { return nil }
    let f = ByteCountFormatter()
    f.countStyle = .file
    return String(format: L("There isn't enough space for %@. It needs %@, and %@ is free."),
                  url.lastPathComponent, f.string(fromByteCount: needed), f.string(fromByteCount: max(0, free)))
  }

  nonisolated static func size(of url: URL) -> Int64 {
    guard isDirectory(url) else {
      return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    var total: Int64 = 0
    let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    while let file = e?.nextObject() as? URL {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}

extension WiiUModel {
  /// "Choose a Game File" on the Wii U tab. A GameCube or Wii game picked here goes to its own tab.
  func chooseGameFiles() {
    GameFilePicker.present(types: [.data, .folder], directory: gamesDir) { urls in GameImport.add(urls, from: .wiiU) }
  }

  static func shortList(_ names: [String]) -> String { GameImport.shortList(names) }
  static func noTicketNote(_ names: [String]) -> String { GameImport.noTicketNote(names) }
}
#endif
