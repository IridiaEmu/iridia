// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Minizip
import zlib

/// How far an unpack has got, shared between the unpacking thread and the screen showing it.
final class UnpackProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var _total: Int64 = 0
  private var _done: Int64 = 0
  private var _cancelled = false
  private var _interrupted = false

  var total: Int64 { lock.withLock { _total } }
  var done: Int64 { lock.withLock { _done } }
  var fraction: Double {
    lock.withLock { _total > 0 ? min(1, Double(_done) / Double(_total)) : 0 }
  }
  var isCancelled: Bool { lock.withLock { _cancelled } }
  /// Stopped by the app rather than the player.
  var wasInterrupted: Bool { lock.withLock { _interrupted } }

  func setTotal(_ bytes: Int64) { lock.withLock { _total = bytes; _done = 0 } }
  func add(_ bytes: Int64) { lock.withLock { _done += bytes } }
  func setFraction(_ fraction: Double) {
    lock.withLock { _done = Int64(Double(_total) * min(1, max(0, fraction))) }
  }
  func cancel() { lock.withLock { _cancelled = true } }
  func interrupt() { lock.withLock { _cancelled = true; _interrupted = true } }
}

enum UnpackError: LocalizedError {
  case cancelled
  case damaged(String)
  case tooBig(kind: String, limit: Int64)

  var errorDescription: String? {
    switch self {
    case .cancelled: return L("Unpacking was cancelled.")
    case .damaged(let name): return String(format: L("%@ is damaged."), name)
    case .tooBig(let kind, let limit):
      return String(format: L("Iridia can unpack %@ files up to %@. Unpack this one on a computer, or make it a ZIP or 7Z file, and add it again."),
                    kind, ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))
    }
  }
}

/// Unpacks a ZIP with large reads and writes, checking each file's CRC. minizip walks the directory and finds
/// where each file's data starts; stored and deflated data are then read straight from the archive.
enum ZipStreamExtractor {
  private static let chunk = 4 << 20

  /// The total size of the files inside, from the archive's directory.
  static func unpackedSize(of archive: URL) -> Int64? {
    guard let zip = unzOpen64(archive.path) else { return nil }
    defer { unzClose(zip) }
    var total: Int64 = 0
    do { try forEachEntry(zip) { info, name in total = try adding(info.uncompressed_size, to: total, name) } } catch { return nil }
    return total
  }

  static func extract(_ archive: URL, to destination: URL, progress: UnpackProgress?) throws {
    guard let zip = unzOpen64(archive.path) else { throw ZipEntryScannerError.notAZip }
    defer { unzClose(zip) }
    let input = open(archive.path, O_RDONLY)
    guard input >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(input) }

    var total: Int64 = 0
    try forEachEntry(zip) { info, name in total = try adding(info.uncompressed_size, to: total, name) }
    progress?.setTotal(total)

    let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
    let output = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
    defer {
      buffer.deallocate()
      output.deallocate()
    }

    try forEachEntry(zip) { info, name in
      if progress?.isCancelled == true { throw UnpackError.cancelled }
      let path = name.replacingOccurrences(of: "\\", with: "/")
      let url = destination.appendingPathComponent(path)
      if path.hasSuffix("/") {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return
      }
      guard (info.flag & 1) == 0 else { throw UnpackError.damaged(path) }
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard unzOpenCurrentFile(zip) == UNZ_OK else { throw UnpackError.damaged(path) }
      let start = unzGetCurrentFileZStreamPos64(zip)
      unzCloseCurrentFile(zip)

      let file = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
      guard file >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      var written: UInt64 = 0
      var crc: uLong = crc32(0, nil, 0)
      let write: (UnsafeRawPointer, Int) throws -> Void = { bytes, count in
        var offset = 0
        while offset < count {
          let n = Foundation.write(file, bytes + offset, count - offset)
          guard n > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
          offset += n
        }
        crc = crc32(crc, bytes.assumingMemoryBound(to: Bytef.self), uInt(count))
        written += UInt64(count)
        if written > info.uncompressed_size { throw UnpackError.damaged(path) }
        progress?.add(Int64(count))
        if progress?.isCancelled == true { throw UnpackError.cancelled }
      }
      do {
        defer { close(file) }
        switch info.compression_method {
        case 0:
          try copyStored(input, from: start, count: info.compressed_size, buffer: buffer, write: write)
        case UInt(Z_DEFLATED):
          try inflate(input, from: start, count: info.compressed_size, input: buffer, output: output, name: path, write: write)
        default:
          try readWithMinizip(zip, buffer: buffer, name: path, write: write)
        }
      }
      if written != info.uncompressed_size || crc != info.crc {
        throw UnpackError.damaged(path)
      }
      let permissions = (info.external_fa >> 16) & 0o777
      if info.external_fa != 0, permissions >= 0o400 {
        chmod(url.path, mode_t(permissions))
      }
    }
  }

  private static func adding(_ size: UInt64, to total: Int64, _ name: String) throws -> Int64 {
    let (sum, overflow) = total.addingReportingOverflow(Int64(clamping: size))
    if overflow { throw UnpackError.damaged(name) }
    return sum
  }

  private static func forEachEntry(_ zip: unzFile, _ body: (unz_file_info64, String) throws -> Void) throws {
    var result = unzGoToFirstFile(zip)
    guard result == UNZ_OK else { throw ZipEntryScannerError.notAZip }
    var name = [CChar](repeating: 0, count: 0x10000)
    while result == UNZ_OK {
      var info = unz_file_info64()
      guard unzGetCurrentFileInfo64(zip, &info, &name, UInt(name.count - 1), nil, 0, nil, 0) == UNZ_OK else {
        throw ZipEntryScannerError.notAZip
      }
      let length = Int(info.size_filename)
      guard length > 0 else { throw ZipEntryScannerError.notAZip }
      let text = name.withUnsafeBufferPointer { String(decoding: UnsafeRawBufferPointer($0).prefix(length), as: UTF8.self) }
      try body(info, text)
      result = unzGoToNextFile(zip)
    }
    guard result == UNZ_END_OF_LIST_OF_FILE else { throw ZipEntryScannerError.inconsistentDirectory }
  }

  private static func readAt(_ file: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: UInt64) throws -> Int {
    let n = pread(file, buffer, count, off_t(offset))
    guard n > 0 else { throw n == 0 ? ZipEntryScannerError.truncated : POSIXError(.init(rawValue: errno) ?? .EIO) }
    return n
  }

  private static func copyStored(_ input: Int32, from start: UInt64, count: UInt64, buffer: UnsafeMutableRawPointer,
                                 write: (UnsafeRawPointer, Int) throws -> Void) throws {
    var offset: UInt64 = 0
    while offset < count {
      let n = try readAt(input, buffer, Int(min(UInt64(chunk), count - offset)), start + offset)
      try write(buffer, n)
      offset += UInt64(n)
    }
  }

  private static func inflate(_ file: Int32, from start: UInt64, count: UInt64, input: UnsafeMutableRawPointer,
                              output: UnsafeMutableRawPointer, name: String,
                              write: (UnsafeRawPointer, Int) throws -> Void) throws {
    var stream = z_stream()
    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw UnpackError.damaged(name)
    }
    defer { inflateEnd(&stream) }
    var offset: UInt64 = 0
    var status = Z_OK
    while status != Z_STREAM_END {
      if stream.avail_in == 0 {
        guard offset < count else { throw UnpackError.damaged(name) }
        let n = try readAt(file, input, Int(min(UInt64(chunk), count - offset)), start + offset)
        offset += UInt64(n)
        stream.next_in = input.assumingMemoryBound(to: Bytef.self)
        stream.avail_in = uInt(n)
      }
      stream.next_out = output.assumingMemoryBound(to: Bytef.self)
      stream.avail_out = uInt(chunk)
      status = zlib.inflate(&stream, Z_NO_FLUSH)
      guard status == Z_OK || status == Z_STREAM_END else { throw UnpackError.damaged(name) }
      let produced = chunk - Int(stream.avail_out)
      if produced > 0 { try write(output, produced) }
    }
  }

  private static func readWithMinizip(_ zip: unzFile, buffer: UnsafeMutableRawPointer, name: String,
                                      write: (UnsafeRawPointer, Int) throws -> Void) throws {
    guard unzOpenCurrentFile(zip) == UNZ_OK else { throw UnpackError.damaged(name) }
    defer { unzCloseCurrentFile(zip) }
    while true {
      let n = unzReadCurrentFile(zip, buffer, UInt32(chunk))
      guard n >= 0 else { throw UnpackError.damaged(name) }
      if n == 0 { return }
      try write(buffer, Int(n))
    }
  }
}

/// Unpacks a gzip file to `output` in large pieces, instead of reading it all into memory. Files made of several
/// gzip members (as `cat a.gz b.gz` makes) come out joined, like gunzip does.
enum GzipStreamExtractor {
  private static let chunk = 4 << 20

  static func extract(_ source: URL, to output: URL, progress: UnpackProgress?) throws {
    let input = open(source.path, O_RDONLY)
    guard input >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(input) }
    let file = open(output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard file >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(file) }
    progress?.setTotal(WiiUImport.size(of: source))

    let inBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
    let outBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
    defer {
      inBuffer.deallocate()
      outBuffer.deallocate()
    }
    var stream = z_stream()
    guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw UnpackError.damaged(source.lastPathComponent)
    }
    defer { inflateEnd(&stream) }
    var ended = false
    var atEnd = false
    var newMember = false
    var ignoredTail = false
    while true {
      if stream.avail_in == 0 && !atEnd {
        let n = read(input, inBuffer, chunk)
        guard n >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if n == 0 { atEnd = true } else {
          stream.next_in = inBuffer.assumingMemoryBound(to: Bytef.self)
          stream.avail_in = uInt(n)
          progress?.add(Int64(n))
        }
      }
      if stream.avail_in == 0 && atEnd { break }
      if ended {
        guard inflateReset(&stream) == Z_OK else { throw UnpackError.damaged(source.lastPathComponent) }
        ended = false
        newMember = true
      }
      stream.next_out = outBuffer.assumingMemoryBound(to: Bytef.self)
      stream.avail_out = uInt(chunk)
      let status = inflate(&stream, Z_NO_FLUSH)
      // Bytes after the last member that aren't another member: gunzip ignores them, so do the same.
      if newMember && status == Z_DATA_ERROR {
        ignoredTail = true
        break
      }
      newMember = false
      guard status == Z_OK || status == Z_STREAM_END || (status == Z_BUF_ERROR && stream.avail_in == 0) else {
        throw UnpackError.damaged(source.lastPathComponent)
      }
      let produced = chunk - Int(stream.avail_out)
      var offset = 0
      while offset < produced {
        let n = write(file, outBuffer + offset, produced - offset)
        guard n > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        offset += n
      }
      if status == Z_STREAM_END { ended = true }
      if progress?.isCancelled == true { throw UnpackError.cancelled }
    }
    guard ended || ignoredTail else { throw UnpackError.damaged(source.lastPathComponent) }
  }
}
