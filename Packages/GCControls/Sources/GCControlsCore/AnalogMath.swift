// SPDX-License-Identifier: GPL-2.0-or-later

public struct AnalogSettings: Codable, Sendable, Equatable {
  /// Radial dead zone, 0…0.9 of full deflection.
  public var deadZone: Double
  /// Output gain after the dead zone, 0.5…2.0. Values >1 reach full deflection sooner.
  public var sensitivity: Double

  public init(deadZone: Double = 0.10, sensitivity: Double = 1.0) {
    self.deadZone = deadZone
    self.sensitivity = sensitivity
  }

  public static let touchDefault = AnalogSettings(deadZone: 0.08, sensitivity: 1.0)
  public static let physicalDefault = AnalogSettings(deadZone: 0.12, sensitivity: 1.0)
}

public enum AnalogMath {
  /// Radial dead zone with rescale so output starts at 0 just past the dead zone
  /// (no jump), then gain, clamped to the unit circle. Input/output in -1…1, +y = up.
  @inline(__always)
  public static func shape(x: Double, y: Double, _ s: AnalogSettings) -> (x: Double, y: Double) {
    let mag = (x * x + y * y).squareRoot()
    let dz = min(max(s.deadZone, 0), 0.9)
    guard mag > dz, mag > 0 else { return (0, 0) }
    let clampedMag = min(mag, 1)
    let out = min((clampedMag - dz) / (1 - dz) * max(s.sensitivity, 0.1), 1)
    let k = out / mag
    return (x * k, y * k)
  }

  /// -1…1 → 0…255 with 128 = center.
  @inline(__always)
  public static func axisByte(_ v: Double) -> UInt8 {
    let c = min(max(v, -1), 1)
    return UInt8(clamping: Int((c * 127).rounded()) + 128)
  }

  /// 0…1 → 0…255.
  @inline(__always)
  public static func triggerByte(_ v: Double) -> UInt8 {
    UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded()))
  }

  /// 8-way D-pad from a vector (+y = up). Returns no directions inside `deadRadius`.
  /// Diagonals cover ±22.5° around 45°, 135°, … so they're easy to hit on glass.
  @inline(__always)
  public static func dpad(x: Double, y: Double, deadRadius: Double = 0.25) -> GCButtons {
    let mag = (x * x + y * y).squareRoot()
    guard mag > deadRadius else { return [] }
    // tan(22.5°) and tan(67.5°)
    let t1 = 0.41421356, t2 = 2.41421356
    let ax = abs(x), ay = abs(y)
    var out: GCButtons = []
    if ay <= ax * t1 {
      out.insert(x > 0 ? .dpadRight : .dpadLeft)
    } else if ay >= ax * t2 {
      out.insert(y > 0 ? .dpadUp : .dpadDown)
    } else {
      out.insert(x > 0 ? .dpadRight : .dpadLeft)
      out.insert(y > 0 ? .dpadUp : .dpadDown)
    }
    return out
  }
}
