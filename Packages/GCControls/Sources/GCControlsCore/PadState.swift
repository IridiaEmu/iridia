// SPDX-License-Identifier: GPL-2.0-or-later
//
// One GameCube pad's full input state, packed into a single UInt64 so it can be
// published and read with one atomic operation (no locks on the emulation thread).
//
// Layout (little end first):
//   bits  0–15  buttons (same bit values as Dolphin's PadButton, see GCButtons)
//   bits 16–23  L analog   0…255
//   bits 24–31  R analog   0…255
//   bits 32–39  main stick X  0…255, 128 = center
//   bits 40–47  main stick Y  0…255, 128 = center, 255 = up
//   bits 48–55  C-stick X     0…255, 128 = center
//   bits 56–63  C-stick Y     0…255, 128 = center, 255 = up

/// Digital buttons. Raw values match Dolphin's `PadButton` so the core bridge can copy them.
public struct GCButtons: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let dpadLeft = GCButtons(rawValue: 0x0001)
  public static let dpadRight = GCButtons(rawValue: 0x0002)
  public static let dpadDown = GCButtons(rawValue: 0x0004)
  public static let dpadUp = GCButtons(rawValue: 0x0008)
  public static let z = GCButtons(rawValue: 0x0010)
  public static let r = GCButtons(rawValue: 0x0020)  // digital click at full press
  public static let l = GCButtons(rawValue: 0x0040)  // digital click at full press
  public static let a = GCButtons(rawValue: 0x0100)
  public static let b = GCButtons(rawValue: 0x0200)
  public static let x = GCButtons(rawValue: 0x0400)
  public static let y = GCButtons(rawValue: 0x0800)
  public static let start = GCButtons(rawValue: 0x1000)
}

public struct PadState: Sendable, Equatable {
  public static let center: UInt8 = 128

  public var buttons: GCButtons
  public var triggerL: UInt8
  public var triggerR: UInt8
  public var stickX: UInt8
  public var stickY: UInt8
  public var cStickX: UInt8
  public var cStickY: UInt8

  public static let neutral = PadState(
    buttons: [], triggerL: 0, triggerR: 0,
    stickX: center, stickY: center, cStickX: center, cStickY: center)

  public init(
    buttons: GCButtons, triggerL: UInt8, triggerR: UInt8,
    stickX: UInt8, stickY: UInt8, cStickX: UInt8, cStickY: UInt8
  ) {
    self.buttons = buttons
    self.triggerL = triggerL
    self.triggerR = triggerR
    self.stickX = stickX
    self.stickY = stickY
    self.cStickX = cStickX
    self.cStickY = cStickY
  }

  @inline(__always)
  public init(packed w: UInt64) {
    buttons = GCButtons(rawValue: UInt16(truncatingIfNeeded: w))
    triggerL = UInt8(truncatingIfNeeded: w >> 16)
    triggerR = UInt8(truncatingIfNeeded: w >> 24)
    stickX = UInt8(truncatingIfNeeded: w >> 32)
    stickY = UInt8(truncatingIfNeeded: w >> 40)
    cStickX = UInt8(truncatingIfNeeded: w >> 48)
    cStickY = UInt8(truncatingIfNeeded: w >> 56)
  }

  @inline(__always)
  public var packed: UInt64 {
    UInt64(buttons.rawValue)
      | UInt64(triggerL) << 16 | UInt64(triggerR) << 24
      | UInt64(stickX) << 32 | UInt64(stickY) << 40
      | UInt64(cStickX) << 48 | UInt64(cStickY) << 56
  }

  public static let neutralPacked: UInt64 = neutral.packed

  /// Combine two sources (touch + physical): buttons OR'd, triggers max'd,
  /// each stick taken from whichever source is pushed further from center.
  @inline(__always)
  public static func merge(_ a: UInt64, _ b: UInt64) -> UInt64 {
    if b == neutralPacked { return a }
    if a == neutralPacked { return b }
    let pa = PadState(packed: a), pb = PadState(packed: b)
    func deflection(_ x: UInt8, _ y: UInt8) -> Int {
      let dx = Int(x) - 128, dy = Int(y) - 128
      return dx * dx + dy * dy
    }
    let useAMain = deflection(pa.stickX, pa.stickY) >= deflection(pb.stickX, pb.stickY)
    let useAC = deflection(pa.cStickX, pa.cStickY) >= deflection(pb.cStickX, pb.cStickY)
    return PadState(
      buttons: pa.buttons.union(pb.buttons),
      triggerL: max(pa.triggerL, pb.triggerL),
      triggerR: max(pa.triggerR, pb.triggerR),
      stickX: useAMain ? pa.stickX : pb.stickX,
      stickY: useAMain ? pa.stickY : pb.stickY,
      cStickX: useAC ? pa.cStickX : pb.cStickX,
      cStickY: useAC ? pa.cStickY : pb.cStickY
    ).packed
  }
}
