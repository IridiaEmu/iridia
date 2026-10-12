// SPDX-License-Identifier: GPL-2.0-or-later
//
// Thermal governor: steps graphics down while the device is hot and back up once it has stayed
// cool for a while (hysteresis, so it doesn't oscillate). Pure state machine, so the app feeds it
// ProcessInfo.thermalState changes and a clock, and applies whatever profile it returns.

public enum ThermalLevel: Int, Comparable, Sendable {
  case nominal = 0, fair, serious, critical
  public static func < (l: ThermalLevel, r: ThermalLevel) -> Bool { l.rawValue < r.rawValue }
}

public struct ThermalGovernor: Sendable {
  public enum Advice: Equatable, Sendable {
    case none
    /// Apply this (cheaper) profile.
    case apply(PerformanceProfile)
    /// Critical heat: also tell the user (and suggest pausing).
    case applyAndWarn(PerformanceProfile)
  }

  /// The user's chosen profile; the governor never goes above it.
  public private(set) var base: PerformanceProfile
  public private(set) var current: PerformanceProfile
  /// How many step-downs are in effect.
  public private(set) var steps = 0
  /// Seconds the device must stay at fair-or-cooler before one step is restored.
  public var recoveryDelay: Double

  private var coolSince: Double?

  public init(base: PerformanceProfile, recoveryDelay: Double = 60) {
    self.base = base
    current = base
    self.recoveryDelay = recoveryDelay
  }

  public mutating func setBase(_ p: PerformanceProfile) {
    base = p; current = p; steps = 0; coolSince = nil
  }

  /// Feed the current thermal level and time (seconds, monotonic). Returns what to do now.
  public mutating func update(level: ThermalLevel, now: Double) -> Advice {
    switch level {
    case .serious, .critical:
      coolSince = nil
      // serious: one step per update; critical: drop straight to the floor.
      var changed = false
      repeat {
        guard let next = current.steppedDown() else { break }
        current = next; steps += 1; changed = true
      } while level == .critical
      if level == .critical { return .applyAndWarn(current) }
      return changed ? .apply(current) : .none
    case .nominal, .fair:
      guard steps > 0 else { return .none }
      if coolSince == nil { coolSince = now; return .none }
      guard now - (coolSince ?? now) >= recoveryDelay else { return .none }
      steps -= 1
      var p = base
      for _ in 0..<steps { p = p.steppedDown() ?? p }
      current = p
      coolSince = now  // wait again before the next step back up
      return .apply(current)
    }
  }
}
