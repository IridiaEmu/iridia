// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if os(iOS)
import UIKit
#endif

/// Facade over the save-state bridge that writes a metadata sidecar alongside
/// every save, so saves are self-describing (title, timestamp, game).
///
/// Call sites should prefer this over calling `TVEmulationBridge.saveState`
/// directly. The save-manager UI phase migrates the existing in-game Save
/// buttons onto these entry points.
public enum SaveStateService {
  /// Game ID of the running title (authoritative, from the core), or nil when
  /// nothing is running.
  public static var currentGameID: String? {
    let gid = TVEmulationBridge.currentGameID()
    return gid.isEmpty ? nil : gid
  }

  /// Save to a numbered slot and write/refresh its metadata sidecar.
  ///
  /// `wait` blocks until the state file has been written so the sidecar is
  /// consistent with the file on disk. Returns false if the core refused the save
  /// (not running), the path could not be resolved, or the sidecar could not be written.
  @discardableResult
  public static func saveSlot(_ slot: Int,
                              title: String? = nil,
                              gameTitle: String? = nil,
                              wait: Bool = true) -> Bool {
    // The core refuses while it is booting or stopping; writing a sidecar for a state that was never made would lie.
    guard TVEmulationBridge.saveState(toSlot: slot, wait: wait) else { return false }

    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot) else { return false }
    let stateURL = URL(fileURLWithPath: path)
    let now = Date()
    let metadata = SaveStateMetadata(
      title: title ?? defaultTitle(slot: slot, date: now),
      gameID: currentGameID ?? "UNKNOWN",
      gameTitle: gameTitle,
      savedAt: now,
      playTimeSeconds: Double(TVEmulationBridge.currentGamePlayTimeSeconds()),
      isAuto: false
    )
    let ok = SaveStateMetadataStore.write(metadata, forStateFile: stateURL)
    captureThumbnail(forStateFile: stateURL)
    return ok
  }

  // MARK: - Thumbnails

  /// Stable scratch path for the "last frame before the pause menu opened" preview.
  public static var pausePreviewURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("icube_pause_preview.png")
  }

  /// Grab the current frame into the pause preview. Call this as the pause menu
  /// opens, while frames are still in flight — so a save made while paused still
  /// has a thumbnail (the live capture below can't fire once presenting stops).
  public static func capturePausePreview() {
    TVEmulationBridge.captureScreenshot(toPath: pausePreviewURL.path)
  }

  /// Produce a thumbnail next to the state file. Adopts the fresh pause preview
  /// (covers saves made while paused), then requests a live capture that overwrites
  /// it with the current frame when emulation is still running. Both are best-effort;
  /// a missing thumbnail degrades to a placeholder in the UI.
  private static func captureThumbnail(forStateFile stateURL: URL) {
    let thumbURL = stateURL.appendingPathExtension("png")
    adoptPausePreviewIfFresh(into: thumbURL)
    TVEmulationBridge.captureScreenshot(toPath: thumbURL.path)
  }

  /// gc-emu: the resume ("Continue") save gets a thumbnail too: GZ2E01.auto -> GZ2E01.auto.png.
  /// Same two sources as a slot save: the pause preview (Save & Exit comes from the pause menu,
  /// where the game has been frozen since the preview was taken), then a live frame if one is
  /// still being presented. Best-effort, like slot thumbnails.
  /// `live` also asks for the next presented frame; only useful while the game is still running
  /// (a request made while paused would fire on resume, with a later frame).
  static func captureAutoThumbnail(live: Bool) {
    guard let url = autoStateURL else { return }
    let thumbURL = url.appendingPathExtension("png")
    adoptPausePreviewIfFresh(into: thumbURL, maxAge: 600)
    if live { TVEmulationBridge.captureScreenshot(toPath: thumbURL.path) }
  }

  private static func adoptPausePreviewIfFresh(into thumbURL: URL, maxAge: TimeInterval = 60) {
    let fm = FileManager.default
    let preview = pausePreviewURL
    guard let attrs = try? fm.attributesOfItem(atPath: preview.path),
          let modified = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(modified) < maxAge else { return }
    // Never replace a newer thumbnail (e.g. a live frame grabbed as the app left the foreground).
    if let existing = (try? fm.attributesOfItem(atPath: thumbURL.path))?[.modificationDate] as? Date,
       existing >= modified { return }
    try? fm.removeItem(at: thumbURL)
    try? fm.copyItem(at: preview, to: thumbURL)
  }

  /// A reasonable default label for an unlabeled save, e.g. "Slot 1 — Jun 3, 2026 at 4:12 PM".
  public static func defaultTitle(slot: Int, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "Slot \(slot) — \(formatter.string(from: date))"
  }

  // MARK: - Resume where I left off

  /// NSUserDefault key for the "resume where I left off" toggle. Kept as a default
  /// (not a Dolphin Config key) because it is pure frontend behavior — the core
  /// never reads it, so a Config key would be flagged dangling by icube_config_lint.
  public static let resumeDefaultsKey = "resume_where_left_off"

  /// gc-emu: on by default (registered in AppDelegate), so a game opens where you left it instead
  /// of at the title screen. Never during scripted benchmarks (-gcemuBench): those must start cold.
  public static var resumeEnabled: Bool {
    UserDefaults.standard.bool(forKey: resumeDefaultsKey) && !isBenchmarkRun
  }

  static var isBenchmarkRun: Bool { UserDefaults.standard.double(forKey: "gcemuBench") > 0 }

  /// gc-emu: write the running game's resume state now. Used when the app goes to the background,
  /// because iOS may end a backgrounded app (or the user swipes it away) without +stop ever running.
  static func saveAutoStateNow() {
    guard resumeEnabled, TVEmulationBridge.isStateOperationAllowed(), let url = autoStateURL else { return }
    captureAutoThumbnail(live: false)   // live frames were requested earlier (resign-active, session end)
    TVEmulationBridge.saveState(toPath: url.path, wait: true)
    NSLog("[Resume] saved %@ (app backgrounded)", url.lastPathComponent)
  }

  /// Path to the running title's dedicated auto-state, or nil if nothing is running.
  public static var autoStateURL: URL? {
    guard let path = TVEmulationBridge.autoStateFilePath() else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// True when a resume auto-state exists on disk for the running title.
  public static var hasAutoState: Bool {
    guard let url = autoStateURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// One-shot: the next boot starts fresh even though an auto-state exists. Set by the library's
  /// "Start Fresh" action: a bad auto-state would otherwise be reloaded on every single launch, with
  /// no way back into the game. Main thread only, like everything else here.
  public static var skipResumeOnce = false

  // MARK: - Boot into a chosen save state

  /// Path to a save state that should be loaded immediately after the next boot,
  /// in place of the ordinary auto-resume. Set by "boot into a chosen save
  /// state" entry points (the save-state browser's Load action, when reached
  /// from the library rather than the pause menu of an already-running game)
  /// right before launching the game. Consumed once by
  /// `resumeOrBootIntoPendingState()`, which always clears it so a stale request
  /// can never leak into a later, unrelated boot.
  public static var pendingBootStatePath: String?

  /// Pure outcome of `resumeDecision(...)` — no I/O, so the decision table is
  /// unit-testable without touching `TVEmulationBridge` or `UserDefaults`.
  enum ResumeDecision: Equatable {
    /// The previous boot armed the watchdog and never confirmed it survived;
    /// decline everything and tell the user.
    case declineWatchdog
    /// A specific save state was requested (library "boot into a state" or a
    /// Continuity handoff); load it.
    case loadPending(path: String)
    /// "Start Fresh (Skip Resume)" was requested for this boot; load nothing.
    case skipOnce
    /// Resume-where-left-off is on and an auto-state exists; load it.
    case loadAuto(path: String)
    /// Nothing to do (resume disabled, no auto-state, or a requested state
    /// vanished from disk).
    case none
  }

  /// Decides what a boot should do with no side effects, given a snapshot of
  /// the flags/files `resumeOrBootIntoPendingState()` would otherwise read
  /// and mutate live. Kept free of `TVEmulationBridge`/`UserDefaults` so the
  /// precedence rules (a requested state beats resume, "Start Fresh" beats
  /// resume, the watchdog beats everything) can be tested directly — see
  /// `SaveStateServiceResumeDecisionTests`.
  static func resumeDecision(
    watchdogArmed: Bool,
    pendingBootStatePath: String?,
    pendingStateExists: Bool,
    skipResumeOnce: Bool,
    resumeEnabled: Bool,
    autoStatePath: String?,
    autoStateExists: Bool
  ) -> ResumeDecision {
    if watchdogArmed { return .declineWatchdog }
    if let path = pendingBootStatePath {
      return pendingStateExists ? .loadPending(path: path) : .none
    }
    if skipResumeOnce { return .skipOnce }
    guard resumeEnabled, let auto = autoStatePath, autoStateExists else { return .none }
    return .loadAuto(path: auto)
  }

  /// If resume is enabled and an auto-state exists for the running title (or a
  /// specific save state was requested via `pendingBootStatePath`), load it.
  /// Returns true if a load was issued. Safe to call right after the game boots
  /// (the save side runs in `TVEmulationBridge.stop`, so every quit path is
  /// covered). Driven by a single app-lifetime observer (`installDidStartObserver()`)
  /// rather than per-`EmulationScreen`-instance observers: two observers alive for
  /// the same `DOLEmulationDidStartNotification` — e.g. an outgoing screen's observer
  /// not yet torn down while an incoming one's is already registered — let the first
  /// call consume `skipResumeOnce` and the second see it already cleared, loading the
  /// auto-state right on top of a "Start Fresh" request. A requested boot state takes
  /// precedence over resume when both are set, and whichever load actually happens is
  /// wrapped with the boot watchdog, so a previous attempt that never got past this
  /// same step is declined instead of repeated.
  @discardableResult
  public static func resumeOrBootIntoPendingState() -> Bool {
    let requestedPath = pendingBootStatePath
    let requestedExists = requestedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    let autoURL = autoStateURL
    let autoExists = autoURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

    let decision = resumeDecision(
      watchdogArmed: BootWatchdog.previousBootNeverCompleted,
      pendingBootStatePath: requestedPath,
      pendingStateExists: requestedExists,
      skipResumeOnce: skipResumeOnce,
      resumeEnabled: resumeEnabled,
      autoStatePath: autoURL?.path,
      autoStateExists: autoExists
    )

    switch decision {
    case .declineWatchdog:
      // A previous launch armed the watchdog around this exact step and nothing
      // ever cleared it - the state (or the auto-state) that step was about to
      // load never let the app come back up. Don't try it again automatically.
      BootWatchdog.clear()
      pendingBootStatePath = nil
      skipResumeOnce = false
      NotificationCenter.default.post(
        name: NSNotification.Name("DOLShowSnackbar"), object: nil,
        userInfo: ["text": L("Didn't resume, because the last try didn't finish loading.")]
      )
      return false

    case .loadPending(let path):
      pendingBootStatePath = nil
      BootWatchdog.armBeforeBoot()
      TVEmulationBridge.loadState(fromPath: path)
      BootWatchdog.clearAfterLivenessWindow()
      return true

    case .skipOnce:
      skipResumeOnce = false
      resumeChoiceForNextBoot = nil
      return false

    case .loadAuto(let path):
      #if os(iOS)
      if let choice = resumeChoiceForNextBoot {
        resumeChoiceForNextBoot = nil
        if choice { loadResumeState(path) }
        return choice
      }
      // gc-emu: ask first. The game is already booting normally, so "Title Screen" just lets it
      // carry on (to load an in-game save); "Continue" loads the resume state. EmulationScreen
      // shows the prompt and calls answerResumePrompt(continue:).
      pendingResumePromptPath = path
      NotificationCenter.default.post(name: resumePromptNotification, object: nil)
      return true
      #else
      loadResumeState(path)
      return true
      #endif

    case .none:
      // Matches the old behavior of clearing a requested-but-missing state
      // path unconditionally; a no-op when it was already nil.
      pendingBootStatePath = nil
      resumeChoiceForNextBoot = nil
      return false
    }
  }

  // MARK: - Resume prompt (gc-emu)

  static let resumePromptNotification = Notification.Name("GCEmuResumePrompt")

  /// The resume state waiting on the player's choice, or nil when there's nothing to ask.
  static var pendingResumePromptPath: String?

  /// Set by a launch that already chose (the shelf's Continue button): true loads the resume point
  /// without asking. Consumed by the next boot.
  static var resumeChoiceForNextBoot: Bool?

  /// Continue = load the resume state; Title Screen = leave the fresh boot running.
  static func answerResumePrompt(continue shouldContinue: Bool) {
    guard let path = pendingResumePromptPath else { return }
    pendingResumePromptPath = nil
    if shouldContinue { loadResumeState(path) }
  }

  private static func loadResumeState(_ path: String) {
    NSLog("[Resume] loading %@", (path as NSString).lastPathComponent)
    BootWatchdog.armBeforeBoot()
    TVEmulationBridge.loadState(fromPath: path)
    BootWatchdog.clearAfterLivenessWindow()
  }

  // MARK: - App-lifetime resume observer

  /// Installed exactly once (the `static let` initializer runs at most once no
  /// matter how many times `installDidStartObserver()` is called) so exactly
  /// one listener ever resolves the resume/boot-into-state decision, instead of
  /// one per `EmulationScreen` appearance. See `resumeOrBootIntoPendingState()`
  /// for why a per-view observer is the wrong lifetime for this specific step.
  private static let didStartObserverToken: NSObjectProtocol = {
    NotificationCenter.default.addObserver(
      forName: Notification.Name("DOLEmulationDidStartNotification"),
      object: nil, queue: .main
    ) { _ in
      resumeOrBootIntoPendingState()
    }
  }()

  #if os(iOS)
  /// gc-emu: frames stop once the app is in the background, so grab the Continue thumbnail while
  /// the game is still presenting (resign-active comes first).
  private static let willResignActiveObserverToken: NSObjectProtocol = {
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { _ in
      guard resumeEnabled, TVEmulationBridge.isRunning(), let url = autoStateURL else { return }
      TVEmulationBridge.captureScreenshot(toPath: url.appendingPathExtension("png").path)
    }
  }()

  private static let didEnterBackgroundObserverToken: NSObjectProtocol = {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      // Ask for time to finish: a state is ~30 MB and iOS may suspend the app right away.
      var task = UIBackgroundTaskIdentifier.invalid
      task = UIApplication.shared.beginBackgroundTask(withName: "resume-state") {
        UIApplication.shared.endBackgroundTask(task)
      }
      saveAutoStateNow()
      UIApplication.shared.endBackgroundTask(task)
    }
  }()
  #endif

  /// Call once at app startup. Idempotent: repeat calls just re-touch the
  /// already-initialized `static let` and register nothing further.
  public static func installDidStartObserver() {
    _ = didStartObserverToken
    #if os(iOS)
    _ = didEnterBackgroundObserverToken
    _ = willResignActiveObserverToken
    #endif
  }
}
