// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: tells Wii U games apart from GameCube ones, by name and by content. Shared by both tabs: the GameCube
// shelf points Wii U files to the Wii U tab, and the Wii U import, shelf and delete use the same rules.

import Foundation

enum WiiUFileTypes {
  /// Wii U game files that never hold a GameCube game. (.iso can be either, so it's checked by content.)
  static let extensions: Set<String> = ["wux", "wud", "wua", "wuhb", "rpx"]

  enum TitleKind { case game, update, extraContent, other }

  /// A Wii U game file: one of `extensions`, or a disc image named .iso that is a Wii U disc.
  static func isWiiUFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if extensions.contains(ext) { return true }
    return ext == "iso" && isWiiUDisc(url)
  }

  /// A Wii U disc image starts with its product code, "WUP-P-XXXX".
  static func isWiiUDisc(_ url: URL) -> Bool {
    guard let head = readHead(url, count: 4) else { return false }
    return head == Data("WUP-".utf8)
  }

  static func readHead(_ url: URL, count: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
    return data
  }

  static func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  /// An installed game, update or extra content folder (title.tmd), or an unpacked one (code and meta).
  static func isTitleFolder(_ url: URL) -> Bool {
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("title.tmd").path) { return true }
    return ["code", "meta"].allSatisfy { isDirectory(url.appendingPathComponent($0)) }
  }

  /// An installed (encrypted) title folder without the title.tik its contents are opened with.
  static func isMissingTicket(_ url: URL) -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: url.appendingPathComponent("title.tmd").path)
      && !fm.fileExists(atPath: url.appendingPathComponent("title.tik").path)
  }

  /// The title ID of a title folder: from title.tmd, or from meta/meta.xml in an unpacked one.
  static func titleID(ofFolder url: URL) -> UInt64? {
    if let tmd = readHead(url.appendingPathComponent("title.tmd"), count: 0x194) {
      return tmd[0x18C..<0x194].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
    guard let xml = try? String(contentsOf: url.appendingPathComponent("meta/meta.xml"), encoding: .utf8),
          let start = xml.range(of: "<title_id"), let open = xml[start.upperBound...].firstIndex(of: ">"),
          let close = xml[open...].range(of: "</title_id>") else { return nil }
    return UInt64(xml[xml.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
  }

  /// Games are 00050000-xxxxxxxx, their updates 0005000E-xxxxxxxx and extra content 0005000C-xxxxxxxx.
  static func kind(ofTitleID id: UInt64) -> TitleKind {
    switch id >> 32 {
    case 0x0005_0000: return .game
    case 0x0005_000E: return .update
    case 0x0005_000C: return .extraContent
    default: return .other
    }
  }

  /// Files and folders under `dir`, `maxDepth` levels down, for scans of a games folder. Doesn't go into title
  /// folders (their code folder is full of .rpx files that aren't homebrew), hidden folders or half-done imports.
  static func walk(_ dir: URL, maxDepth: Int) -> [URL] {
    var found: [URL] = []
    func visit(_ folder: URL, depth: Int) {
      let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
      for child in children where !child.lastPathComponent.hasSuffix(".importing") {
        found.append(child)
        if depth + 1 < maxDepth, isDirectory(child), !isTitleFolder(child) { visit(child, depth: depth + 1) }
      }
    }
    visit(dir, depth: 0)
    return found
  }
}
