// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the app's single UnlockStore (IridiaStore package) and the free play session that runs
// while a game is played on the free tier. Wording rule (Guideline 3.1.1): this is a free play
// session that repeats without limit, never a "trial".

#if os(iOS)
import Foundation
import IridiaStore
import SwiftUI

@MainActor
enum IridiaUnlock {
  static let store = UnlockStore()

  /// Developer override for builds without App Store Connect (free-team installs):
  /// `-iridiaUnlocked YES` / `NO`. Never compiled into App Store builds.
  private static var devOverride: Bool? {
    #if APPSTORE
    return nil
    #else
    return UserDefaults.standard.object(forKey: "iridiaUnlocked") as? Bool
    #endif
  }

  static var isUnlocked: Bool { devOverride ?? store.isUnlocked }

  static func start() { store.start() }
}

/// Counts play time on the free tier and ends the session at 10 minutes. Owned by EmulationScreen.
@MainActor
final class FreePlaySession: ObservableObject {
  @Published var showUnlock = false
  /// True once the session ran out; the player can still unlock from the sheet.
  @Published private(set) var ended = false

  private var timer = FreePlayTimer()
  private var ticker: Timer?
  private var last = Date()
  private var pauseToken: PauseArbiter.Token?

  /// Benchmarks and unlocked players never get a session.
  var isActive: Bool { ticker != nil }

  func begin() {
    let benchmarking = UserDefaults.standard.double(forKey: "gcemuBench") > 0
    GCEmuStatsOverlay.forced = !IridiaUnlock.isUnlocked   // free play always shows FPS · speed
    guard !IridiaUnlock.isUnlocked, !benchmarking, ticker == nil else { return }
    timer = FreePlayTimer(limit: Self.limitOverride ?? FreePlayTimer.defaultLimit)
    last = Date()
    EmulationToast.post(L("Free play session: 10 minutes. Unlock the full version for unlimited play."))
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  func end() {
    ticker?.invalidate()
    ticker = nil
    releasePause()
  }

  /// Bought from the sheet: stop counting and let the game continue.
  func unlocked() {
    GCEmuStatsOverlay.forced = false
    showUnlock = false
    ended = false
    end()
    PauseArbiter.shared.userResume()
  }

  private func tick() {
    let now = Date()
    let elapsed = now.timeIntervalSince(last)
    last = now
    if IridiaUnlock.isUnlocked { unlocked(); return }   // bought elsewhere (e.g. Settings)
    let playing = TVEmulationBridge.isRunning() && !TVEmulationBridge.isPaused()
    switch timer.tick(elapsed: elapsed, isPlaying: playing) {
    case .warning:
      EmulationToast.post(L("1 minute left in this free play session"))
    case .expired:
      expire()
    case nil:
      break
    }
  }

  private func expire() {
    ticker?.invalidate()
    ticker = nil
    ended = true
    // Keep the player's progress: resume point now; the memory card is written when the game stops.
    SaveStateService.saveAutoStateNow()
    pauseToken = PauseArbiter.shared.claim("free-play-session")
    showUnlock = true
  }

  private func releasePause() {
    if let token = pauseToken {
      PauseArbiter.shared.release(token)
      pauseToken = nil
    }
  }

  /// Test hook (non-App Store builds): `-iridiaSessionSeconds 30` shortens the session.
  private static var limitOverride: TimeInterval? {
    #if APPSTORE
    return nil
    #else
    let s = UserDefaults.standard.double(forKey: "iridiaSessionSeconds")
    return s > 0 ? s : nil
    #endif
  }
}
#endif
