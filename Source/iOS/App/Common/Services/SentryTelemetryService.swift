// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia sends NO telemetry. iCube reported crashes, hangs and performance to its own Sentry
// account; the Sentry SDK is removed and these entry points are kept as no-ops so call sites stay
// unchanged. (Privacy: nothing leaves the device; see PrivacyInfo.xcprivacy and PRIVACY.md.)

import Foundation

/// Thread-safe gate read by `tracesSampler` and trace helpers during active emulation.
enum EmulationTelemetryGate {
  private static let lock = NSLock()
  private static var _isActive = false

  static var isEmulationActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isActive
  }

  static func setEmulationActive(_ active: Bool) {
    lock.lock()
    _isActive = active
    lock.unlock()
  }
}

/// Which kind of build this binary is, reported as the Sentry environment. Keyed on the build
/// configuration only: the build number cannot tell a local build apart, because every CI alpha
/// before ca0f5931d1 (2026-09-21) also shipped as CFBundleVersion 13 and sideload users still run them.
enum SentryBuildEnvironment: String {
  case development
  case appStore = "appstore"
  case trollStore = "trollstore"
  case sideload

  static func resolve(isDebug: Bool, isAppStore: Bool, isTrollStore: Bool) -> Self {
    if isDebug { return .development }
    if isAppStore { return .appStore }
    if isTrollStore { return .trollStore }
    return .sideload
  }

  static var current: Self {
    #if DEBUG
    let isDebug = true
    #else
    let isDebug = false
    #endif
    #if APPSTORE
    let isAppStore = true
    #else
    let isAppStore = false
    #endif
    #if TROLLSTORE
    let isTrollStore = true
    #else
    let isTrollStore = false
    #endif
    return resolve(isDebug: isDebug, isAppStore: isAppStore, isTrollStore: isTrollStore)
  }

  /// Sentry's watchdog-termination heuristic reports ANY foreground death that left no crash report.
  /// On debug builds that is mostly devicectl/Xcode reinstalling or terminating the app, and every
  /// local build shares release `1.0.0+13`, so Sentry cannot tell a reinstall from a kill.
  var tracksWatchdogTerminations: Bool {
    self != .development
  }

}

/// Drops breadcrumbs that flood the 100-entry buffer and push out the ones that explain a death.
enum SentryBreadcrumbFilter {
  /// Selectors the on-screen touch controls fire on every frame of input (joystick, TCButton).
  /// About 30 per second while playing, so they fill the whole buffer in a few seconds.
  static let touchControlSelectors: Set<String> = ["valueChanged:", "buttonPressed", "buttonReleased"]
  /// Sentry Spotlight's local sidecar (DEBUG only); every event it forwards records an http crumb.
  static let spotlightPort = 8969

  static func shouldKeep(category: String, message: String?, url: String?, emulationActive: Bool) -> Bool {
    if category == "touch", emulationActive, let message, touchControlSelectors.contains(message) {
      return false
    }
    if category == "http", let url, let components = URLComponents(string: url),
       components.host == "localhost", components.port == spotlightPort {
      return false
    }
    return true
  }
}

/// No-op stand-in for iCube's Sentry service (see the file header).
enum SentryTelemetryService {
  /// Opaque placeholder for the removed Sentry span type.
  final class Span {}
  enum SpanStatus { case ok, cancelled, internalError }

  static let releaseSessionSampleRate = 0.0

  static func isUnitTestHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  static func configure() {}
  static func handleEmulationWillStart() { EmulationTelemetryGate.setEmulationActive(true) }
  static func handleEmulationDidStart() {}
  static func handleEmulationDidEnd() { EmulationTelemetryGate.setEmulationActive(false) }

  static func beginTrace(_ name: String, op: String, tags: [String: String] = [:], force: Bool = false) -> Span? { nil }
  static func finishTrace(_ span: Span?, status: SpanStatus = .ok) {}

  static func trace<T>(_ name: String, op: String, tags: [String: String] = [:], force: Bool = false,
                       _ work: () throws -> T) rethrows -> T { try work() }

  static func traceAsync<T>(_ name: String, op: String, tags: [String: String] = [:], force: Bool = false,
                            _ work: () async throws -> T) async rethrows -> T { try await work() }

  static func recordEmulationBoot(jitMode: String, cpuCore: Int, gfxBackend: String) {}
  static func recordJitStep(_ step: String, data: [String: Any] = [:]) {}
  static func recordSettingsRepair(version: Int, deleted: [String: String], removedDefaults: [String]) {}
}

/// Objective-C entry points (EmulationCoordinator, GameFileCacheManager, MsgAlertManager): no-ops.
@objc(DOLSentryTelemetryBridge)
@objcMembers
final class DOLSentryTelemetryBridge: NSObject {
  @objc(configure) static func configure() {}
  @objc(emulationWillStart) static func emulationWillStart() { SentryTelemetryService.handleEmulationWillStart() }
  @objc(recordEmulationBootWithJitMode:cpuCore:gfxBackend:)
  static func recordEmulationBoot(jitMode: String, cpuCore: Int, gfxBackend: String) {}
  @objc(recordJitStep:data:) static func recordJitStep(_ step: String, data: [String: Any]) {}
  @objc(recordMsgAlertWithCaption:text:question:) static func recordMsgAlert(caption: String, text: String, question: Bool) {}
  @objc(recordMsgAlertAnswer:) static func recordMsgAlertAnswer(_ confirmed: Bool) {}
  @objc(traceSyncWithName:operation:tags:work:)
  static func traceSync(name: String, operation: String, tags: [String: String], work: () -> Void) { work() }
}
