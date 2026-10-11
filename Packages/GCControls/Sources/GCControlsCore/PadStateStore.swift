// SPDX-License-Identifier: GPL-2.0-or-later
//
// Lock-free mailbox between input producers (touch on the main thread, physical
// controllers on their handler queue) and the emulation thread. Each player has
// one slot per source; a write or read is a single atomic UInt64 operation.

import Synchronization

public enum InputSource: Int, Sendable, CaseIterable {
  case touch = 0
  case physical = 1
}

public final class PadStateStore: Sendable {
  public static let playerCount = 4
  public static let shared = PadStateStore()

  private final class Slot: Sendable {
    let word = Atomic<UInt64>(PadState.neutralPacked)
  }

  // Immutable after init, so indexing is thread-safe; only the slots' atomics change.
  private let slots: [Slot]

  public init() {
    slots = (0..<(Self.playerCount * InputSource.allCases.count)).map { _ in Slot() }
  }

  @inline(__always)
  private func slot(_ player: Int, _ source: InputSource) -> Slot {
    slots[player * InputSource.allCases.count + source.rawValue]
  }

  /// Producers call this once per input event with the full new state.
  @inline(__always)
  public func publish(_ packed: UInt64, player: Int, source: InputSource) {
    guard player >= 0, player < Self.playerCount else { return }
    slot(player, source).word.store(packed, ordering: .releasing)
  }

  @inline(__always)
  public func publish(_ state: PadState, player: Int, source: InputSource) {
    publish(state.packed, player: player, source: source)
  }

  public func clear(player: Int, source: InputSource) {
    publish(PadState.neutralPacked, player: player, source: source)
  }

  /// Emulation thread: merged state for one player. Two atomic loads, no allocation.
  @inline(__always)
  public func read(player: Int) -> UInt64 {
    guard player >= 0, player < Self.playerCount else { return PadState.neutralPacked }
    let t = slot(player, .touch).word.load(ordering: .acquiring)
    let p = slot(player, .physical).word.load(ordering: .acquiring)
    return PadState.merge(t, p)
  }
}

/// C ABI for the emulation core (Source/Core/InputCommon iOS backend):
///   extern "C" uint64_t gcpad_read(int32_t player);
/// Unpack with the bit layout documented in PadState.swift.
@_cdecl("gcpad_read")
public func gcpad_read(_ player: Int32) -> UInt64 {
  PadStateStore.shared.read(player: Int(player))
}
