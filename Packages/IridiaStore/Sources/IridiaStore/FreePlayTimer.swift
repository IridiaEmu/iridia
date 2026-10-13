// SPDX-License-Identifier: GPL-2.0-or-later
//
// The free play session: 10 minutes of actual play (time spent paused or in menus doesn't count),
// a heads-up one minute before the end, then the session ends. Sessions are unlimited: a new one
// starts every time a game is launched. Pure state machine, driven by the app's 1 Hz tick.

import Foundation

public struct FreePlayTimer: Equatable, Sendable {
  public enum Event: Equatable, Sendable {
    /// One minute (by default) is left.
    case warning(secondsLeft: Int)
    /// The session is over: pause, save, show the unlock screen.
    case expired
  }

  public static let defaultLimit: TimeInterval = 10 * 60
  public static let defaultWarning: TimeInterval = 60

  public let limit: TimeInterval
  public let warningAt: TimeInterval
  public private(set) var played: TimeInterval = 0
  public private(set) var warned = false
  public private(set) var isExpired = false

  public init(limit: TimeInterval = FreePlayTimer.defaultLimit, warningAt: TimeInterval = FreePlayTimer.defaultWarning) {
    self.limit = limit
    self.warningAt = min(warningAt, limit)
  }

  public var remaining: TimeInterval { max(0, limit - played) }

  /// Advance by `elapsed` seconds of wall time; only counts while `isPlaying` (running, not paused).
  /// Returns the event this step crossed, if any (at most one; expiry wins).
  public mutating func tick(elapsed: TimeInterval, isPlaying: Bool) -> Event? {
    guard !isExpired, isPlaying, elapsed > 0 else { return nil }
    // A long gap (app suspended, debugger) counts as at most a few seconds of play.
    played += min(elapsed, 5)
    if played >= limit {
      isExpired = true
      return .expired
    }
    if !warned, remaining <= warningAt {
      warned = true
      return .warning(secondsLeft: Int(remaining.rounded(.up)))
    }
    return nil
  }
}
